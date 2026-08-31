// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

//
//                         ,(
//                        ((
//                         \\
//                     .---\\---.
//                    /    ``    \
//                   |            |
//                   |            |
//                    \          /
//                     '.______.'
//
//              O R C H A R D  ·  $SEED
//             Plant ETH. Harvest $AAPL.
//
//                https://orchard.gold
//            https://x.com/orcharddotgold
//

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ISwapper} from "./interfaces/ISwapper.sol";
import {IStaking} from "./interfaces/IStaking.sol";
import {IRandomness} from "./interfaces/IRandomness.sol";

contract Orchard is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    error InvalidPlot();
    error InvalidPlotMask();
    error InvalidRoundCount();
    error TooManySlots();
    error BelowMinPlant();
    error SowingClosed();
    error RoundNotResolved(uint256 round);
    error AlreadyClaimed(uint256 round);
    error NothingToClaim();
    error InsufficientOutput();
    error ZeroAddress();
    error BpsTooHigh();
    error ZeroOdds();
    error NotAuthorized();
    error MinPlantTooHigh();
    error RenounceDisabled();

    event Planted(address indexed player, uint256 indexed round, uint8 plot, uint256 ethIn, uint256 stake);
    event PlantedMany(
        address indexed player,
        uint256 indexed startRound,
        uint16 roundCount,
        uint32 plotMask,
        uint256 ethIn,
        uint256 totalStake
    );
    event Sealed(uint256 indexed round, uint64 sealBlock);
    event Revealed(uint256 indexed round, uint8 winningPlot, uint256 winningStake, uint256 netLossPool);
    event CropVaulted(uint256 indexed round, uint8 winningPlot, uint256 crop);
    event RoundVoided(uint256 indexed round);
    event JackpotHit(uint256 indexed round, uint256 amount);
    event Claimed(address indexed player, uint256 aaplAmount, uint256 juiceFee);
    event BuybackBurned(uint256 aaplIn, uint256 seedBurned);
    event TreasuryCollected(address indexed to, uint256 aaplAmount);
    event AdminCollected(address indexed to, uint256 aaplAmount);
    event StakingFlushed(uint256 aaplAmount);
    event MinPlantEthSet(uint256 minPlantEth);
    event RakeBpsSet(uint16 bps);
    event AdminFeeBpsSet(uint16 bps);
    event JackpotBpsSet(uint16 bps);
    event JackpotOddsSet(uint32 odds);
    event SwapperSet(address swapper);
    event StakingSet(address staking);
    event RandomnessSet(address randomness);
    event KeeperSet(address keeper);

    uint8 public constant PLOTS = 25;
    uint256 public constant ROUND_SECONDS = 75;
    uint256 public constant SOW_SECONDS = 60;
    uint256 public constant MAX_PLANT_SLOTS = 250;
    uint16 public constant MAX_RAKE_BPS = 2_000;
    uint16 public constant MAX_ADMIN_FEE_BPS = 500;
    uint256 public constant MAX_MIN_PLANT_ETH = 1 ether;
    uint16 public constant STAKERS_BPS = 1_000;
    uint16 public constant JUICE_BPS = 1_000;
    uint256 private constant BPS = 10_000;
    uint256 private constant INDEX_SCALE = 1e18;
    address private constant DEAD = 0x000000000000000000000000000000000000dEaD;

    IERC20 public immutable aapl;
    IERC20 public immutable seed;
    uint256 public immutable genesis;

    ISwapper public swapper;
    IRandomness public randomness;
    IStaking public staking;
    address public keeper;
    uint256 public minPlantEth;
    uint16 public rakeBps;
    uint16 public adminFeeBps;
    uint16 public jackpotBps;
    uint32 public jackpotOdds;

    struct Round {
        uint64 sealBlock;
        bool revealed;
        bool voided;
        uint8 winningPlot;
        uint16 rakeBps;
        uint16 jackpotBps;
        uint32 jackpotOdds;
        uint256 totalStake;
        uint256 winningStake;
        uint256 netLossPool;
        uint256 entryIndex;
        uint256 jackpotWon;
    }

    mapping(uint256 => Round) public rounds;
    mapping(uint256 => mapping(uint8 => uint256)) public plotStake;
    mapping(uint256 => mapping(address => mapping(uint8 => uint256))) public stakeOf;
    mapping(uint256 => mapping(address => uint256)) public playerTotal;
    mapping(uint256 => mapping(address => bool)) public roundClaimed;
    mapping(uint256 => address[]) private roundMiners;
    mapping(uint256 => mapping(address => uint32)) public playerPlots;
    uint256 public treasuryAccrued;
    uint256 public stakingAccrued;
    uint256 public adminAccrued;
    uint256 public jackpotAccrued;
    uint256 public juiceIndex;
    uint256 public unclaimedShares;
    uint256 public nextToResolve;

    constructor(IERC20 aapl_, IERC20 seed_, ISwapper swapper_, IRandomness randomness_, uint16 rakeBps_, address owner_)
        Ownable(owner_)
    {
        if (address(aapl_) == address(0) || address(seed_) == address(0)) revert ZeroAddress();
        aapl = aapl_;
        seed = seed_;
        genesis = block.timestamp;
        _setSwapper(swapper_);
        _setRandomness(randomness_);
        _setMinPlantEth(0.0005 ether);
        _setRakeBps(rakeBps_);
        _setAdminFeeBps(100);
        _setJackpotBps(5_000);
        _setJackpotOdds(500);
    }

    function plant(uint8 plot, uint256 minAaplOut) external payable nonReentrant {
        if (plot >= PLOTS) revert InvalidPlot();
        if (msg.value < minPlantEth) revert BelowMinPlant();
        if ((block.timestamp - genesis) % ROUND_SECONDS >= SOW_SECONDS) revert SowingClosed();
        _crank(2);

        uint256 balanceBefore = aapl.balanceOf(address(this));
        swapper.swapEthForAapl{value: msg.value}(minAaplOut);
        uint256 bought = aapl.balanceOf(address(this)) - balanceBefore;
        if (bought < minAaplOut || bought == 0) revert InsufficientOutput();

        (uint256 round, uint256 stake) = _credit(plot, bought);
        emit Planted(msg.sender, round, plot, msg.value, stake);
    }

    function plantMany(uint32 plotMask, uint16 roundCount, uint256 minAaplOut) external payable nonReentrant {
        uint256 slots = _checkSpread(plotMask, roundCount);
        if (msg.value < minPlantEth * slots) revert BelowMinPlant();
        _crank(2);

        uint256 balanceBefore = aapl.balanceOf(address(this));
        swapper.swapEthForAapl{value: msg.value}(minAaplOut);
        uint256 bought = aapl.balanceOf(address(this)) - balanceBefore;
        if (bought < minAaplOut || bought == 0) revert InsufficientOutput();

        (uint256 startRound, uint256 totalStake) = _creditMany(plotMask, roundCount, slots, bought);
        emit PlantedMany(msg.sender, startRound, roundCount, plotMask, msg.value, totalStake);
    }

    function _credit(uint8 plot, uint256 bought) private returns (uint256 round, uint256 stake) {
        uint256 adminCut = (bought * adminFeeBps) / BPS;
        adminAccrued += adminCut;
        stake = bought - adminCut;
        round = currentRound();
        _stake(round, plot, stake);
    }

    function _stake(uint256 round, uint8 plot, uint256 stake) private {
        if (playerTotal[round][msg.sender] == 0) roundMiners[round].push(msg.sender);
        stakeOf[round][msg.sender][plot] += stake;
        plotStake[round][plot] += stake;
        playerTotal[round][msg.sender] += stake;
        playerPlots[round][msg.sender] |= uint32(1) << plot;
        rounds[round].totalStake += stake;
    }

    function _checkSpread(uint32 plotMask, uint16 roundCount) private pure returns (uint256 slots) {
        if (plotMask == 0 || plotMask >> PLOTS != 0) revert InvalidPlotMask();
        if (roundCount == 0) revert InvalidRoundCount();
        uint256 plots = 0;
        for (uint32 m = plotMask; m != 0; m &= m - 1) {
            plots++;
        }
        slots = plots * roundCount;
        if (slots > MAX_PLANT_SLOTS) revert TooManySlots();
    }

    function _creditMany(uint32 plotMask, uint16 roundCount, uint256 slots, uint256 bought)
        private
        returns (uint256 startRound, uint256 totalStake)
    {
        uint256 adminCut = (bought * adminFeeBps) / BPS;
        adminAccrued += adminCut;
        totalStake = bought - adminCut;
        uint256 perSlot = totalStake / slots;
        if (perSlot == 0) revert InsufficientOutput();
        startRound = currentRound();
        if ((block.timestamp - genesis) % ROUND_SECONDS >= SOW_SECONDS) startRound += 1;
        uint256 dust = totalStake - perSlot * slots;
        for (uint256 r = 0; r < roundCount; r++) {
            for (uint8 p = 0; p < PLOTS; p++) {
                if (plotMask & (uint32(1) << p) == 0) continue;
                _stake(startRound + r, p, perSlot + dust);
                dust = 0;
            }
        }
    }

    function crank(uint256 maxRounds) public {
        _crank(maxRounds);
    }

    function _crank(uint256 maxRounds) private {
        uint256 round = nextToResolve;
        uint256 limit = currentRound();
        if ((block.timestamp - genesis) % ROUND_SECONDS >= SOW_SECONDS) limit += 1;
        for (uint256 i = 0; i < maxRounds && round < limit; i++) {
            Round storage r = rounds[round];
            if (r.totalStake == 0) {
                r.voided = true;
                emit RoundVoided(round);
                round++;
                continue;
            }
            if (r.sealBlock == 0) {
                r.sealBlock = randomness.commit();
                r.rakeBps = rakeBps;
                r.jackpotBps = jackpotBps;
                r.jackpotOdds = jackpotOdds;
                emit Sealed(round, r.sealBlock);
                break;
            }
            bytes32 seed_ = randomness.seedFor(round, r.sealBlock);
            if (seed_ == bytes32(0)) {
                if (randomness.expired(r.sealBlock)) {
                    r.voided = true;
                    emit RoundVoided(round);
                    round++;
                    continue;
                }
                break;
            }
            _reveal(round, r, seed_);
            round++;
        }
        nextToResolve = round;
    }

    function _reveal(uint256 round, Round storage r, bytes32 seed_) private {
        uint8 winningPlot = uint8(uint256(seed_) % PLOTS);
        uint256 winningStake = plotStake[round][winningPlot];
        if (winningStake == 0) {
            uint256 crop = r.totalStake;
            jackpotAccrued += crop;
            r.revealed = true;
            r.winningPlot = winningPlot;
            emit Revealed(round, winningPlot, 0, 0);
            emit CropVaulted(round, winningPlot, crop);
            return;
        }
        uint256 lossPool = r.totalStake - winningStake;
        uint256 rake = (lossPool * r.rakeBps) / BPS;
        uint256 toStakers = (rake * STAKERS_BPS) / BPS;
        uint256 toJackpot = (rake * r.jackpotBps) / BPS;
        stakingAccrued += toStakers;
        jackpotAccrued += toJackpot;
        treasuryAccrued += rake - toStakers - toJackpot;

        uint256 netLossPool = lossPool - rake;
        uint256 jackpot = jackpotAccrued;
        if (jackpot != 0 && uint256(keccak256(abi.encode(seed_, "JACKPOT"))) % r.jackpotOdds == 0) {
            jackpotAccrued = 0;
            netLossPool += jackpot;
            r.jackpotWon = jackpot;
            emit JackpotHit(round, jackpot);
        }
        unclaimedShares += winningStake + netLossPool;
        r.entryIndex = juiceIndex;

        r.revealed = true;
        r.winningPlot = winningPlot;
        r.winningStake = winningStake;
        r.netLossPool = netLossPool;
        emit Revealed(round, winningPlot, winningStake, netLossPool);
    }

    function claim(uint256[] calldata roundIds) external nonReentrant {
        uint256 refunds = 0;
        uint256 grossTotal = 0;
        for (uint256 i = 0; i < roundIds.length; i++) {
            uint256 round = roundIds[i];
            Round storage r = rounds[round];
            if (!r.revealed && !r.voided) revert RoundNotResolved(round);
            if (roundClaimed[round][msg.sender]) revert AlreadyClaimed(round);
            roundClaimed[round][msg.sender] = true;
            if (r.voided) {
                refunds += playerTotal[round][msg.sender];
                continue;
            }
            uint256 winStake = stakeOf[round][msg.sender][r.winningPlot];
            if (winStake == 0) continue;
            uint256 shares = winStake + (r.netLossPool * winStake) / r.winningStake;
            grossTotal += shares + (shares * (juiceIndex - r.entryIndex)) / INDEX_SCALE;
            unclaimedShares -= shares;
        }
        uint256 fee = (grossTotal * JUICE_BPS) / BPS;
        if (fee > 0) {
            if (unclaimedShares > 0) {
                juiceIndex += (fee * INDEX_SCALE) / unclaimedShares;
            } else {
                jackpotAccrued += fee;
            }
        }
        uint256 total = refunds + grossTotal - fee;
        if (total == 0) revert NothingToClaim();
        aapl.safeTransfer(msg.sender, total);
        emit Claimed(msg.sender, total, fee);
    }

    function buybackSeed(uint256 minSeedOut) external onlyOwner nonReentrant {
        uint256 amount = treasuryAccrued;
        if (amount == 0) revert NothingToClaim();
        treasuryAccrued = 0;

        aapl.forceApprove(address(swapper), amount);
        uint256 balanceBefore = seed.balanceOf(address(this));
        swapper.swapAaplForSeed(amount, minSeedOut);
        aapl.forceApprove(address(swapper), 0);
        uint256 bought = seed.balanceOf(address(this)) - balanceBefore;
        if (bought < minSeedOut || bought == 0) revert InsufficientOutput();

        seed.safeTransfer(DEAD, bought);
        emit BuybackBurned(amount, bought);
    }

    function collectTreasury(address to) external onlyOwner nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        uint256 amount = treasuryAccrued;
        if (amount == 0) revert NothingToClaim();
        treasuryAccrued = 0;
        aapl.safeTransfer(to, amount);
        emit TreasuryCollected(to, amount);
    }

    function collectAdmin(address to) external onlyOwner nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        uint256 amount = adminAccrued;
        if (amount == 0) revert NothingToClaim();
        adminAccrued = 0;
        aapl.safeTransfer(to, amount);
        emit AdminCollected(to, amount);
    }

    function flushStaking() external nonReentrant {
        if (msg.sender != owner() && msg.sender != keeper) revert NotAuthorized();
        if (address(staking) == address(0)) revert ZeroAddress();
        uint256 amount = stakingAccrued;
        if (amount == 0) revert NothingToClaim();
        stakingAccrued = 0;
        aapl.forceApprove(address(staking), amount);
        uint256 balanceBefore = aapl.balanceOf(address(staking));
        staking.notifyReward(amount);
        if (aapl.balanceOf(address(staking)) - balanceBefore != amount) revert InsufficientOutput();
        emit StakingFlushed(amount);
    }

    function currentRound() public view returns (uint256) {
        return (block.timestamp - genesis) / ROUND_SECONDS;
    }

    function miners(uint256 round) external view returns (address[] memory) {
        return roundMiners[round];
    }

    function pendingClaim(address player, uint256[] calldata roundIds) external view returns (uint256 total) {
        for (uint256 i = 0; i < roundIds.length; i++) {
            uint256 round = roundIds[i];
            Round storage r = rounds[round];
            if ((!r.revealed && !r.voided) || roundClaimed[round][player]) continue;
            if (r.voided) {
                total += playerTotal[round][player];
                continue;
            }
            uint256 winStake = stakeOf[round][player][r.winningPlot];
            if (winStake == 0) continue;
            uint256 shares = winStake + (r.netLossPool * winStake) / r.winningStake;
            uint256 gross = shares + (shares * (juiceIndex - r.entryIndex)) / INDEX_SCALE;
            total += gross - (gross * JUICE_BPS) / BPS;
        }
    }

    function setMinPlantEth(uint256 minPlantEth_) external onlyOwner {
        _setMinPlantEth(minPlantEth_);
    }

    function setAdminFeeBps(uint16 bps) external onlyOwner {
        _setAdminFeeBps(bps);
    }

    function setRakeBps(uint16 bps) external onlyOwner {
        _setRakeBps(bps);
    }

    function setJackpotBps(uint16 bps) external onlyOwner {
        _setJackpotBps(bps);
    }

    function setJackpotOdds(uint32 odds) external onlyOwner {
        _setJackpotOdds(odds);
    }

    function setSwapper(ISwapper swapper_) external onlyOwner {
        _setSwapper(swapper_);
    }

    function setStaking(IStaking staking_) external onlyOwner {
        if (address(staking_) == address(0)) revert ZeroAddress();
        staking = staking_;
        emit StakingSet(address(staking_));
    }

    function setRandomness(IRandomness randomness_) external onlyOwner {
        _setRandomness(randomness_);
    }

    function setKeeper(address keeper_) external onlyOwner {
        keeper = keeper_;
        emit KeeperSet(keeper_);
    }

    function renounceOwnership() public view override onlyOwner {
        revert RenounceDisabled();
    }

    function _setMinPlantEth(uint256 minPlantEth_) private {
        if (minPlantEth_ > MAX_MIN_PLANT_ETH) revert MinPlantTooHigh();
        minPlantEth = minPlantEth_;
        emit MinPlantEthSet(minPlantEth_);
    }

    function _setRakeBps(uint16 bps) private {
        if (bps > MAX_RAKE_BPS) revert BpsTooHigh();
        rakeBps = bps;
        emit RakeBpsSet(bps);
    }

    function _setAdminFeeBps(uint16 bps) private {
        if (bps > MAX_ADMIN_FEE_BPS) revert BpsTooHigh();
        adminFeeBps = bps;
        emit AdminFeeBpsSet(bps);
    }

    function _setJackpotBps(uint16 bps) private {
        if (bps > BPS - STAKERS_BPS) revert BpsTooHigh();
        jackpotBps = bps;
        emit JackpotBpsSet(bps);
    }

    function _setJackpotOdds(uint32 odds) private {
        if (odds == 0) revert ZeroOdds();
        jackpotOdds = odds;
        emit JackpotOddsSet(odds);
    }

    function _setSwapper(ISwapper swapper_) private {
        if (address(swapper_) == address(0)) revert ZeroAddress();
        swapper = swapper_;
        emit SwapperSet(address(swapper_));
    }

    function _setRandomness(IRandomness randomness_) private {
        if (address(randomness_) == address(0)) revert ZeroAddress();
        randomness = randomness_;
        emit RandomnessSet(address(randomness_));
    }
}
