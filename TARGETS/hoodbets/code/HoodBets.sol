// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// ----------------------------------------------------------------------
/// HoodBets — parimutuel price markets on Robinhood Chain (4663)
///
/// One market = one question: will FEED settle ABOVE the strike at the
/// first oracle round at-or-after settleTime?
///
/// - Bets in native ETH, held by this contract. Nobody can move them.
/// - Settlement reads a Chainlink stock feed. No admin settlement.
/// - Losers pay winners pro-rata. Rake (bps of the losing pool) -> treasury.
/// - If the oracle never delivers by settleDeadline, or a side is empty,
///   the market flips to refund mode and every bettor withdraws in full.
/// - No upgradeability. No pause. Owner can only create markets.
/// ----------------------------------------------------------------------

interface AggregatorV3Interface {
    function decimals() external view returns (uint8);

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);

    function getRoundData(uint80 _roundId)
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

contract HoodBets {
    // ------------------------------------------------------------------
    // Types
    // ------------------------------------------------------------------

    uint8 public constant SIDE_OVER = 0;
    uint8 public constant SIDE_UNDER = 1;

    struct Market {
        address feed; // Chainlink AggregatorV3 proxy
        string symbol; // e.g. "GME"
        int256 strike; // price line, in feed decimals (8 for stock feeds)
        uint64 cutoffTime; // no bets at/after this timestamp
        uint64 settleTime; // settle on first oracle round at/after this
        uint64 settleDeadline; // refunds allowed if unsettled past this
        bool settled;
        bool refundMode;
        uint8 winningSide;
        int256 settlePrice;
        uint256 potCap; // max total pot (wei), 0 = uncapped
        uint256[2] pools; // [over, under]
    }

    // ------------------------------------------------------------------
    // Storage
    // ------------------------------------------------------------------

    address public immutable owner;
    address public immutable treasury;
    uint256 public immutable rakeBps; // capped at MAX_RAKE_BPS forever

    uint256 public constant MAX_RAKE_BPS = 500; // 5% hard cap
    uint256 public constant MIN_BET = 0.0001 ether;

    Market[] private _markets;

    // marketId => bettor => [overStake, underStake]
    mapping(uint256 => mapping(address => uint256[2])) public stakes;
    // marketId => bettor => claimed/refunded
    mapping(uint256 => mapping(address => bool)) public paidOut;

    uint256 private _locked = 1;

    // ------------------------------------------------------------------
    // Events
    // ------------------------------------------------------------------

    event MarketCreated(
        uint256 indexed marketId,
        address indexed feed,
        string symbol,
        int256 strike,
        uint64 cutoffTime,
        uint64 settleTime,
        uint64 settleDeadline,
        uint256 potCap
    );
    event BetPlaced(uint256 indexed marketId, address indexed bettor, uint8 side, uint256 amount);
    event MarketSettled(uint256 indexed marketId, int256 settlePrice, uint8 winningSide, uint256 rakeAmount);
    event RefundModeEnabled(uint256 indexed marketId);
    event Claimed(uint256 indexed marketId, address indexed bettor, uint256 amount);
    event Refunded(uint256 indexed marketId, address indexed bettor, uint256 amount);

    // ------------------------------------------------------------------
    // Modifiers
    // ------------------------------------------------------------------

    modifier nonReentrant() {
        require(_locked == 1, "reentrancy");
        _locked = 2;
        _;
        _locked = 1;
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "not owner");
        _;
    }

    // ------------------------------------------------------------------
    // Constructor
    // ------------------------------------------------------------------

    constructor(address _treasury, uint256 _rakeBps) {
        require(_treasury != address(0), "treasury zero");
        require(_rakeBps <= MAX_RAKE_BPS, "rake too high");
        owner = msg.sender;
        treasury = _treasury;
        rakeBps = _rakeBps;
    }

    // ------------------------------------------------------------------
    // Market creation (only admin power in the contract)
    // ------------------------------------------------------------------

    function createMarket(
        address feed,
        string calldata symbol,
        int256 strike,
        uint64 cutoffTime,
        uint64 settleTime,
        uint64 settleDeadline,
        uint256 potCap
    ) external onlyOwner returns (uint256 marketId) {
        require(feed != address(0), "feed zero");
        require(strike > 0, "strike zero");
        require(cutoffTime > block.timestamp, "cutoff in past");
        require(settleTime >= cutoffTime, "settle before cutoff");
        require(settleDeadline > settleTime, "deadline before settle");

        Market storage m = _markets.push();
        m.feed = feed;
        m.symbol = symbol;
        m.strike = strike;
        m.cutoffTime = cutoffTime;
        m.settleTime = settleTime;
        m.settleDeadline = settleDeadline;
        m.potCap = potCap;

        marketId = _markets.length - 1;
        emit MarketCreated(marketId, feed, symbol, strike, cutoffTime, settleTime, settleDeadline, potCap);
    }

    // ------------------------------------------------------------------
    // Betting
    // ------------------------------------------------------------------

    function bet(uint256 marketId, uint8 side) external payable nonReentrant {
        Market storage m = _market(marketId);
        require(side <= SIDE_UNDER, "bad side");
        require(block.timestamp < m.cutoffTime, "betting closed");
        require(msg.value >= MIN_BET, "below min bet");
        if (m.potCap != 0) {
            require(m.pools[0] + m.pools[1] + msg.value <= m.potCap, "pot cap");
        }

        m.pools[side] += msg.value;
        stakes[marketId][msg.sender][side] += msg.value;

        emit BetPlaced(marketId, msg.sender, side, msg.value);
    }

    // ------------------------------------------------------------------
    // Settlement — permissionless, oracle-verified
    //
    // Caller supplies the roundId of the FIRST oracle round whose
    // updatedAt >= settleTime. The contract verifies:
    //   1. the round is valid and at/after settleTime
    //   2. the previous round (if readable) is before settleTime
    // ------------------------------------------------------------------

    function settle(uint256 marketId, uint80 roundId) external nonReentrant {
        Market storage m = _market(marketId);
        require(!m.settled && !m.refundMode, "finalized");
        require(block.timestamp >= m.settleTime, "too early");

        AggregatorV3Interface feed = AggregatorV3Interface(m.feed);

        (, int256 answer,, uint256 updatedAt,) = feed.getRoundData(roundId);
        require(answer > 0 && updatedAt != 0, "invalid round");
        require(updatedAt >= m.settleTime, "round before settleTime");
        require(updatedAt <= m.settleDeadline, "round after deadline");

        // must be the FIRST round at/after settleTime
        if (roundId > 0) {
            try feed.getRoundData(roundId - 1) returns (uint80, int256, uint256, uint256 prevUpdatedAt, uint80) {
                if (prevUpdatedAt != 0) {
                    require(prevUpdatedAt < m.settleTime, "not first round");
                }
            } catch {
                // previous round unreadable (phase boundary) — accept
            }
        }

        // one-sided market -> nobody to pay anybody: full refunds, no rake
        if (m.pools[SIDE_OVER] == 0 || m.pools[SIDE_UNDER] == 0) {
            m.refundMode = true;
            emit RefundModeEnabled(marketId);
            return;
        }

        uint8 winningSide = answer > m.strike ? SIDE_OVER : SIDE_UNDER;
        uint256 rakeAmount = (m.pools[1 - winningSide] * rakeBps) / 10_000;

        m.settled = true;
        m.winningSide = winningSide;
        m.settlePrice = answer;

        if (rakeAmount > 0) {
            (bool ok,) = treasury.call{value: rakeAmount}("");
            require(ok, "rake transfer failed");
        }

        emit MarketSettled(marketId, answer, winningSide, rakeAmount);
    }

    /// If the oracle never produced a settleable round by the deadline
    /// (feed paused, corporate action, sequencer outage), everyone exits whole.
    function enableRefund(uint256 marketId) external {
        Market storage m = _market(marketId);
        require(!m.settled && !m.refundMode, "finalized");
        require(block.timestamp > m.settleDeadline, "deadline not passed");
        m.refundMode = true;
        emit RefundModeEnabled(marketId);
    }

    // ------------------------------------------------------------------
    // Payouts — pull, never push
    // ------------------------------------------------------------------

    function claim(uint256 marketId) external nonReentrant {
        Market storage m = _market(marketId);
        require(m.settled, "not settled");
        require(!paidOut[marketId][msg.sender], "already paid");

        uint256 winStake = stakes[marketId][msg.sender][m.winningSide];
        require(winStake > 0, "nothing to claim");

        uint256 winPool = m.pools[m.winningSide];
        uint256 losePool = m.pools[1 - m.winningSide];
        uint256 distributable = losePool - (losePool * rakeBps) / 10_000;

        uint256 payout = winStake + (winStake * distributable) / winPool;
        paidOut[marketId][msg.sender] = true;

        (bool ok,) = msg.sender.call{value: payout}("");
        require(ok, "payout failed");

        emit Claimed(marketId, msg.sender, payout);
    }

    function refund(uint256 marketId) external nonReentrant {
        Market storage m = _market(marketId);
        require(m.refundMode, "not refund mode");
        require(!paidOut[marketId][msg.sender], "already paid");

        uint256 total = stakes[marketId][msg.sender][SIDE_OVER] + stakes[marketId][msg.sender][SIDE_UNDER];
        require(total > 0, "nothing to refund");

        paidOut[marketId][msg.sender] = true;

        (bool ok,) = msg.sender.call{value: total}("");
        require(ok, "refund failed");

        emit Refunded(marketId, msg.sender, total);
    }

    // ------------------------------------------------------------------
    // Views
    // ------------------------------------------------------------------

    function marketCount() external view returns (uint256) {
        return _markets.length;
    }

    function getMarket(uint256 marketId) external view returns (Market memory) {
        return _market(marketId);
    }

    function stakeOf(uint256 marketId, address bettor) external view returns (uint256 overStake, uint256 underStake) {
        return (stakes[marketId][bettor][SIDE_OVER], stakes[marketId][bettor][SIDE_UNDER]);
    }

    // ------------------------------------------------------------------
    // Internal
    // ------------------------------------------------------------------

    function _market(uint256 marketId) internal view returns (Market storage) {
        require(marketId < _markets.length, "no market");
        return _markets[marketId];
    }
}