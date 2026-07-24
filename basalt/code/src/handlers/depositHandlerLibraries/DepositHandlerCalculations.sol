// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {DepositContext} from "./DepositHandlerTypes.sol";
import {DepositHandlerRequirements} from "./DepositHandlerRequirements.sol";

library DepositHandlerCalculations {
    // ────────────────────────────────────────────────────────────────────────
    //  PRICE CONVERSIONS
    // ────────────────────────────────────────────────────────────────────────

    function toWbtcPriceE8(DepositContext memory depositContext) internal pure returns (uint256) {
        return depositContext.basaltMath.toWbtcPriceE8FromE18(depositContext.wbtcPriceE18);
    }

    // ────────────────────────────────────────────────────────────────────────
    //  DEPOSIT VALUE CALCULATIONS
    // ────────────────────────────────────────────────────────────────────────

    function calcDepositValueE18(DepositContext memory depositContext) internal pure returns (uint256) {
        return depositContext.basaltMath.calcGmValueE18(depositContext.amountGmE18, depositContext.gmPriceE18);
    }

    function calcWbtcSurplusValueUsdE18(DepositContext memory depositContext, uint256 wbtcAmountE8)
        internal
        pure
        returns (uint256)
    {
        return depositContext.basaltMath.calcDebtUsdE18(wbtcAmountE8, depositContext.wbtcPriceE18);
    }

    // ────────────────────────────────────────────────────────────────────────
    //  BORROW / WRAP CALCULATIONS
    // ────────────────────────────────────────────────────────────────────────

    function calcBorrowValueE18(DepositContext memory depositContext) internal pure returns (uint256) {
        return depositContext.basaltMath
            .calcBorrowValueForTargetLtvE18(depositContext.depositValueE18, depositContext.targetLtvBps);
    }

    function calcBorrowWbtcE8(DepositContext memory depositContext) internal pure returns (uint256) {
        return depositContext.basaltMath
            .calcBorrowWbtcE8FromBorrowValueE18(depositContext.borrowValueE18, depositContext.wbtcPriceE18);
    }

    function calcGmReceivedMinE18(DepositContext memory depositContext) internal pure returns (uint256) {
        return depositContext.basaltMath
            .calcGmReceivedMinE18(
                depositContext.borrowWbtcE8,
                depositContext.userSlippageBps,
                depositContext.wbtcPriceE8,
                depositContext.gmPriceE18
            );
    }

    function calcBorrowValueForCollateralInVaultOnly(DepositContext memory depositContext)
        internal
        pure
        returns (uint256)
    {
        return depositContext.basaltMath
            .calcBorrowValueForCollateralOnlyDepositE18(
                depositContext.gmCollateral,
                depositContext.amountGmE18,
                depositContext.gmPriceE18,
                depositContext.targetLtvBps
            );
    }

    function calcRatioPreservingBorrowWbtcE8(DepositContext memory depositContext) internal pure returns (uint256) {
        return depositContext.basaltMath
            .calcRatioPreservingBorrow(depositContext.amountGmE18, depositContext.wbtcDebt, depositContext.gmCollateral);
    }

    function calcBorrowValueFromBorrowWbtcE8(DepositContext memory depositContext) internal pure returns (uint256) {
        return depositContext.basaltMath.calcDebtUsdE18(depositContext.borrowWbtcE8, depositContext.wbtcPriceE18);
    }

    // ────────────────────────────────────────────────────────────────────────
    //  SURPLUS ABSORB CALCULATIONS
    // ────────────────────────────────────────────────────────────────────────

    function calcExpectedAbsorbGmE18(DepositContext memory depositContext, uint256 surplusWbtcE8)
        internal
        pure
        returns (uint256)
    {
        return depositContext.basaltMath
            .calcExpectedGmOutE18(surplusWbtcE8, depositContext.wbtcPriceE18, depositContext.gmPriceE18);
    }

    function calcSlippageAdjustedGmE18(
        DepositContext memory depositContext,
        uint256 expectedGmE18,
        uint256 userSlippageBps
    ) internal pure returns (uint256) {
        return depositContext.basaltMath.applySlippage(expectedGmE18, userSlippageBps);
    }

    // ────────────────────────────────────────────────────────────────────────
    //  CONTEXT FILLERS
    // ────────────────────────────────────────────────────────────────────────

    function fillTargetLtvDepositContext(DepositContext memory depositContext, uint256 borrowValueE18)
        internal
        pure
        returns (DepositContext memory)
    {
        depositContext.borrowValueE18 = borrowValueE18;
        depositContext.borrowWbtcE8 = calcBorrowWbtcE8(depositContext);
        depositContext.gmReceivedMinE18 = calcGmReceivedMinE18(depositContext);
        DepositHandlerRequirements.requireLtvBelowCap(depositContext);
        return depositContext;
    }
}
