// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";

import {IChainlinkAggregator} from "../interfaces/IChainlinkAggregator.sol";
import {ISwapRouter} from "../interfaces/ISwapRouter.sol";
import {OracleGuard} from "../libraries/OracleGuard.sol";
import {BasaltConstants} from "../libraries/BasaltConstants.sol";

// Stateless WBTC → USDC router via Uniswap V3; no holdings between txs.
contract BasaltZapOut is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ────────────────────────────────────────────────────────────────────────
    //  ERRORS
    // ────────────────────────────────────────────────────────────────────────

    error ZeroAddress();
    error ZeroAmount();
    error InvalidSwapSlippage();

    // ────────────────────────────────────────────────────────────────────────
    //  EVENTS
    // ────────────────────────────────────────────────────────────────────────

    event ZapOutExecuted(address indexed user, uint256 wbtcAmountE8, uint256 usdcAmountE6);

    // ────────────────────────────────────────────────────────────────────────
    //  CONFIG
    // ────────────────────────────────────────────────────────────────────────

    struct Config {
        address swapRouter;
        address wbtc;
        address usdc;
        address wbtcOracle;
        address usdcOracle;
        address sequencerOracle;
    }

    // ────────────────────────────────────────────────────────────────────────
    //  CONSTANTS
    // ────────────────────────────────────────────────────────────────────────

    uint256 internal constant BPS = BasaltConstants.BPS;
    uint256 internal constant MIN_SWAP_SLIPPAGE_BPS = BasaltConstants.ZAP_MIN_SWAP_SLIPPAGE_BPS;
    uint256 internal constant MAX_SWAP_SLIPPAGE_BPS = BasaltConstants.ZAP_MAX_SWAP_SLIPPAGE_BPS;
    uint24 internal constant WBTC_POOL_FEE = BasaltConstants.WBTC_POOL_FEE;

    // ────────────────────────────────────────────────────────────────────────
    //  IMMUTABLES
    // ────────────────────────────────────────────────────────────────────────

    ISwapRouter public immutable SWAP_ROUTER;
    address public immutable WBTC_TOKEN;
    address public immutable USDC_TOKEN;
    IChainlinkAggregator public immutable WBTC_ORACLE;
    IChainlinkAggregator public immutable USDC_ORACLE;
    IChainlinkAggregator public immutable SEQUENCER_ORACLE;

    constructor(Config memory c) {
        if (
            c.swapRouter == address(0) || c.wbtc == address(0) || c.usdc == address(0)
                || c.wbtcOracle == address(0) || c.usdcOracle == address(0) || c.sequencerOracle == address(0)
        ) {
            revert ZeroAddress();
        }
        SWAP_ROUTER = ISwapRouter(c.swapRouter);
        WBTC_TOKEN = c.wbtc;
        USDC_TOKEN = c.usdc;
        WBTC_ORACLE = IChainlinkAggregator(c.wbtcOracle);
        USDC_ORACLE = IChainlinkAggregator(c.usdcOracle);
        SEQUENCER_ORACLE = IChainlinkAggregator(c.sequencerOracle);
    }

    // ────────────────────────────────────────────────────────────────────────
    //  PUBLIC ENTRY
    // ────────────────────────────────────────────────────────────────────────

    // Pull WBTC, swap WBTC→USDC via Uniswap V3, deliver USDC to caller.
    function zapOut(uint256 wbtcAmountE8, uint256 swapSlippageBps)
        external
        nonReentrant
        returns (uint256 usdcAmountE6)
    {
        if (wbtcAmountE8 == 0) revert ZeroAmount();
        if (swapSlippageBps < MIN_SWAP_SLIPPAGE_BPS || swapSlippageBps > MAX_SWAP_SLIPPAGE_BPS) {
            revert InvalidSwapSlippage();
        }

        IERC20(WBTC_TOKEN).safeTransferFrom(msg.sender, address(this), wbtcAmountE8);

        uint256 minUsdcOutE6 = _calcMinUsdcOutE6(wbtcAmountE8, swapSlippageBps);

        IERC20(WBTC_TOKEN).forceApprove(address(SWAP_ROUTER), wbtcAmountE8);
        usdcAmountE6 = SWAP_ROUTER.exactInputSingle(
            ISwapRouter.ExactInputSingleParams({
                tokenIn: WBTC_TOKEN,
                tokenOut: USDC_TOKEN,
                fee: WBTC_POOL_FEE,
                recipient: msg.sender,
                amountIn: wbtcAmountE8,
                amountOutMinimum: minUsdcOutE6,
                sqrtPriceLimitX96: 0
            })
        );

        emit ZapOutExecuted(msg.sender, wbtcAmountE8, usdcAmountE6);
    }

    // ────────────────────────────────────────────────────────────────────────
    //  INTERNAL — ORACLE-BASED MIN-OUT
    // ────────────────────────────────────────────────────────────────────────

    // wbtc × wbtcPrice / (usdcPrice × 1e2); Chainlink parity.
    function _calcMinUsdcOutE6(uint256 wbtcAmountE8, uint256 swapSlippageBps)
        internal
        view
        returns (uint256)
    {
        OracleGuard.requireSequencerUp(SEQUENCER_ORACLE);

        uint256 wbtcPriceE8 = OracleGuard.readChainlinkPrice(
            WBTC_ORACLE, OracleGuard.WBTC_MAX_AGE, OracleGuard.WBTC_MAX_PRICE_E8
        );
        uint256 usdcPriceE8 = OracleGuard.readChainlinkPrice(
            USDC_ORACLE, OracleGuard.USDC_MAX_AGE, OracleGuard.USDC_MAX_PRICE_E8
        );

        uint256 expectedUsdcE6 = Math.mulDiv(wbtcAmountE8, wbtcPriceE8, usdcPriceE8 * 1e2);
        return Math.mulDiv(expectedUsdcE6, BPS - swapSlippageBps, BPS);
    }
}
