// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";
import {BasaltConstants} from "./BasaltConstants.sol";

library ZapInMath {
    uint256 internal constant BPS = BasaltConstants.BPS;

    function calcStableMinOut(
        uint256 amountIn,
        uint8 inputDecimals,
        uint8 outputDecimals,
        uint256 swapSlippageBps
    ) internal pure returns (uint256) {
        uint256 scaledAmount = amountIn;
        if (inputDecimals > outputDecimals) {
            scaledAmount = amountIn / (10 ** (inputDecimals - outputDecimals));
        } else if (outputDecimals > inputDecimals) {
            scaledAmount = amountIn * (10 ** (outputDecimals - inputDecimals));
        }
        return Math.mulDiv(scaledAmount, BPS - swapSlippageBps, BPS);
    }

    // E6 × (E8 × 1e2) / E8 = E8 (WBTC decimals)
    function quoteWbtcFromUsdc(
        uint256 usdcAmountE6,
        uint256 usdcPriceE8,
        uint256 wbtcPriceE8
    ) internal pure returns (uint256) {
        return Math.mulDiv(usdcAmountE6, usdcPriceE8 * 1e2, wbtcPriceE8);
    }

    // E6 × E8 × 1e4 = E18
    function calcUsdcValueE18(
        uint256 usdcAmountE6,
        uint256 usdcPriceE8
    ) internal pure returns (uint256) {
        return usdcAmountE6 * usdcPriceE8 * 1e4;
    }

    // E8 × E8 × 1e2 = E18
    function calcWbtcValueE18(
        uint256 wbtcAmountE8,
        uint256 wbtcPriceE8
    ) internal pure returns (uint256) {
        return wbtcAmountE8 * wbtcPriceE8 * 1e2;
    }

    function calcMinMarketTokens(
        uint256 inputValueE18,
        uint256 gmPriceE18,
        uint256 swapSlippageBps
    ) internal pure returns (uint256) {
        return
            Math.mulDiv(
                inputValueE18 * (BPS - swapSlippageBps),
                1e18,
                gmPriceE18 * BPS
            );
    }
}
