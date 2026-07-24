// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";

import {IChainlinkAggregator} from "../interfaces/IChainlinkAggregator.sol";
import {IGmxExchangeRouter} from "../interfaces/IGmxExchangeRouter.sol";
import {IGmxDataStore} from "../libraries/GMCalculator.sol";
import {OracleGuard} from "../libraries/OracleGuard.sol";
import {BasaltConstants} from "../libraries/BasaltConstants.sol";

interface IGmToken {
    function totalSupply() external view returns (uint256);
}

// Stateless GM → (WBTC + USDC) router; receiver = msg.sender.
contract BasaltGmUnwrapper is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ────────────────────────────────────────────────────────────────────────
    //  ERRORS
    // ────────────────────────────────────────────────────────────────────────

    error ZeroAddress();
    error ZeroAmount();
    error MissingExecutionFee();
    error InvalidSlippage();
    error GmxPoolAmountZero();
    error GmxTotalSupplyZero();

    // ────────────────────────────────────────────────────────────────────────
    //  EVENTS
    // ────────────────────────────────────────────────────────────────────────

    event GmUnwrapSubmitted(
        address indexed user,
        uint256 gmAmount,
        uint256 minLongWbtcE8,
        uint256 minShortUsdcE6,
        bytes32 indexed gmxRequestKey
    );

    // ────────────────────────────────────────────────────────────────────────
    //  CONFIG
    // ────────────────────────────────────────────────────────────────────────

    struct Config {
        address exchangeRouter;
        address gmxRouter;
        address gmxWithdrawalVault;
        address gmToken;
        address wbtc;
        address usdc;
        address gmxDataStore;
        address wbtcOracle;
        address usdcOracle;
        address sequencerOracle;
    }

    // ────────────────────────────────────────────────────────────────────────
    //  CONSTANTS
    // ────────────────────────────────────────────────────────────────────────

    uint256 internal constant BPS = BasaltConstants.BPS;
    uint256 internal constant MAX_SLIPPAGE_BPS = BasaltConstants.GM_UNWRAPPER_MAX_SLIPPAGE_BPS;
    bytes32 internal constant POOL_AMOUNT = BasaltConstants.GMX_KEY_POOL_AMOUNT;

    // ────────────────────────────────────────────────────────────────────────
    //  IMMUTABLES
    // ────────────────────────────────────────────────────────────────────────

    IGmxExchangeRouter public immutable GMX_EXCHANGE_ROUTER;
    address public immutable GMX_ROUTER;
    address public immutable GMX_WITHDRAWAL_VAULT;
    address public immutable GM_TOKEN;
    address public immutable WBTC_TOKEN;
    address public immutable USDC_TOKEN;
    IGmxDataStore public immutable GMX_DATA_STORE;
    IChainlinkAggregator public immutable WBTC_ORACLE;
    IChainlinkAggregator public immutable USDC_ORACLE;
    IChainlinkAggregator public immutable SEQUENCER_ORACLE;

    constructor(Config memory c) {
        if (
            c.exchangeRouter == address(0) || c.gmxRouter == address(0) || c.gmxWithdrawalVault == address(0)
                || c.gmToken == address(0) || c.wbtc == address(0) || c.usdc == address(0)
                || c.gmxDataStore == address(0) || c.wbtcOracle == address(0) || c.usdcOracle == address(0)
                || c.sequencerOracle == address(0)
        ) {
            revert ZeroAddress();
        }
        GMX_EXCHANGE_ROUTER = IGmxExchangeRouter(c.exchangeRouter);
        GMX_ROUTER = c.gmxRouter;
        GMX_WITHDRAWAL_VAULT = c.gmxWithdrawalVault;
        GM_TOKEN = c.gmToken;
        WBTC_TOKEN = c.wbtc;
        USDC_TOKEN = c.usdc;
        GMX_DATA_STORE = IGmxDataStore(c.gmxDataStore);
        WBTC_ORACLE = IChainlinkAggregator(c.wbtcOracle);
        USDC_ORACLE = IChainlinkAggregator(c.usdcOracle);
        SEQUENCER_ORACLE = IChainlinkAggregator(c.sequencerOracle);
    }

    // ────────────────────────────────────────────────────────────────────────
    //  PUBLIC ENTRY
    // ────────────────────────────────────────────────────────────────────────

    // Pull GM, submit GMX v2 createWithdrawal with receiver = msg.sender.
    function unwrap(uint256 gmAmount, uint256 slippageBps)
        external
        payable
        nonReentrant
        returns (bytes32 gmxRequestKey)
    {
        if (gmAmount == 0) revert ZeroAmount();
        if (msg.value == 0) revert MissingExecutionFee();
        if (slippageBps == 0 || slippageBps > MAX_SLIPPAGE_BPS) revert InvalidSlippage();

        IERC20(GM_TOKEN).safeTransferFrom(msg.sender, address(this), gmAmount);

        (uint256 minLongE8, uint256 minShortE6) = _calcMinLegs(gmAmount, slippageBps);

        // sanity health-check before spending GMX execution fee.
        OracleGuard.requireSequencerUp(SEQUENCER_ORACLE);
        OracleGuard.readChainlinkPrice(
            WBTC_ORACLE, OracleGuard.WBTC_MAX_AGE, OracleGuard.WBTC_MAX_PRICE_E8
        );
        OracleGuard.readChainlinkPrice(
            USDC_ORACLE, OracleGuard.USDC_MAX_AGE, OracleGuard.USDC_MAX_PRICE_E8
        );

        IERC20(GM_TOKEN).forceApprove(GMX_ROUTER, gmAmount);
        gmxRequestKey = _createGmxWithdrawal(gmAmount, minLongE8, minShortE6);

        emit GmUnwrapSubmitted(msg.sender, gmAmount, minLongE8, minShortE6, gmxRequestKey);
    }

    // ────────────────────────────────────────────────────────────────────────
    //  INTERNAL — GMX SUBMISSION
    // ────────────────────────────────────────────────────────────────────────

    function _createGmxWithdrawal(uint256 gmAmount, uint256 minLong, uint256 minShort)
        internal
        returns (bytes32)
    {
        bytes[] memory calls = new bytes[](3);
        calls[0] = abi.encodeCall(IGmxExchangeRouter.sendWnt, (GMX_WITHDRAWAL_VAULT, msg.value));
        calls[1] = abi.encodeCall(
            IGmxExchangeRouter.sendTokens, (GM_TOKEN, GMX_WITHDRAWAL_VAULT, gmAmount)
        );
        calls[2] = abi.encodeCall(
            IGmxExchangeRouter.createWithdrawal, (_buildCreateWithdrawalParams(minLong, minShort))
        );

        bytes[] memory results = GMX_EXCHANGE_ROUTER.multicall{value: msg.value}(calls);
        return abi.decode(results[2], (bytes32));
    }

    function _buildCreateWithdrawalParams(uint256 minLong, uint256 minShort)
        internal
        view
        returns (IGmxExchangeRouter.CreateWithdrawalParams memory)
    {
        IGmxExchangeRouter.CreateWithdrawalParamsAddresses memory addrs = IGmxExchangeRouter
            .CreateWithdrawalParamsAddresses({
            receiver: msg.sender,
            callbackContract: address(0),
            uiFeeReceiver: address(0),
            market: GM_TOKEN,
            longTokenSwapPath: new address[](0),
            shortTokenSwapPath: new address[](0)
        });

        return IGmxExchangeRouter.CreateWithdrawalParams({
            addresses: addrs,
            minLongTokenAmount: minLong,
            minShortTokenAmount: minShort,
            shouldUnwrapNativeToken: false,
            executionFee: msg.value,
            callbackGasLimit: 0,
            dataList: new bytes32[](0)
        });
    }

    // ────────────────────────────────────────────────────────────────────────
    //  INTERNAL — POOL-RATIO MIN-LEG CALC
    // ────────────────────────────────────────────────────────────────────────

    // pool-composition mins; matches GMX internal withdrawal math.
    function _calcMinLegs(uint256 gmAmount, uint256 slippageBps)
        internal
        view
        returns (uint256 minLongE8, uint256 minShortE6)
    {
        uint256 poolLongE8 = _getPoolAmount(WBTC_TOKEN);
        uint256 poolShortE6 = _getPoolAmount(USDC_TOKEN);

        uint256 totalSupply = IGmToken(GM_TOKEN).totalSupply();
        if (totalSupply == 0) revert GmxTotalSupplyZero();

        uint256 expLongE8 = Math.mulDiv(gmAmount, poolLongE8, totalSupply);
        uint256 expShortE6 = Math.mulDiv(gmAmount, poolShortE6, totalSupply);

        minLongE8 = Math.mulDiv(expLongE8, BPS - slippageBps, BPS);
        minShortE6 = Math.mulDiv(expShortE6, BPS - slippageBps, BPS);
    }

    function _getPoolAmount(address token) internal view returns (uint256) {
        uint256 amount = GMX_DATA_STORE.getUint(keccak256(abi.encode(POOL_AMOUNT, GM_TOKEN, token)));
        if (amount == 0) revert GmxPoolAmountZero();
        return amount;
    }
}
