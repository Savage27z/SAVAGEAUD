// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {ICapitalRouter} from "./interfaces/ICapitalRouter.sol";
import {IERC20} from "./interfaces/IERC20.sol";
import {ISwapRouter, IUniswapV3Factory, IUniswapV3Pool} from "./interfaces/IUniswapV3.sol";

/**
 * @title GilderTokenBuyRouter (Uniswap V3)
 * @notice The protocol's open-market token-buy leg (spec §3.3).
 *
 * Every deposit routes 10% of its capital here. `BondContract` transfers that
 * USDC slice into this contract and then calls `executeTokenBuy`, which swaps
 * the USDC for GIL on the GIL/USDC Uniswap V3 pool (0.30% tier) and sends the
 * purchased GIL to the Treasury (the protocol's token inventory).
 *
 * The GIL/USDC pool is a single full-range V3 position, so its token balances
 * behave like constant-product reserves - the pre-trade quote + `spot` are
 * derived from those balances (same math the pool executes), and `minOut`
 * floors the fill at `quote - slippageBps` so a thin pool or a sandwich cannot
 * force a far-worse-than-quoted fill.
 */
contract GilderTokenBuyRouter is ICapitalRouter {
    uint256 public constant BPS_DENOMINATOR = 10_000;
    /// 0.30% fee tier (the protocol's canonical GIL/USDC pool).
    uint24 public constant POOL_FEE = 3000;

    IERC20 public immutable usdc;
    IERC20 public immutable gil;
    ISwapRouter public immutable swapRouter;
    IUniswapV3Factory public immutable factory;
    /// Treasury - receives every GIL the protocol buys (inventory, §9.2).
    address public immutable gilRecipient;

    // §Code-Review H2 (Jul 2026) - hard ceiling on the configurable slippage
    // tolerance. Unbounded, an admin could set 9,999 bps and reduce `minOut`
    // to nothing, silently disabling the only execution floor.
    uint256 public constant MAX_SLIPPAGE_BPS = 1_000; // 10%

    address public admin;
    address public bondContract;
    uint256 public slippageBps;
    uint256 public totalUsdcSpent;
    uint256 public totalGilBought;
    // §Code-Review H2 - TWAP anchor for the anti-sandwich guard. The spot
    // tick must sit within `maxDeviationTicks` of the `twapWindowSeconds`
    // TWAP before any swap executes. Mirrors TreasuryExecutor's §10.6 guard.
    uint32 public twapWindowSeconds;
    uint256 public maxDeviationTicks;
    // §Code-Review H2 - shortest TWAP the guard will accept. A pool younger
    // than `twapWindowSeconds` cannot serve the full window (Uniswap reverts
    // "OLD" when the lookback predates the oldest observation), which would
    // otherwise skip EVERY buy for the first half hour after a fresh
    // deployment. The guard falls back to this floor instead - a 5-minute
    // TWAP still defeats a single-block sandwich, which is the attack H2 is
    // about. Below the floor there is genuinely nothing to verify against,
    // and the buy is skipped rather than executed blind.
    uint32 public minTwapWindowSeconds;

    event GilPurchased(uint256 indexed depositId, uint256 usdcIn, uint256 gilOut);
    event BondContractSet(address indexed bondContract);
    event SlippageUpdated(uint256 bps);
    event AdminTransferred(address indexed previousAdmin, address indexed newAdmin);
    // §Code-Review H2 - the buy was NOT executed because the pool failed the
    // TWAP sanity check (or has no usable oracle history). The USDC slice is
    // forwarded to the Treasury untouched; the deposit still completes.
    event TokenBuySkipped(uint256 indexed depositId, uint256 usdcIn, bytes32 reason);
    event TwapGuardUpdated(uint32 windowSeconds, uint256 maxDeviationTicks, uint32 minWindowSeconds);

    error ZeroAddress();
    error NotAdmin(address caller);
    error NotBondContract(address caller);
    error SwapFailed();
    error SlippageAboveMaximum(uint256 requested, uint256 maximum);

    modifier onlyAdmin() {
        if (msg.sender != admin) revert NotAdmin(msg.sender);
        _;
    }

    constructor(
        address admin_,
        address usdc_,
        address gil_,
        address swapRouter_,
        address gilRecipient_
    ) {
        if (
            admin_ == address(0) || usdc_ == address(0) || gil_ == address(0)
                || swapRouter_ == address(0) || gilRecipient_ == address(0)
        ) {
            revert ZeroAddress();
        }
        admin = admin_;
        usdc = IERC20(usdc_);
        gil = IERC20(gil_);
        swapRouter = ISwapRouter(swapRouter_);
        factory = IUniswapV3Factory(ISwapRouter(swapRouter_).factory());
        gilRecipient = gilRecipient_;
        slippageBps = 300; // 3% default tolerance
        // §Code-Review H2 - same defaults as TreasuryExecutor's oracle guard:
        // a 30-minute TWAP window and a ~5% (500-tick) deviation band.
        twapWindowSeconds = 1_800;
        maxDeviationTicks = 500;
        minTwapWindowSeconds = 300; // 5-minute floor for a young pool
    }

    /**
     * Registers the BondContract once it is deployed. After this is set,
     * `executeTokenBuy` only accepts calls from the BondContract - until then
     * it is open so the deploy script can wire things in any order.
     */
    function setBondContract(address bondContract_) external onlyAdmin {
        if (bondContract_ == address(0)) revert ZeroAddress();
        bondContract = bondContract_;
        emit BondContractSet(bondContract_);
    }

    function setSlippageBps(uint256 bps) external onlyAdmin {
        // §Code-Review H2 - bounded; see MAX_SLIPPAGE_BPS.
        if (bps > MAX_SLIPPAGE_BPS) revert SlippageAboveMaximum(bps, MAX_SLIPPAGE_BPS);
        slippageBps = bps;
        emit SlippageUpdated(bps);
    }

    /**
     * §Code-Review H2 - tunes the TWAP sanity band. A window of 0 disables
     * the guard, which is only appropriate on a freshly-seeded pool with no
     * oracle history; production should keep a non-zero window.
     */
    function setTwapGuard(uint32 windowSeconds, uint256 maxDeviationTicks_, uint32 minWindowSeconds)
        external
        onlyAdmin
    {
        twapWindowSeconds = windowSeconds;
        maxDeviationTicks = maxDeviationTicks_;
        minTwapWindowSeconds = minWindowSeconds;
        emit TwapGuardUpdated(windowSeconds, maxDeviationTicks_, minWindowSeconds);
    }

    function transferAdmin(address newAdmin) external onlyAdmin {
        if (newAdmin == address(0)) revert ZeroAddress();
        emit AdminTransferred(admin, newAdmin);
        admin = newAdmin;
    }

    /**
     * Swaps the deposit's USDC slice (already transferred in by the
     * BondContract's CapitalRouter) for GIL on the Uniswap V3 pool and forwards
     * the GIL to the Treasury. Reverts the whole deposit if the swap cannot
     * clear the slippage floor - atomic, per spec §3.3.
     */
    function executeTokenBuy(uint256 depositId, uint256 amount) external {
        if (bondContract != address(0) && msg.sender != bondContract) {
            revert NotBondContract(msg.sender);
        }
        if (amount == 0) {
            emit TokenBuyExecuted(depositId, 0);
            return;
        }

        // §Code-Review H2 (Jul 2026) - anti-sandwich gate.
        //
        // `minOut` alone was NOT protection: the quote is derived from the
        // pool's reserves read in the SAME transaction, so a sandwicher who
        // moves the price first has the quote recompute against the skewed
        // reserves - `minOut` then validates the already-bad price. It was a
        // self-referential floor.
        //
        // The fix is to establish that spot is honest BEFORE quoting: compare
        // the live tick against the pool's own TWAP and refuse to trade
        // outside the band. Once spot is TWAP-anchored, the reserve-derived
        // quote is trustworthy and `minOut` becomes a meaningful floor.
        //
        // A failed check SKIPS the buy (slice forwarded to the Treasury)
        // rather than reverting - reverting here would deny the user's whole
        // deposit, trading an MEV loss for a liveness failure.
        (bool twapOk, bytes32 reason) = _checkSpotAgainstTwap();
        if (!twapOk) {
            if (!usdc.transfer(gilRecipient, amount)) revert SwapFailed();
            emit TokenBuySkipped(depositId, amount, reason);
            emit TokenBuyExecuted(depositId, amount);
            return;
        }

        (uint256 gilReserve, uint256 usdcReserve) = _reserves();
        uint256 quote = _getAmountOut(amount, usdcReserve, gilReserve);
        uint256 minOut = (quote * (BPS_DENOMINATOR - slippageBps)) / BPS_DENOMINATOR;

        if (!usdc.approve(address(swapRouter), amount)) revert SwapFailed();
        uint256 gilOut = swapRouter.exactInputSingle(
            ISwapRouter.ExactInputSingleParams({
                tokenIn: address(usdc),
                tokenOut: address(gil),
                fee: POOL_FEE,
                recipient: gilRecipient, // acquired GIL -> Treasury
                amountIn: amount,
                amountOutMinimum: minOut,
                sqrtPriceLimitX96: 0
            })
        );

        totalUsdcSpent += amount;
        totalGilBought += gilOut;

        emit GilPurchased(depositId, amount, gilOut);
        emit TokenBuyExecuted(depositId, amount);
    }

    /**
     * Live GIL spot price from the pool, expressed as USDC-per-GIL scaled to
     * 1e8 (the same convention `PriceBandExecutor` + the Chainlink USDC feed
     * use). Derived from the full-range V3 pool's token balances. 0 if the
     * pool isn't created / seeded.
     */
    function gilSpotPriceUsdc() external view returns (uint256 price) {
        (uint256 gilReserve, uint256 usdcReserve) = _reserves();
        if (gilReserve == 0) return 0;
        // USDC has 6 decimals, GIL has 18: price = usdcReserve*1e20 / gilReserve
        // yields USDC-per-GIL x 1e8.
        return (usdcReserve * 1e20) / gilReserve;
    }

    /* --------------------------- internals ------------------------------ */

    function _pool() private view returns (address) {
        return factory.getPool(address(usdc), address(gil), POOL_FEE);
    }

    /**
     * §Code-Review H2 - is the live tick within `maxDeviationTicks` of the
     * pool's own `twapWindowSeconds` TWAP?
     *
     * Returns a (ok, reason) pair rather than reverting so the caller can
     * degrade gracefully. `observe()` is read directly from the pool - no
     * primed observation is required, but a pool whose oracle ring buffer is
     * too short (freshly created, cardinality 1) will revert the call, which
     * we treat as "cannot verify" and therefore "do not trade".
     */
    function _checkSpotAgainstTwap() private view returns (bool ok, bytes32 reason) {
        if (twapWindowSeconds == 0) {
            // Guard explicitly disabled (fresh pool with no history).
            return (true, bytes32(0));
        }
        address pool = _pool();
        if (pool == address(0)) return (false, bytes32("NO_POOL"));

        int24 spotTick;
        try IUniswapV3Pool(pool).slot0() returns (uint160, int24 tick, uint16, uint16, uint16, uint8, bool) {
            spotTick = tick;
        } catch {
            return (false, bytes32("NO_SLOT0"));
        }

        // Try the configured window first; a pool younger than that reverts
        // ("OLD"), so fall back once to the minimum acceptable window before
        // giving up. Without the fallback a freshly-seeded pool would skip
        // every buy until it accumulated the full window of history.
        (bool got, int24 twapTick) = _twapTick(pool, twapWindowSeconds);
        if (!got && minTwapWindowSeconds != 0 && minTwapWindowSeconds < twapWindowSeconds) {
            (got, twapTick) = _twapTick(pool, minTwapWindowSeconds);
        }
        if (!got) {
            // Oracle history too short to verify - refuse rather than trade blind.
            return (false, bytes32("NO_TWAP"));
        }

        int256 diff = int256(spotTick) - int256(twapTick);
        if (diff < 0) diff = -diff;
        if (uint256(diff) > maxDeviationTicks) {
            return (false, bytes32("PRICE_DEVIATION"));
        }
        return (true, bytes32(0));
    }

    /** Reads a `window`-second TWAP tick; (false, 0) if the pool cannot serve it. */
    function _twapTick(address pool, uint32 window) private view returns (bool ok, int24 tick) {
        if (window == 0) return (false, 0);
        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = window;
        secondsAgos[1] = 0;
        try IUniswapV3Pool(pool).observe(secondsAgos) returns (int56[] memory cumulatives, uint160[] memory) {
            int56 delta = cumulatives[1] - cumulatives[0];
            return (true, int24(delta / int56(uint56(window))));
        } catch {
            return (false, 0);
        }
    }

    /** §Code-Review H2 - lets monitoring see whether a buy would execute. */
    function twapGuardStatus() external view returns (bool ok, bytes32 reason) {
        return _checkSpotAgainstTwap();
    }

    /** Pool token balances (full-range V3 => constant-product reserves). */
    function _reserves() private view returns (uint256 gilReserve, uint256 usdcReserve) {
        address pool = _pool();
        if (pool == address(0)) return (0, 0);
        return (gil.balanceOf(pool), usdc.balanceOf(pool));
    }

    /** Constant-product output with the 0.30% pool fee (997/1000). */
    function _getAmountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut)
        private
        pure
        returns (uint256)
    {
        if (reserveIn == 0 || reserveOut == 0) return 0;
        uint256 inWithFee = amountIn * 997;
        return (inWithFee * reserveOut) / (reserveIn * 1000 + inWithFee);
    }
}
