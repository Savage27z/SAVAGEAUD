// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IDrandOracle} from "./interfaces/IDrandOracle.sol";

interface ISteelToken {
    function mint(address to, uint256 amount) external;
}

interface IVeSteelV2 {
    function notifyReward() external payable; // 8% ETH -> stakers
    function creditDevLock(uint256 amount) external; // 8% STEEL -> dev permanent lock
}

/// @title SteelMineV2 — slvr.fun-style round mining lottery (full economics).
/// @notice 25-square grid, 60s rounds, drand winner. Per round:
///   ETH (10% fee of pot): 90% winners · 8% veSTEEL stakers · 2% motherlode.
///   STEEL (mint 1.12): 1.0 winners · 0.08 dev(veSTEEL lock) · 0.04 motherlode.
///   Motherlode (ETH+STEEL) pays out on a 1/625 roll to that round's winners.
///   Single-miner round (50%): the round's STEEL goes to ONE winner (bet-weighted).
///   Winnings are UNREFINED STEEL; refining costs 10%, redistributed pro-rata to
///   the other unrefined holders (claim later, earn more).
contract SteelMineV2 is Ownable, ReentrancyGuard {
    uint256 public constant BPS = 10_000;
    uint256 internal constant WAD = 1e18;

    // ── immutables ──
    ISteelToken public immutable steel;
    uint256 public immutable SQUARES;
    uint256 public immutable miningCap;
    uint256 public immutable genesis;
    uint256 public immutable roundDuration;
    uint256 public immutable drandGenesis;
    uint256 public immutable drandPeriod;
    uint64 public immutable drandSafety;

    // ── wiring ──
    IVeSteelV2 public veSteel;
    IDrandOracle public drand;
    address public devAddr;

    // ── tunable ──
    uint256 public protocolFeeBps = 1000; // 10% of pot
    uint256 public jackpotFeeBps = 200; // 2% of pot -> motherlode ETH
    uint256 public steelPerRound = 1e18; // base winner STEEL / round
    uint256 public devBps = 800; // +8% of base -> dev lock
    uint256 public motherlodeBps = 1000; // +10% of base -> motherlode STEEL (0.1/round)
    uint256 public jackpotOdds = 625; // 1/625 payout roll
    uint256 public refiningFeeBps = 1000; // 10% on refine
    uint256 public minCommit = 1e14; // 0.0001 ETH / square
    uint256 public bettingDuration; // betting closes this many secs into a round (reveal = rest)

    // ── round state ──
    struct Round {
        uint128 totalPot;
        uint128 winnersPool; // ETH to winners (90% + carry, + motherlode on hit)
        uint128 winnerPot; // ETH bet on winning square
        uint128 steelForWinners; // unrefined STEEL for winners (+ motherlode on hit)
        uint64 drandRound;
        uint8 winner;
        bool resolved;
        bool hasWinner;
        bool solo; // single-miner round
        bool jackpotHit;
        address soloWinner;
    }

    mapping(uint256 => Round) public rounds;
    mapping(uint256 => mapping(uint256 => uint256)) public squarePot; // round => sq => ETH
    mapping(bytes32 => uint256) internal _bet; // (round,sq,user) => ETH
    mapping(bytes32 => uint256) internal _userRound; // (round,user) => ETH
    mapping(bytes32 => bool) internal _isBettor; // (round,sq,user)
    mapping(uint256 => mapping(uint256 => address[])) internal _bettors; // round => sq => users
    mapping(bytes32 => bool) internal _claimedRound; // (round,user) => claimed

    uint256 public emittedTotal; // STEEL reserved against cap (1.12x basis)
    uint256 public motherlodeEth;
    uint256 public motherlodeSteel;
    uint256 public carryEth; // no-winner ETH rolled forward
    uint256 public carrySteel;

    // ── payouts + refining ──
    mapping(address => uint256) public pendingEth; // withdrawable ETH winnings
    // ORE-style refining accumulator
    struct Miner {
        uint256 unrefined; // unminted STEEL
        uint256 indexSnapshot;
        uint256 refinedAccrued; // dividends earned from others' refine fees
    }
    mapping(address => Miner) public miners;
    uint256 public globalIndex; // 1e18-scaled dividend index
    uint256 public totalUnrefined;

    // ── events ──
    event Committed(uint256 indexed roundId, address indexed user, uint256 amount, uint8[] squares);
    event Resolved(uint256 indexed roundId, uint8 winner, bool hasWinner, bool solo, bool jackpot, uint256 pot);
    event Claimed(uint256 indexed roundId, address indexed user, uint256 ethWon, uint256 steelUnrefined);
    event Refined(address indexed user, uint256 steelOut, uint256 fee, uint256 ethOut);
    event EthClaimed(address indexed user, uint256 amount);
    event ParamsChanged();

    error BadSquare();
    error NoSquares();
    error TooSmall();
    error NotStarted();
    error RoundOpen();
    error AlreadyResolved();
    error NotResolved();
    error NotReady();
    error NoWinner();
    error NothingToClaim();
    error AlreadyClaimed();
    error BettingClosed();
    error BadParam();

    constructor(
        ISteelToken _steel,
        IDrandOracle _drand,
        address _devAddr,
        uint256 _squares,
        uint256 _miningCap,
        uint256 _roundDuration,
        uint256 _drandGenesis,
        uint256 _drandPeriod,
        uint64 _drandSafety,
        address _owner
    ) Ownable(_owner) {
        if (_squares == 0 || _squares > 256 || _devAddr == address(0)) revert BadParam();
        if (_roundDuration < 10 || _drandPeriod == 0) revert BadParam();
        steel = _steel;
        drand = _drand;
        devAddr = _devAddr;
        SQUARES = _squares;
        miningCap = _miningCap;
        roundDuration = _roundDuration;
        genesis = block.timestamp;
        drandGenesis = _drandGenesis;
        drandPeriod = _drandPeriod;
        drandSafety = _drandSafety;
        bettingDuration = _roundDuration; // default: betting open whole round; tune via setBettingWindow
    }

    // ── views ──
    function currentRound() public view returns (uint256) {
        if (block.timestamp < genesis) return 0;
        return (block.timestamp - genesis) / roundDuration;
    }

    function roundEndsAt(uint256 id) public view returns (uint256) {
        return genesis + (id + 1) * roundDuration;
    }

    function timeLeft() external view returns (uint256) {
        uint256 e = roundEndsAt(currentRound());
        return block.timestamp >= e ? 0 : e - block.timestamp;
    }

    function bettingEndsAt(uint256 id) public view returns (uint256) {
        return genesis + id * roundDuration + bettingDuration;
    }

    /// @notice Secs until betting closes for the current round (0 = in reveal phase).
    function bettingLeft() external view returns (uint256) {
        uint256 e = bettingEndsAt(currentRound());
        return block.timestamp >= e ? 0 : e - block.timestamp;
    }

    function drandRoundFor(uint256 id) public view returns (uint64) {
        // beacon finalizes just after BETTING closes (unknowable while betting is
        // open) so the winner can be resolved during the reveal window.
        uint256 e = bettingEndsAt(id);
        if (e <= drandGenesis) return drandSafety;
        return uint64((e - drandGenesis) / drandPeriod) + drandSafety;
    }

    function getRound(uint256 id) external view returns (Round memory) {
        return rounds[id];
    }

    /// @notice Number of miners who bet on a resolved round's winning square.
    function winnersCount(uint256 id) external view returns (uint256) {
        Round storage r = rounds[id];
        if (!r.resolved || !r.hasWinner) return 0;
        return _bettors[id][r.winner].length;
    }

    /// @notice The i-th miner on a resolved round's winning square.
    function winnerAt(uint256 id, uint256 i) external view returns (address) {
        return _bettors[id][rounds[id].winner][i];
    }

    function betOf(uint256 id, uint256 sq, address u) external view returns (uint256) {
        return _bet[keccak256(abi.encode(id, sq, u))];
    }

    function userRoundTotal(uint256 id, address u) external view returns (uint256) {
        return _userRound[keccak256(abi.encode(id, u))];
    }

    /// @notice Refinable STEEL (unrefined + accrued dividends) and its 10% fee.
    function refinable(address u) public view returns (uint256 gross, uint256 fee, uint256 net) {
        Miner memory m = miners[u];
        uint256 accrued = m.refinedAccrued + (m.unrefined * (globalIndex - m.indexSnapshot)) / WAD;
        fee = (m.unrefined * refiningFeeBps) / BPS;
        gross = m.unrefined + accrued;
        net = gross - fee;
    }

    /// @notice A user's share of a resolved round (informational). Winnings are
    ///         auto-settled into `pendingEth` / unrefined at resolve, so this is a
    ///         historical breakdown, not an outstanding claim.
    function roundShare(uint256 id, address u) external view returns (uint256 ethWon, uint256 steelWon) {
        Round storage r = rounds[id];
        if (!r.resolved || !r.hasWinner) return (0, 0);
        uint256 b = _bet[keccak256(abi.encode(id, uint256(r.winner), u))];
        if (b == 0 || r.winnerPot == 0) return (0, 0);
        ethWon = (uint256(r.winnersPool) * b) / r.winnerPot;
        if (r.solo) steelWon = u == r.soloWinner ? r.steelForWinners : 0;
        else steelWon = (uint256(r.steelForWinners) * b) / r.winnerPot;
    }

    // ── play ──
    function commit(uint8[] calldata squares) external payable nonReentrant {
        _commit(msg.sender, msg.value, squares);
    }

    /// @notice Commit ETH attributed to `bettor` — winnings + STEEL auto-settle to them.
    ///         Whoever calls funds the bet; used by the auto-deploy keeper.
    function commitFor(address bettor, uint8[] calldata squares) external payable nonReentrant {
        _commit(bettor, msg.value, squares);
    }

    function _commit(address bettor, uint256 value, uint8[] memory squares) internal {
        if (block.timestamp < genesis) revert NotStarted();
        uint256 n = squares.length;
        if (n == 0) revert NoSquares();
        uint256 per = value / n;
        if (per < minCommit) revert TooSmall();

        uint256 rid = currentRound();
        if (block.timestamp >= genesis + rid * roundDuration + bettingDuration) revert BettingClosed();
        uint256 used;
        for (uint256 i; i < n; i++) {
            uint8 sq = squares[i];
            if (sq >= SQUARES) revert BadSquare();
            bytes32 bk = keccak256(abi.encode(rid, uint256(sq), bettor));
            if (_bet[bk] == 0 && !_isBettor[bk]) {
                _isBettor[bk] = true;
                _bettors[rid][sq].push(bettor);
            }
            _bet[bk] += per;
            squarePot[rid][sq] += per;
            used += per;
        }
        uint256 rem = value - used;
        if (rem > 0) {
            uint8 f = squares[0];
            _bet[keccak256(abi.encode(rid, uint256(f), bettor))] += rem;
            squarePot[rid][f] += rem;
        }
        rounds[rid].totalPot += uint128(value);
        _userRound[keccak256(abi.encode(rid, bettor))] += value;
        emit Committed(rid, bettor, value, squares);
    }

    // ── auto-deploy (keeper commits for you each round from an escrow balance) ──
    struct AutoSub {
        uint128 amountPerSquare;
        uint64 roundsLeft; // ignored when reload = true
        uint64 lastRound; // last round executed (or subscribe round) — one commit per round
        bool active;
        bool reload; // run indefinitely while the escrow can cover a round
        uint8[] squares;
    }

    mapping(address => AutoSub) internal _autoSub;
    mapping(address => uint256) public autoBalance;
    address[] public autoList;
    mapping(address => bool) internal _autoListed;
    uint256 public autoFee; // flat ETH per executed round -> devAddr (keeper gas). default 0

    event AutoSubscribed(address indexed user, uint256 amountPerSquare, uint256 rounds);
    event AutoTopUp(address indexed user, uint256 amount);
    event AutoCancelled(address indexed user, uint256 refunded);
    event AutoExecuted(address indexed user, uint256 indexed round, uint256 spent);

    /// @notice Escrow ETH and auto-commit `squares` at `amountPerSquare` for `roundsCount`
    ///         future rounds. The keeper fires each round; winnings auto-settle to you.
    ///         Starts next round. Must fully fund the plan (perRound * rounds).
    function autoSubscribe(uint8[] calldata squares, uint256 amountPerSquare, uint256 roundsCount, bool reload)
        external
        payable
        nonReentrant
    {
        uint256 n = squares.length;
        if (n == 0 || n > SQUARES) revert NoSquares();
        if (amountPerSquare < minCommit) revert TooSmall();
        for (uint256 i; i < n; i++) if (squares[i] >= SQUARES) revert BadSquare();

        autoBalance[msg.sender] += msg.value;
        uint256 perRound = amountPerSquare * n + autoFee;
        // reload: fund at least one round and keep going; fixed: fully fund the plan
        if (reload) {
            if (autoBalance[msg.sender] < perRound) revert TooSmall();
        } else {
            if (roundsCount == 0) revert BadParam();
            if (autoBalance[msg.sender] < perRound * roundsCount) revert TooSmall();
        }

        AutoSub storage s = _autoSub[msg.sender];
        delete s.squares;
        for (uint256 i; i < n; i++) s.squares.push(squares[i]);
        s.amountPerSquare = uint128(amountPerSquare);
        s.roundsLeft = reload ? 0 : uint64(roundsCount);
        s.reload = reload;
        s.active = true;
        s.lastRound = uint64(currentRound()); // skip the in-progress round, start next

        if (!_autoListed[msg.sender]) {
            _autoListed[msg.sender] = true;
            autoList.push(msg.sender);
        }
        emit AutoSubscribed(msg.sender, amountPerSquare, roundsCount);
    }

    function autoTopUp() external payable nonReentrant {
        autoBalance[msg.sender] += msg.value;
        emit AutoTopUp(msg.sender, msg.value);
    }

    function autoCancel() external nonReentrant {
        _autoSub[msg.sender].active = false;
        uint256 bal = autoBalance[msg.sender];
        if (bal > 0) {
            autoBalance[msg.sender] = 0;
            (bool ok,) = payable(msg.sender).call{value: bal}("");
            require(ok, "ETH fail");
        }
        emit AutoCancelled(msg.sender, bal);
    }

    /// @notice Keeper entrypoint: fire every ready subscriber for the current round.
    function autoExecuteMany(address[] calldata users) external nonReentrant {
        uint256 rid = currentRound();
        if (block.timestamp >= genesis + rid * roundDuration + bettingDuration) return; // betting closed
        for (uint256 i; i < users.length; i++) _autoExec(users[i], rid);
    }

    function autoExecute(address user) external nonReentrant {
        uint256 rid = currentRound();
        if (block.timestamp >= genesis + rid * roundDuration + bettingDuration) revert BettingClosed();
        _autoExec(user, rid);
    }

    function _autoExec(address user, uint256 rid) internal {
        AutoSub storage s = _autoSub[user];
        if (!s.active) return;
        if (!s.reload && s.roundsLeft == 0) return;
        if (uint64(rid) == s.lastRound) return; // already done this round
        uint256 cost = uint256(s.amountPerSquare) * s.squares.length;
        uint256 total = cost + autoFee;
        if (autoBalance[user] < total) {
            s.active = false; // out of funds -> stop
            return;
        }
        autoBalance[user] -= total;
        if (autoFee > 0) pendingEth[devAddr] += autoFee; // keeper/dev compensation
        s.lastRound = uint64(rid);
        if (!s.reload) {
            s.roundsLeft -= 1;
            if (s.roundsLeft == 0) s.active = false;
        }
        _commit(user, cost, s.squares);
        emit AutoExecuted(user, rid, cost);
    }

    // auto views
    function autoInfo(address u)
        external
        view
        returns (uint256 amountPerSquare, uint256 roundsLeft, uint256 lastRound, bool active, uint256 balance, bool reload)
    {
        AutoSub storage s = _autoSub[u];
        return (s.amountPerSquare, s.roundsLeft, s.lastRound, s.active, autoBalance[u], s.reload);
    }

    function autoSquares(address u) external view returns (uint8[] memory) {
        return _autoSub[u].squares;
    }

    function autoCount() external view returns (uint256) {
        return autoList.length;
    }

    function autoReady(address u) public view returns (bool) {
        AutoSub storage s = _autoSub[u];
        if (!s.active) return false;
        if (!s.reload && s.roundsLeft == 0) return false;
        uint256 rid = currentRound();
        if (uint64(rid) == s.lastRound) return false;
        if (block.timestamp >= genesis + rid * roundDuration + bettingDuration) return false;
        return autoBalance[u] >= uint256(s.amountPerSquare) * s.squares.length + autoFee;
    }

    /// @notice Users the keeper should fire this round (for off-chain iteration).
    function autoReadyList() external view returns (address[] memory ready) {
        uint256 len = autoList.length;
        address[] memory tmp = new address[](len);
        uint256 c;
        for (uint256 i; i < len; i++) {
            if (autoReady(autoList[i])) tmp[c++] = autoList[i];
        }
        ready = new address[](c);
        for (uint256 i; i < c; i++) ready[i] = tmp[i];
    }

    function resolveRound(uint256 rid) external nonReentrant {
        Round storage r = rounds[rid];
        if (r.resolved) revert AlreadyResolved();
        if (block.timestamp < bettingEndsAt(rid)) revert RoundOpen(); // resolvable once betting closes

        uint64 dr = drandRoundFor(rid);
        bytes32 rand = drand.randomness(dr);
        if (rand == bytes32(0)) revert NotReady();
        r.resolved = true;
        r.drandRound = dr;

        uint256 pot = r.totalPot;
        uint8 win = uint8(uint256(rand) % SQUARES);
        r.winner = win;
        uint256 winnerPot = squarePot[rid][win];
        r.winnerPot = uint128(winnerPot);

        // ── STEEL emission (reserve 1.12x against cap) ──
        (uint256 winnerSteel, uint256 devSteel, uint256 mlodeSteel) = _emit();

        if (pot == 0) {
            // nothing wagered — carry STEEL forward, no fees
            carrySteel += winnerSteel + mlodeSteel;
            if (devSteel > 0) _mintDev(devSteel);
            emit Resolved(rid, win, false, false, false, 0);
            return;
        }

        // ── ETH fee split ──
        uint256 fee = (pot * protocolFeeBps) / BPS;
        uint256 jackEth = (pot * jackpotFeeBps) / BPS;
        uint256 stakerEth = fee - jackEth;
        uint256 winnersEth = pot - fee;

        if (devSteel > 0) _mintDev(devSteel); // credit dev weight first so it shares this round's fee
        if (stakerEth > 0 && address(veSteel) != address(0)) veSteel.notifyReward{value: stakerEth}();
        else motherlodeEth += stakerEth; // no stakers/dev -> park in motherlode
        motherlodeEth += jackEth;
        motherlodeSteel += mlodeSteel;

        if (winnerPot == 0) {
            // no winner: roll ETH + winner STEEL into the carry pools
            carryEth += winnersEth;
            carrySteel += winnerSteel;
            emit Resolved(rid, win, false, false, false, pot);
            return;
        }

        r.hasWinner = true;
        uint256 poolEth = winnersEth + carryEth;
        uint256 poolSteel = winnerSteel + carrySteel;
        carryEth = 0;
        carrySteel = 0;

        // ── jackpot roll (1/625) ──
        if (uint256(keccak256(abi.encode(rand, "jackpot"))) % jackpotOdds == 0) {
            r.jackpotHit = true;
            poolEth += motherlodeEth;
            poolSteel += motherlodeSteel;
            emittedTotal += motherlodeSteel; // reserve the motherlode STEEL now
            motherlodeEth = 0;
            motherlodeSteel = 0;
        }

        // ── single-miner roll (50%) ──
        if (uint256(keccak256(abi.encode(rand, "solo"))) % 2 == 0) {
            r.solo = true;
            r.soloWinner = _pickSolo(rid, win, winnerPot, uint256(keccak256(abi.encode(rand, "pick"))));
        }

        r.winnersPool = uint128(poolEth);
        r.steelForWinners = uint128(poolSteel);

        // ── auto-settle: credit winners now so claiming is always one tx ──
        _settleWinners(rid, win, poolEth, poolSteel, r.solo, r.soloWinner, winnerPot);

        emit Resolved(rid, win, true, r.solo, r.jackpotHit, pot);
    }

    /// @dev Push each winner's ETH into `pendingEth` and STEEL into their unrefined
    ///      balance at resolve time. Winning-square bettors are unique in `_bettors`
    ///      (deduped on commit), so a single pass credits everyone with no double-count.
    ///      Solo takes the whole pool; split shares pro-rata by bet.
    function _settleWinners(
        uint256 rid,
        uint8 win,
        uint256 poolEth,
        uint256 poolSteel,
        bool solo,
        address soloW,
        uint256 winnerPot
    ) internal {
        if (winnerPot == 0) return;
        if (solo) {
            if (poolEth > 0) _creditWinnerEth(soloW, poolEth);
            if (poolSteel > 0) _accrueUnrefined(soloW, poolSteel);
            return;
        }
        address[] storage bs = _bettors[rid][win];
        uint256 len = bs.length;
        for (uint256 i; i < len; i++) {
            address u = bs[i];
            uint256 b = _bet[keccak256(abi.encode(rid, uint256(win), u))];
            if (b == 0) continue;
            uint256 e = (poolEth * b) / winnerPot;
            uint256 s = (poolSteel * b) / winnerPot;
            if (e > 0) _creditWinnerEth(u, e);
            if (s > 0) _accrueUnrefined(u, s);
        }
    }

    /// @dev ETH winnings compound straight into an ACTIVE auto-deploy escrow so the
    ///      loop self-funds; for everyone else they land in the claimable balance.
    function _creditWinnerEth(address u, uint256 amt) internal {
        if (_autoSub[u].active) autoBalance[u] += amt;
        else pendingEth[u] += amt;
    }

    /// @dev size + reserve the base emission (winner 100% / dev 8% / motherlode 4%).
    function _emit() internal returns (uint256 winnerSteel, uint256 devSteel, uint256 mlodeSteel) {
        uint256 mult = BPS + devBps + motherlodeBps; // 11200
        uint256 remaining = miningCap - emittedTotal;
        uint256 maxBudget = (remaining * BPS) / mult;
        uint256 budget = steelPerRound < maxBudget ? steelPerRound : maxBudget;
        if (budget == 0) return (0, 0, 0);
        winnerSteel = budget;
        devSteel = (budget * devBps) / BPS;
        mlodeSteel = (budget * motherlodeBps) / BPS;
        // reserve winner + dev now; motherlode reserved when it pays out
        emittedTotal += winnerSteel + devSteel;
    }

    function _mintDev(uint256 amt) internal {
        if (address(veSteel) != address(0)) {
            steel.mint(address(veSteel), amt);
            veSteel.creditDevLock(amt);
        } else {
            steel.mint(devAddr, amt);
        }
    }

    /// @dev weighted-by-bet pick among the winning square's bettors.
    function _pickSolo(uint256 rid, uint256 sq, uint256 winnerPot, uint256 seed)
        internal
        view
        returns (address)
    {
        uint256 target = seed % winnerPot;
        address[] storage bs = _bettors[rid][sq];
        uint256 acc;
        for (uint256 i; i < bs.length; i++) {
            acc += _bet[keccak256(abi.encode(rid, sq, bs[i]))];
            if (target < acc) return bs[i];
        }
        return bs.length > 0 ? bs[bs.length - 1] : address(0);
    }

    // ── claim / refine (winnings are auto-settled at resolve; just withdraw) ──

    /// @notice Withdraw ETH winnings only (STEEL stays unrefined, earning dividends).
    function claimEth() external nonReentrant {
        uint256 amt = pendingEth[msg.sender];
        if (amt == 0) revert NothingToClaim();
        pendingEth[msg.sender] = 0;
        (bool ok,) = payable(msg.sender).call{value: amt}("");
        require(ok, "ETH fail");
        emit EthClaimed(msg.sender, amt);
    }

    /// @notice Refine STEEL (mint it) — 10% fee shared to other unrefined holders —
    ///         and withdraw ETH winnings in the same call.
    function claimAll() external nonReentrant {
        _checkpoint(msg.sender);
        Miner storage m = miners[msg.sender];
        uint256 unref = m.unrefined;
        uint256 accrued = m.refinedAccrued;
        uint256 gross = unref + accrued;
        if (gross == 0 && pendingEth[msg.sender] == 0) revert NothingToClaim();

        uint256 fee = (unref * refiningFeeBps) / BPS;
        uint256 out = gross - fee;

        m.unrefined = 0;
        m.refinedAccrued = 0;
        totalUnrefined -= unref;
        if (fee > 0 && totalUnrefined > 0) globalIndex += (fee * WAD) / totalUnrefined;
        // if no one left to receive, fee stays unminted (reduces circulating; safe)

        if (out > 0) steel.mint(msg.sender, out);

        uint256 eth = pendingEth[msg.sender];
        if (eth > 0) {
            pendingEth[msg.sender] = 0;
            (bool ok,) = payable(msg.sender).call{value: eth}("");
            require(ok, "ETH fail");
        }
        emit Refined(msg.sender, out, fee, eth);
    }

    function _accrueUnrefined(address u, uint256 amt) internal {
        _checkpoint(u);
        miners[u].unrefined += amt;
        totalUnrefined += amt;
    }

    function _checkpoint(address u) internal {
        Miner storage m = miners[u];
        if (m.unrefined > 0) {
            m.refinedAccrued += (m.unrefined * (globalIndex - m.indexSnapshot)) / WAD;
        }
        m.indexSnapshot = globalIndex;
    }

    // ── admin ──
    function setVeSteel(IVeSteelV2 v) external onlyOwner {
        veSteel = v;
    }

    function setDrand(IDrandOracle d) external onlyOwner {
        drand = d;
    }

    function setDevAddr(address d) external onlyOwner {
        if (d == address(0)) revert BadParam();
        devAddr = d;
    }

    function setAutoFee(uint256 f) external onlyOwner {
        if (f > 0.01 ether) revert BadParam();
        autoFee = f;
    }

    // ── one-time migration seed (carry state from a previous mine) ──
    bool public seeded;

    /// @notice Carry each holder's claimable STEEL over as fresh unrefined balance.
    ///         Reserved against the cap so refining mints correctly. Dev-only, one-shot.
    function seedUnrefined(address[] calldata users, uint256[] calldata amounts) external onlyOwner {
        if (seeded) revert BadParam();
        if (users.length != amounts.length) revert BadParam();
        for (uint256 i; i < users.length; i++) {
            uint256 amt = amounts[i];
            if (amt == 0) continue;
            _accrueUnrefined(users[i], amt);
            emittedTotal += amt; // it was already emitted on the old mine
        }
    }

    /// @notice Carry the motherlode over (ETH sent with the call, STEEL as param).
    function seedMotherlode(uint256 steel) external payable onlyOwner {
        if (seeded) revert BadParam();
        motherlodeEth += msg.value;
        motherlodeSteel += steel;
    }

    function finalizeSeed() external onlyOwner {
        seeded = true;
    }

    function setEconomics(
        uint256 _protocolFeeBps,
        uint256 _jackpotFeeBps,
        uint256 _steelPerRound,
        uint256 _devBps,
        uint256 _motherlodeBps,
        uint256 _jackpotOdds,
        uint256 _refiningFeeBps
    ) external onlyOwner {
        if (_protocolFeeBps > 2000 || _jackpotFeeBps > _protocolFeeBps) revert BadParam();
        if (_steelPerRound > 1000e18 || _devBps > 2000 || _motherlodeBps > 2000) revert BadParam();
        if (_jackpotOdds == 0 || _refiningFeeBps > 2000) revert BadParam();
        protocolFeeBps = _protocolFeeBps;
        jackpotFeeBps = _jackpotFeeBps;
        steelPerRound = _steelPerRound;
        devBps = _devBps;
        motherlodeBps = _motherlodeBps;
        jackpotOdds = _jackpotOdds;
        refiningFeeBps = _refiningFeeBps;
        emit ParamsChanged();
    }

    function setMinCommit(uint256 v) external onlyOwner {
        if (v > 1 ether) revert BadParam();
        minCommit = v;
        emit ParamsChanged();
    }

    /// @notice Betting closes this many secs into a round; the rest is the reveal phase.
    function setBettingWindow(uint256 _bettingDuration) external onlyOwner {
        if (_bettingDuration < 10 || _bettingDuration > roundDuration) revert BadParam();
        bettingDuration = _bettingDuration;
        emit ParamsChanged();
    }
}

