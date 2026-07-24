// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";

import {IChainlinkAggregator} from "../interfaces/IChainlinkAggregator.sol";
import {IGmxExchangeRouter} from "../interfaces/IGmxExchangeRouter.sol";
import {ISwapRouter} from "../interfaces/ISwapRouter.sol";
import {GMCalculator, IGmxDataStore} from "../libraries/GMCalculator.sol";
import {OracleGuard} from "../libraries/OracleGuard.sol";
import {ZapInMath} from "../libraries/ZapInMath.sol";
import {BasaltConstants} from "../libraries/BasaltConstants.sol";

// Stateless USDC → GM router; receiver = msg.sender; no holdings between txs.
contract BasaltZapIn is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ────────────────────────────────────────────────────────────────────────
    //  ERRORS
    // ────────────────────────────────────────────────────────────────────────

    error ZeroAddress();
    error ZeroAmount();
    error InvalidSwapSlippage();
    error MissingExecutionFee();
    error BelowMinimumDeposit();
    error GmxPoolAmountZero();

    // ────────────────────────────────────────────────────────────────────────
    //  EVENTS
    // ────────────────────────────────────────────────────────────────────────

    event ZapInSubmitted(
        address indexed user,
        uint256 usdcAmountE6,
        bytes32 indexed gmxRequestKey,
        bool isLongRoute
    );

    // ────────────────────────────────────────────────────────────────────────
    //  CONFIG / TYPES
    // ────────────────────────────────────────────────────────────────────────

    enum Route {
        GM_SHORT,
        GM_LONG
    }

    struct Config {
        address swapRouter;
        address exchangeRouter;
        address gmxRouter;
        address gmxDepositVault;
        address usdc;
        address wbtc;
        address gmToken;
        address gmxDataStore;
        address wbtcOracle;
        address usdcOracle;
        address sequencerOracle;
    }

    struct PriceSnapshot {
        uint256 usdcPriceE8;
        uint256 wbtcPriceE8;
        uint256 gmPriceE18;
    }

    // ────────────────────────────────────────────────────────────────────────
    //  CONSTANTS
    // ────────────────────────────────────────────────────────────────────────

    uint256 internal constant BPS = BasaltConstants.BPS;
    uint256 internal constant MAX_SWAP_SLIPPAGE_BPS = BasaltConstants.ZAP_MAX_SWAP_SLIPPAGE_BPS;
    uint24 internal constant WBTC_POOL_FEE = BasaltConstants.WBTC_POOL_FEE;
    uint256 internal constant POOL_IMBALANCE_BPS = BasaltConstants.ZAPIN_MIN_POOL_IMBALANCE_BPS;
    uint256 internal constant MIN_DEPOSIT_GM_BUFFER_BPS = BasaltConstants.ZAPIN_MIN_DEPOSIT_GM_BUFFER_BPS;
    bytes32 internal constant POOL_AMOUNT = BasaltConstants.GMX_KEY_POOL_AMOUNT;

    // ────────────────────────────────────────────────────────────────────────
    //  IMMUTABLES
    // ────────────────────────────────────────────────────────────────────────

    ISwapRouter public immutable SWAP_ROUTER;
    IGmxExchangeRouter public immutable GMX_EXCHANGE_ROUTER;
    address public immutable GMX_ROUTER;
    address public immutable GMX_DEPOSIT_VAULT;
    address public immutable USDC_TOKEN;
    address public immutable WBTC_TOKEN;
    address public immutable GM_TOKEN;
    IGmxDataStore public immutable GMX_DATA_STORE;
    IChainlinkAggregator public immutable WBTC_ORACLE;
    IChainlinkAggregator public immutable USDC_ORACLE;
    IChainlinkAggregator public immutable SEQUENCER_ORACLE;

    // ────────────────────────────────────────────────────────────────────────
    //  CONSTRUCTOR
    // ────────────────────────────────────────────────────────────────────────

    constructor(Config memory c) {
        if (
            c.swapRouter == address(0) || c.exchangeRouter == address(0) || c.gmxRouter == address(0)
                || c.gmxDepositVault == address(0) || c.usdc == address(0) || c.wbtc == address(0)
                || c.gmToken == address(0) || c.gmxDataStore == address(0) || c.wbtcOracle == address(0)
                || c.usdcOracle == address(0) || c.sequencerOracle == address(0)
        ) {
            revert ZeroAddress();
        }

        SWAP_ROUTER = ISwapRouter(c.swapRouter);
        GMX_EXCHANGE_ROUTER = IGmxExchangeRouter(c.exchangeRouter);
        GMX_ROUTER = c.gmxRouter;
        GMX_DEPOSIT_VAULT = c.gmxDepositVault;
        USDC_TOKEN = c.usdc;
        WBTC_TOKEN = c.wbtc;
        GM_TOKEN = c.gmToken;
        GMX_DATA_STORE = IGmxDataStore(c.gmxDataStore);
        WBTC_ORACLE = IChainlinkAggregator(c.wbtcOracle);
        USDC_ORACLE = IChainlinkAggregator(c.usdcOracle);
        SEQUENCER_ORACLE = IChainlinkAggregator(c.sequencerOracle);
    }

    // ────────────────────────────────────────────────────────────────────────
    //  PUBLIC ENTRY
    // ────────────────────────────────────────────────────────────────────────

    // Pull USDC, submit GMX v2 deposit with receiver = msg.sender.
    function zapIn(uint256 usdcAmountE6, uint256 swapSlippageBps)
        external
        payable
        nonReentrant
        returns (bytes32 gmxRequestKey)
    {
        if (usdcAmountE6 == 0) revert ZeroAmount();
        if (msg.value == 0) revert MissingExecutionFee();
        if (swapSlippageBps > MAX_SWAP_SLIPPAGE_BPS) revert InvalidSwapSlippage();

        IERC20(USDC_TOKEN).safeTransferFrom(msg.sender, address(this), usdcAmountE6);

        PriceSnapshot memory snap = _takePriceSnapshot();

        // catch dust zaps: must clear 1 GM + 5% buffer.
        uint256 usdcValueUsdE18 = ZapInMath.calcUsdcValueE18(usdcAmountE6, snap.usdcPriceE8);
        uint256 minDepositValueUsdE18 =
            snap.gmPriceE18 + Math.mulDiv(snap.gmPriceE18, MIN_DEPOSIT_GM_BUFFER_BPS, BPS);
        if (usdcValueUsdE18 < minDepositValueUsdE18) revert BelowMinimumDeposit();

        Route route = _selectRoute(snap);
        if (route == Route.GM_SHORT) {
            gmxRequestKey = _execGmShort(usdcAmountE6, swapSlippageBps, snap);
            emit ZapInSubmitted(msg.sender, usdcAmountE6, gmxRequestKey, false);
        } else {
            gmxRequestKey = _execGmLong(usdcAmountE6, swapSlippageBps, snap);
            emit ZapInSubmitted(msg.sender, usdcAmountE6, gmxRequestKey, true);
        }
    }

    // ────────────────────────────────────────────────────────────────────────
    //  INTERNAL — ROUTES
    // ────────────────────────────────────────────────────────────────────────

    // GM_SHORT: USDC direct → GMX short side.
    function _execGmShort(uint256 usdcAmountE6, uint256 slippageBps, PriceSnapshot memory snap)
        internal
        returns (bytes32)
    {
        uint256 minMarketTokens = ZapInMath.calcMinMarketTokens(
            ZapInMath.calcUsdcValueE18(usdcAmountE6, snap.usdcPriceE8), snap.gmPriceE18, slippageBps
        );

        IERC20(USDC_TOKEN).forceApprove(GMX_ROUTER, usdcAmountE6);
        return _createGmxDeposit(USDC_TOKEN, usdcAmountE6, minMarketTokens);
    }

    // GM_LONG: USDC→WBTC (UniV3) → GMX long; cancel returns WBTC.
    function _execGmLong(uint256 usdcAmountE6, uint256 slippageBps, PriceSnapshot memory snap)
        internal
        returns (bytes32)
    {
        uint256 quotedWbtcOutE8 =
            ZapInMath.quoteWbtcFromUsdc(usdcAmountE6, snap.usdcPriceE8, snap.wbtcPriceE8);
        uint256 minWbtcOutE8 = Math.mulDiv(quotedWbtcOutE8, BPS - slippageBps, BPS);
        uint256 wbtcAmountE8 = _swapExactInputSingle(
            USDC_TOKEN, WBTC_TOKEN, WBTC_POOL_FEE, usdcAmountE6, minWbtcOutE8
        );

        uint256 minMarketTokens = ZapInMath.calcMinMarketTokens(
            ZapInMath.calcWbtcValueE18(wbtcAmountE8, snap.wbtcPriceE8), snap.gmPriceE18, slippageBps
        );

        IERC20(WBTC_TOKEN).forceApprove(GMX_ROUTER, wbtcAmountE8);
        return _createGmxDeposit(WBTC_TOKEN, wbtcAmountE8, minMarketTokens);
    }

    // ────────────────────────────────────────────────────────────────────────
    //  INTERNAL — GMX SUBMISSION
    // ────────────────────────────────────────────────────────────────────────

    function _createGmxDeposit(address token, uint256 amount, uint256 minMarketTokens)
        internal
        returns (bytes32)
    {
        bytes[] memory calls = new bytes[](3);
        calls[0] = abi.encodeCall(IGmxExchangeRouter.sendWnt, (GMX_DEPOSIT_VAULT, msg.value));
        calls[1] = abi.encodeCall(IGmxExchangeRouter.sendTokens, (token, GMX_DEPOSIT_VAULT, amount));
        calls[2] = abi.encodeCall(
            IGmxExchangeRouter.createDeposit, (_buildCreateDepositParams(minMarketTokens))
        );

        bytes[] memory results = GMX_EXCHANGE_ROUTER.multicall{value: msg.value}(calls);
        return abi.decode(results[2], (bytes32));
    }

    function _buildCreateDepositParams(uint256 minMarketTokens)
        internal
        view
        returns (IGmxExchangeRouter.CreateDepositParams memory)
    {
        IGmxExchangeRouter.CreateDepositParamsAddresses memory addrs = IGmxExchangeRouter
            .CreateDepositParamsAddresses({
            receiver: msg.sender,
            callbackContract: address(0),
            uiFeeReceiver: address(0),
            market: GM_TOKEN,
            initialLongToken: WBTC_TOKEN,
            initialShortToken: USDC_TOKEN,
            longTokenSwapPath: new address[](0),
            shortTokenSwapPath: new address[](0)
        });

        return IGmxExchangeRouter.CreateDepositParams({
            addresses: addrs,
            minMarketTokens: minMarketTokens,
            shouldUnwrapNativeToken: false,
            executionFee: msg.value,
            callbackGasLimit: 0,
            dataList: new bytes32[](0)
        });
    }

    // ────────────────────────────────────────────────────────────────────────
    //  INTERNAL — PRICING & ROUTE SELECTION
    // ────────────────────────────────────────────────────────────────────────

    function _takePriceSnapshot() internal view returns (PriceSnapshot memory snap) {
        OracleGuard.requireSequencerUp(SEQUENCER_ORACLE);

        snap.wbtcPriceE8 =
            OracleGuard.readChainlinkPrice(WBTC_ORACLE, OracleGuard.WBTC_MAX_AGE, OracleGuard.WBTC_MAX_PRICE_E8);
        snap.usdcPriceE8 =
            OracleGuard.readChainlinkPrice(USDC_ORACLE, OracleGuard.USDC_MAX_AGE, OracleGuard.USDC_MAX_PRICE_E8);

        GMCalculator.GmPriceParams memory gm = GMCalculator.GmPriceParams({
            dataStore: GMX_DATA_STORE,
            market: GM_TOKEN,
            indexToken: WBTC_TOKEN,
            longToken: WBTC_TOKEN,
            shortToken: USDC_TOKEN,
            indexPriceE30: snap.wbtcPriceE8 * (OracleGuard.CL_TO_GMX / 1e8),
            longPriceE30: snap.wbtcPriceE8 * (OracleGuard.CL_TO_GMX / 1e8),
            shortPriceE30: snap.usdcPriceE8 * (OracleGuard.CL_TO_GMX / 1e6)
        });

        snap.gmPriceE18 = GMCalculator.calcGmPriceUsdE18(gm);
    }

    // pick lighter pool side; default GM_SHORT inside POOL_IMBALANCE_BPS band.
    function _selectRoute(PriceSnapshot memory snap) internal view returns (Route) {
        uint256 longPoolAmountE8 = _getPoolAmount(GM_TOKEN, WBTC_TOKEN);
        uint256 shortPoolAmountE6 = _getPoolAmount(GM_TOKEN, USDC_TOKEN);
        uint256 longUsdE18 = ZapInMath.calcWbtcValueE18(longPoolAmountE8, snap.wbtcPriceE8);
        uint256 shortUsdE18 = ZapInMath.calcUsdcValueE18(shortPoolAmountE6, snap.usdcPriceE8);

        if (longUsdE18 > shortUsdE18 * (BPS + POOL_IMBALANCE_BPS) / BPS) {
            return Route.GM_SHORT;
        }
        if (shortUsdE18 > longUsdE18 * (BPS + POOL_IMBALANCE_BPS) / BPS) {
            return Route.GM_LONG;
        }
        return Route.GM_SHORT;
    }

    function _swapExactInputSingle(
        address tokenIn,
        address tokenOut,
        uint24 fee,
        uint256 amountIn,
        uint256 amountOutMinimum
    ) internal returns (uint256) {
        IERC20(tokenIn).forceApprove(address(SWAP_ROUTER), amountIn);
        return SWAP_ROUTER.exactInputSingle(
            ISwapRouter.ExactInputSingleParams({
                tokenIn: tokenIn,
                tokenOut: tokenOut,
                fee: fee,
                recipient: address(this),
                amountIn: amountIn,
                amountOutMinimum: amountOutMinimum,
                sqrtPriceLimitX96: 0
            })
        );
    }

    function _getPoolAmount(address market, address token) internal view returns (uint256) {
        uint256 amount = GMX_DATA_STORE.getUint(keccak256(abi.encode(POOL_AMOUNT, market, token)));
        if (amount == 0) revert GmxPoolAmountZero();
        return amount;
    }
}
