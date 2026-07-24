// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BasaltMath} from "../../pure/BasaltMath.sol";

library WithdrawHandlerCalculations {
    // ────────────────────────────────────────────────────────────────────────
    //  OWNER ELIGIBLE WITHDRAW CALCULATIONS
    // ────────────────────────────────────────────────────────────────────────

    function calcOwnerEligibleWithdrawShares(
        BasaltMath basaltMath,
        uint256 navUsdE18,
        uint256 managerAccruedFeeUsdE18,
        uint256 totalSharesE18
    ) internal pure returns (uint256) {
        return basaltMath.calcOwnerEligibleWithdrawShares(navUsdE18, managerAccruedFeeUsdE18, totalSharesE18);
    }

    function calcManagerMaxFeeWithdrawShares(
        BasaltMath basaltMath,
        uint256 navUsdE18,
        uint256 managerAccruedFeeUsdE18,
        uint256 totalSharesE18
    ) internal pure returns (uint256) {
        return basaltMath.calcManagerMaxFeeWithdrawShares(navUsdE18, managerAccruedFeeUsdE18, totalSharesE18);
    }

    // ────────────────────────────────────────────────────────────────────────
    //  PRO-RATA WITHDRAW CALCULATIONS
    // ────────────────────────────────────────────────────────────────────────

    function calcGmToSell(BasaltMath basaltMath, uint256 gmCollateralE18, uint256 sharesE18, uint256 totalSharesE18)
        internal
        pure
        returns (uint256)
    {
        return basaltMath.calcProRataGm(gmCollateralE18, sharesE18, totalSharesE18);
    }

    function calcRawRatioInitial(BasaltMath basaltMath, uint256 gmCollateralE18, uint256 debtE8)
        internal
        pure
        returns (uint256)
    {
        return basaltMath.calcWithdrawRawRatioInitialE18(gmCollateralE18, debtE8);
    }

    function calcGmToReturn(BasaltMath basaltMath, uint256 gmCollateralE18, uint256 sharesE18, uint256 totalSharesE18)
        internal
        pure
        returns (uint256)
    {
        return basaltMath.calcProRataGm(gmCollateralE18, sharesE18, totalSharesE18);
    }

    function calcSurplusToReturn(BasaltMath basaltMath, uint256 surplusE8, uint256 sharesE18, uint256 totalSharesE18)
        internal
        pure
        returns (uint256)
    {
        return basaltMath.calcProRataRedeem(surplusE8, sharesE18, totalSharesE18);
    }

    // ────────────────────────────────────────────────────────────────────────
    //  FINALIZE RATIO CALCULATIONS
    // ────────────────────────────────────────────────────────────────────────

    function calcWbtcToBorrowForRatio(
        BasaltMath basaltMath,
        uint256 currentCollateralE18,
        uint256 rawRatioScale,
        uint256 rawRatioE18
    ) internal pure returns (uint256) {
        return basaltMath.calcWithdrawBorrowFromRatio(currentCollateralE18, rawRatioScale, rawRatioE18);
    }

    function calcAdjustedDebtForBorrowIndex(
        BasaltMath basaltMath,
        uint256 currentDebtE8,
        uint256 snapshotIndexE18,
        uint256 currentIndexE18
    ) internal pure returns (uint256) {
        return basaltMath.calcDebtScaledByIndexRatio(currentDebtE8, snapshotIndexE18, currentIndexE18);
    }

    function calcTargetDebtForRatio(
        BasaltMath basaltMath,
        uint256 currentCollateralE18,
        uint256 rawRatioScale,
        uint256 rawRatioE18
    ) internal pure returns (uint256) {
        return basaltMath.calcWithdrawBorrowFromRatio(currentCollateralE18, rawRatioScale, rawRatioE18);
    }
}
