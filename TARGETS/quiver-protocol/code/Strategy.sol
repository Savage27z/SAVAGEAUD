// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IQuiverStrategy} from "./interfaces/IQuiverStrategy.sol";
import {IUniswapV3Pool, IUniswapV3MintCallback, IUniswapV3SwapCallback} from "./interfaces/IUniswapV3Pool.sol";
import {TickMath} from "./vendor/uniswap/TickMath.sol";
import {FullMath} from "./vendor/uniswap/FullMath.sol";
import {LiquidityAmounts} from "./vendor/uniswap/LiquidityAmounts.sol";

interface IVaultView {
    function isActive() external view returns (bool);
    function owner() external view returns (address);
    function keeper() external view returns (address);
    function totalSupply() external view returns (uint256);
}

interface IFeeConfigView {
    function getFees(address vault) external view returns (uint256 totalBps, uint256 callerBps, address treasury);
}

/// @title QuiverStrategyUniV3 — position mechanics for a Uniswap V3 pool.
/// @notice Talks to the pool directly (mint/burn/collect/swap — no position
///         manager, no router, zero standing approvals). The agent holds only
///         the keeper role and can act exclusively inside hard rails: cooldown,
///         tick-width bounds and a TWAP calm-period check. The emergency exit
///         performs zero swaps and zero oracle reads.
contract QuiverStrategyUniV3 is IQuiverStrategy, Initializable, ReentrancyGuard, IUniswapV3MintCallback, IUniswapV3SwapCallback {
    using SafeERC20 for IERC20;

    struct Rails {
        uint32 twapInterval;
        int24 maxTickDeviation;
        uint256 rebalanceCooldown;
        int24 minTickWidth;
        int24 maxTickWidth;
        uint256 fallbackRebalanceDelay;
    }

    uint256 internal constant BPS = 10_000;
    uint32 internal constant MIN_TWAP_INTERVAL = 30; // seconds — a shorter window is trivially skewed

    IUniswapV3Pool public pool;
    address public vault;
    address public override token0;
    address public override token1;
    int24 public tickSpacing;
    int24 public tickLower;
    int24 public tickUpper;

    // Rails — changeable only by the vault owner (the timelock).
    uint32 public twapInterval; // seconds
    int24 public maxTickDeviation; // calm-period bound, in ticks
    uint256 public rebalanceCooldown; // seconds between rebalances
    int24 public minTickWidth;
    int24 public maxTickWidth;
    uint256 public fallbackRebalanceDelay; // out-of-range duration after which rebalance goes permissionless

    address public feeConfig;
    uint256 public lastRebalance;
    uint256 public lastInRange;

    event Harvest(address indexed caller, uint256 fees0, uint256 fees1, uint256 ppsAfter);
    event Rebalance(int24 oldLower, int24 oldUpper, int24 newLower, int24 newUpper, bool viaFallback);
    event EmergencyExit(uint256 balance0, uint256 balance1);
    event Reinvested(uint128 liquidity);
    event RetiredTo(address indexed newStrategy, uint256 balance0, uint256 balance1);
    event RailsSet(uint32 twapInterval, int24 maxTickDeviation, uint256 cooldown, int24 minWidth, int24 maxWidth, uint256 fallbackDelay);

    error NotVault();
    error NotVaultOwner();
    error NotKeeperNorFallback();
    error NotPool();
    error VaultNotActive();
    error NotCalm();
    error CooldownActive();
    error BadTicks();
    error RangeMustBracketPrice();
    error ZeroAddress();
    error BadTwapInterval();

    modifier onlyVault() {
        if (msg.sender != vault) revert NotVault();
        _;
    }

    modifier onlyVaultOwner() {
        if (msg.sender != IVaultView(vault).owner()) revert NotVaultOwner();
        _;
    }

    constructor() {
        _disableInitializers();
    }

    function initialize(address pool_, address vault_, int24 tickLower_, int24 tickUpper_, address feeConfig_, Rails calldata rails)
        external
        initializer
    {
        if (pool_ == address(0) || vault_ == address(0) || feeConfig_ == address(0)) revert ZeroAddress();
        if (rails.twapInterval < MIN_TWAP_INTERVAL) revert BadTwapInterval();

        pool = IUniswapV3Pool(pool_);
        vault = vault_;
        token0 = pool.token0();
        token1 = pool.token1();
        tickSpacing = pool.tickSpacing();
        feeConfig = feeConfig_;

        twapInterval = rails.twapInterval;
        maxTickDeviation = rails.maxTickDeviation;
        rebalanceCooldown = rails.rebalanceCooldown;
        minTickWidth = rails.minTickWidth;
        maxTickWidth = rails.maxTickWidth;
        fallbackRebalanceDelay = rails.fallbackRebalanceDelay;

        _validateTicks(tickLower_, tickUpper_);
        tickLower = tickLower_;
        tickUpper = tickUpper_;
        lastInRange = block.timestamp;
    }

    // ---------------------------------------------------------------- views

    function totalLiquidity() public view override returns (uint128 liquidity_) {
        (liquidity_,,,,) = pool.positions(_positionKey());
    }

    function inRange() public view override returns (bool) {
        (, int24 tick,,,,,) = pool.slot0();
        return tick >= tickLower && tick < tickUpper;
    }

    /// @notice Spot tick within `maxTickDeviation` of the TWAP tick.
    function isCalm() public view override returns (bool) {
        (, int24 tick,,,,,) = pool.slot0();
        int24 twap = twapTick();
        int24 diff = tick > twap ? tick - twap : twap - tick;
        return diff <= maxTickDeviation;
    }

    function twapTick() public view returns (int24 tick) {
        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = twapInterval;
        secondsAgos[1] = 0;
        (int56[] memory tickCumulatives,) = pool.observe(secondsAgos);
        int56 delta = tickCumulatives[1] - tickCumulatives[0];
        tick = int24(delta / int56(uint56(twapInterval)));
        // round toward negative infinity, matching Uniswap's OracleLibrary
        if (delta < 0 && (delta % int56(uint56(twapInterval)) != 0)) tick--;
    }

    function quoteDeposit(uint256 amount0Max, uint256 amount1Max)
        external
        view
        override
        returns (uint256 used0, uint256 used1, uint128 liquidity)
    {
        // Reserve one wei of headroom so the +1 rounding margin below can never
        // exceed the caller's stated maxima.
        uint256 q0 = amount0Max > 0 ? amount0Max - 1 : 0;
        uint256 q1 = amount1Max > 0 ? amount1Max - 1 : 0;

        (uint160 sqrtPriceX96,,,,,,) = pool.slot0();
        uint160 sqrtA = TickMath.getSqrtRatioAtTick(tickLower);
        uint160 sqrtB = TickMath.getSqrtRatioAtTick(tickUpper);

        liquidity = LiquidityAmounts.getLiquidityForAmounts(sqrtPriceX96, sqrtA, sqrtB, q0, q1);
        (used0, used1) = LiquidityAmounts.getAmountsForLiquidity(sqrtPriceX96, sqrtA, sqrtB, liquidity);
        // The pool rounds owed amounts up on mint; getAmountsForLiquidity rounds
        // down. One extra wei per side covers the difference.
        if (used0 > 0) used0 += 1;
        if (used1 > 0) used1 += 1;
    }

    // ------------------------------------------------------------ vault flow

    function invest(uint256 amount0, uint256 amount1) external override onlyVault nonReentrant returns (uint128 liquidityAdded) {
        liquidityAdded = _mintMaxLiquidity(amount0, amount1);
    }

    function divest(uint256 shares, uint256 totalShares, address receiver)
        external
        override
        onlyVault
        nonReentrant
        returns (uint256 out0, uint256 out1)
    {
        // Pro-rata slice of the position principal, collected straight to the
        // receiver. Pending fees are untouched — they belong to all holders
        // and get compounded at the next harvest.
        uint128 liquidity_ = totalLiquidity();
        uint128 burnLiquidity = uint128(FullMath.mulDiv(liquidity_, shares, totalShares));
        if (burnLiquidity > 0) {
            (uint256 burned0, uint256 burned1) = pool.burn(tickLower, tickUpper, burnLiquidity);
            (uint128 c0, uint128 c1) = pool.collect(receiver, tickLower, tickUpper, _u128(burned0), _u128(burned1));
            out0 += c0;
            out1 += c1;
        }

        // Pro-rata slice of idle balances (compound dust, post-panic holdings).
        uint256 idle0 = FullMath.mulDiv(IERC20(token0).balanceOf(address(this)), shares, totalShares);
        uint256 idle1 = FullMath.mulDiv(IERC20(token1).balanceOf(address(this)), shares, totalShares);
        if (idle0 > 0) IERC20(token0).safeTransfer(receiver, idle0);
        if (idle1 > 0) IERC20(token1).safeTransfer(receiver, idle1);
        out0 += idle0;
        out1 += idle1;
    }

    // -------------------------------------------------------------- keeper

    /// @notice Permissionless compounding: collect fees, split the performance
    ///         fee (caller / treasury), swap the rest toward the position
    ///         ratio and reinvest.
    function harvest(address callFeeRecipient) external override nonReentrant {
        if (!IVaultView(vault).isActive()) revert VaultNotActive();
        (uint256 fees0, uint256 fees1) = _harvest(callFeeRecipient);
        _compound();
        if (inRange()) lastInRange = block.timestamp;
        emit Harvest(callFeeRecipient, fees0, fees1, _pps());
    }

    /// @notice Move the range. Keeper-only inside the rails; permissionless
    ///         once the position has sat out of range past the fallback delay.
    function rebalance(int24 newTickLower, int24 newTickUpper) external override nonReentrant {
        if (!IVaultView(vault).isActive()) revert VaultNotActive();

        bool viaFallback = false;
        if (msg.sender != IVaultView(vault).keeper()) {
            // Anyone may re-center a long-abandoned position — the protocol
            // must degrade gracefully if the agent disappears.
            if (inRange() || block.timestamp < lastInRange + fallbackRebalanceDelay) revert NotKeeperNorFallback();
            viaFallback = true;
        }

        if (block.timestamp < lastRebalance + rebalanceCooldown) revert CooldownActive();
        if (!isCalm()) revert NotCalm();
        _validateTicks(newTickLower, newTickUpper);
        // The new range must bracket the current price. This keeps the mandatory
        // compound swap a small composition adjustment — never a full one-sided
        // flip of the whole principal — which is the only value a compromised
        // keeper (or the permissionless fallback caller) could otherwise extract
        // by self-sandwiching. It also guarantees the position lands in range, so
        // lastInRange refreshes and the fallback window cannot self-perpetuate.
        (, int24 spotTick,,,,,) = pool.slot0();
        if (spotTick < newTickLower || spotTick >= newTickUpper) revert RangeMustBracketPrice();

        (uint256 hf0, uint256 hf1) = _harvest(msg.sender);

        // Exit the whole position, move the range, re-enter.
        uint128 liquidity_ = totalLiquidity();
        if (liquidity_ > 0) {
            (uint256 burned0, uint256 burned1) = pool.burn(tickLower, tickUpper, liquidity_);
            pool.collect(address(this), tickLower, tickUpper, _u128(burned0), _u128(burned1));
        }

        int24 oldLower = tickLower;
        int24 oldUpper = tickUpper;
        tickLower = newTickLower;
        tickUpper = newTickUpper;

        _compound();

        lastRebalance = block.timestamp;
        if (inRange()) lastInRange = block.timestamp;
        emit Harvest(msg.sender, hf0, hf1, _pps());
        emit Rebalance(oldLower, oldUpper, newTickLower, newTickUpper, viaFallback);
    }

    // ------------------------------------------------------------ emergency

    /// @dev Zero swaps, zero oracle reads — must work mid-manipulation.
    function emergencyExit() external override onlyVault nonReentrant {
        _exitPosition();
        emit EmergencyExit(IERC20(token0).balanceOf(address(this)), IERC20(token1).balanceOf(address(this)));
    }

    function reinvestIdle() external override onlyVault nonReentrant {
        // Re-entering the whole idle principal runs a compound swap; only do so
        // in calm conditions so a large re-entry can't execute mid-manipulation.
        if (!isCalm()) revert NotCalm();
        _compound();
        emit Reinvested(totalLiquidity());
    }

    function retireTo(address newStrategy) external override onlyVault nonReentrant {
        if (newStrategy == address(0)) revert ZeroAddress();
        _exitPosition();
        uint256 b0 = IERC20(token0).balanceOf(address(this));
        uint256 b1 = IERC20(token1).balanceOf(address(this));
        if (b0 > 0) IERC20(token0).safeTransfer(newStrategy, b0);
        if (b1 > 0) IERC20(token1).safeTransfer(newStrategy, b1);
        emit RetiredTo(newStrategy, b0, b1);
    }

    // ----------------------------------------------------------------- admin

    function setRails(
        uint32 twapInterval_,
        int24 maxTickDeviation_,
        uint256 rebalanceCooldown_,
        int24 minTickWidth_,
        int24 maxTickWidth_,
        uint256 fallbackRebalanceDelay_
    ) external onlyVaultOwner {
        if (twapInterval_ < MIN_TWAP_INTERVAL) revert BadTwapInterval();
        twapInterval = twapInterval_;
        maxTickDeviation = maxTickDeviation_;
        rebalanceCooldown = rebalanceCooldown_;
        minTickWidth = minTickWidth_;
        maxTickWidth = maxTickWidth_;
        fallbackRebalanceDelay = fallbackRebalanceDelay_;
        emit RailsSet(twapInterval_, maxTickDeviation_, rebalanceCooldown_, minTickWidth_, maxTickWidth_, fallbackRebalanceDelay_);
    }

    // ------------------------------------------------------------- callbacks

    function uniswapV3MintCallback(uint256 amount0Owed, uint256 amount1Owed, bytes calldata) external override {
        if (msg.sender != address(pool)) revert NotPool();
        if (amount0Owed > 0) IERC20(token0).safeTransfer(msg.sender, amount0Owed);
        if (amount1Owed > 0) IERC20(token1).safeTransfer(msg.sender, amount1Owed);
    }

    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata) external override {
        if (msg.sender != address(pool)) revert NotPool();
        if (amount0Delta > 0) IERC20(token0).safeTransfer(msg.sender, uint256(amount0Delta));
        if (amount1Delta > 0) IERC20(token1).safeTransfer(msg.sender, uint256(amount1Delta));
    }

    // ------------------------------------------------------------- internals

    /// @dev Collect all pending fees and split the performance fee. Charged on
    ///      harvested yield only — never on principal.
    function _harvest(address callFeeRecipient) internal returns (uint256 fees0, uint256 fees1) {
        if (totalLiquidity() > 0) {
            pool.burn(tickLower, tickUpper, 0); // poke: realize fee growth
            (fees0, fees1) = pool.collect(address(this), tickLower, tickUpper, type(uint128).max, type(uint128).max);
        }

        if (fees0 > 0 || fees1 > 0) {
            (uint256 totalBps, uint256 callerBps, address treasury) = IFeeConfigView(feeConfig).getFees(vault);
            uint256 treasuryBps = totalBps - callerBps;
            if (callerBps > 0 && callFeeRecipient != address(0)) {
                if (fees0 > 0) IERC20(token0).safeTransfer(callFeeRecipient, (fees0 * callerBps) / BPS);
                if (fees1 > 0) IERC20(token1).safeTransfer(callFeeRecipient, (fees1 * callerBps) / BPS);
            }
            if (treasuryBps > 0) {
                if (fees0 > 0) IERC20(token0).safeTransfer(treasury, (fees0 * treasuryBps) / BPS);
                if (fees1 > 0) IERC20(token1).safeTransfer(treasury, (fees1 * treasuryBps) / BPS);
            }
        }

    }

    function _pps() internal view returns (uint256) {
        uint256 supply = IVaultView(vault).totalSupply();
        return supply == 0 ? 1e18 : FullMath.mulDiv(totalLiquidity(), 1e18, supply);
    }

    /// @dev Swap idle balances toward the position's composition (one bounded
    ///      swap, price-limited to the calm band around TWAP) and mint.
    function _compound() internal {
        uint256 bal0 = IERC20(token0).balanceOf(address(this));
        uint256 bal1 = IERC20(token1).balanceOf(address(this));
        if (bal0 == 0 && bal1 == 0) return;

        (uint160 sqrtPriceX96, int24 tick,,,,,) = pool.slot0();
        uint160 sqrtA = TickMath.getSqrtRatioAtTick(tickLower);
        uint160 sqrtB = TickMath.getSqrtRatioAtTick(tickUpper);

        (int256 amountIn, bool zeroForOne) = _swapToRatio(bal0, bal1, sqrtPriceX96, tick, sqrtA, sqrtB);
        if (amountIn > 0) {
            // Price limit = edge of the calm band around TWAP: execution can
            // never be worse than the manipulation bound, only partially fill.
            int24 twap = twapTick();
            uint160 limit = zeroForOne
                ? TickMath.getSqrtRatioAtTick(twap - maxTickDeviation)
                : TickMath.getSqrtRatioAtTick(twap + maxTickDeviation);
            pool.swap(address(this), zeroForOne, amountIn, limit, "");
            bal0 = IERC20(token0).balanceOf(address(this));
            bal1 = IERC20(token1).balanceOf(address(this));
        }

        _mintMaxLiquidity(bal0, bal1);
    }

    /// @dev How much of which token to sell so balances match the range ratio.
    function _swapToRatio(uint256 bal0, uint256 bal1, uint160 sqrtPriceX96, int24 tick, uint160 sqrtA, uint160 sqrtB)
        internal
        pure
        returns (int256 amountIn, bool zeroForOne)
    {
        if (tick < TickMath.MIN_TICK || tick > TickMath.MAX_TICK) return (0, false);

        // Below range: position wants only token0 — sell all token1. Above: inverse.
        if (sqrtPriceX96 <= sqrtA) return bal1 > 0 ? (int256(bal1), false) : (int256(0), false);
        if (sqrtPriceX96 >= sqrtB) return bal0 > 0 ? (int256(bal0), true) : (int256(0), false);

        // In range: target the composition of one unit of liquidity.
        (uint256 unit0, uint256 unit1) =
            LiquidityAmounts.getAmountsForLiquidity(sqrtPriceX96, sqrtA, sqrtB, uint128(1e18));
        uint256 unit0In1 = _amount0ToAmount1(unit0, sqrtPriceX96);
        uint256 unitTotal1 = unit0In1 + unit1;
        if (unitTotal1 == 0) return (0, false);

        uint256 total1 = bal1 + _amount0ToAmount1(bal0, sqrtPriceX96);
        uint256 target1 = FullMath.mulDiv(total1, unit1, unitTotal1);

        if (bal1 > target1) {
            return (int256(bal1 - target1), false); // sell excess token1
        }
        uint256 sell0 = _amount1ToAmount0(target1 - bal1, sqrtPriceX96);
        if (sell0 > bal0) sell0 = bal0;
        return (int256(sell0), true);
    }

    function _mintMaxLiquidity(uint256 amount0, uint256 amount1) internal returns (uint128 liquidity_) {
        (uint160 sqrtPriceX96,,,,,,) = pool.slot0();
        liquidity_ = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtRatioAtTick(tickLower),
            TickMath.getSqrtRatioAtTick(tickUpper),
            amount0,
            amount1
        );
        if (liquidity_ > 0) {
            pool.mint(address(this), tickLower, tickUpper, liquidity_, "");
        }
    }

    function _exitPosition() internal {
        uint128 liquidity_ = totalLiquidity();
        if (liquidity_ > 0) {
            pool.burn(tickLower, tickUpper, liquidity_);
        }
        // Collect everything owed: burned principal plus any pending fees.
        pool.collect(address(this), tickLower, tickUpper, type(uint128).max, type(uint128).max);
    }

    function _validateTicks(int24 lower, int24 upper) internal view {
        int24 spacing = tickSpacing;
        if (
            lower >= upper || lower < TickMath.MIN_TICK || upper > TickMath.MAX_TICK || lower % spacing != 0
                || upper % spacing != 0
        ) revert BadTicks();
        int24 width = upper - lower;
        if (width < minTickWidth || width > maxTickWidth) revert BadTicks();
    }

    function _positionKey() internal view returns (bytes32) {
        return keccak256(abi.encodePacked(address(this), tickLower, tickUpper));
    }

    function _amount0ToAmount1(uint256 amount0, uint160 sqrtPriceX96) internal pure returns (uint256) {
        return FullMath.mulDiv(FullMath.mulDiv(amount0, sqrtPriceX96, 1 << 96), sqrtPriceX96, 1 << 96);
    }

    function _amount1ToAmount0(uint256 amount1, uint160 sqrtPriceX96) internal pure returns (uint256) {
        return FullMath.mulDiv(FullMath.mulDiv(amount1, 1 << 96, sqrtPriceX96), 1 << 96, sqrtPriceX96);
    }

    function _u128(uint256 x) internal pure returns (uint128) {
        require(x <= type(uint128).max);
        return uint128(x);
    }
}
