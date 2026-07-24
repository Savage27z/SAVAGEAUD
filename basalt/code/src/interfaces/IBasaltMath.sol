// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

interface IBasaltMath {
    // ════════════════════════════════════════════════════════════════════════
    //  1. PRICE SCALE CONVERSIONS
    // ════════════════════════════════════════════════════════════════════════

    function toWbtcPriceE18FromE28(uint256 wbtcPriceE28) external view returns (uint256);

    function toWbtcPriceE8FromE28(uint256 wbtcPriceE28) external view returns (uint256);

    function toWbtcPriceE8FromE18(uint256 wbtcPriceE18) external view returns (uint256);

    // ════════════════════════════════════════════════════════════════════════
    //  2. USD VALUATION  (token amount → USD)
    // ════════════════════════════════════════════════════════════════════════

    function calcCollUsdE18(uint256 gmCollateralE18, uint256 gmPriceUsdE18) external view returns (uint256);

    function calcDebtUsdE18(uint256 wbtcDebtE8, uint256 wbtcPriceUsdE18) external view returns (uint256);

    function calcGmValueE18(uint256 gmAmountE18, uint256 gmPriceE18) external view returns (uint256);

    function calcCollValueE36(uint256 gmCollateralE18, uint256 gmPriceE18) external view returns (uint256);

    function calcDebtValueE36(uint256 wbtcDebtE8, uint256 wbtcPriceE28) external view returns (uint256);

    function calcNavUsdE18(
        uint256 gmCollateralE18,
        uint256 wbtcSurplusE8,
        uint256 wbtcDebtE8,
        uint256 gmPriceUsdE18,
        uint256 wbtcPriceUsdE18
    ) external view returns (uint256);

    // ════════════════════════════════════════════════════════════════════════
    //  3. USD → TOKEN INVERSION  (USD value → token amount)
    // ════════════════════════════════════════════════════════════════════════

    function calcGmFromUsdE18(uint256 usdValueE18, uint256 gmPriceUsdE18) external view returns (uint256);

    function calcWbtcFromUsdE18(uint256 usdValueE18, uint256 wbtcPriceUsdE18) external view returns (uint256);

    function calcBorrowWbtcE8FromBorrowValueE18(uint256 borrowValueE18, uint256 wbtcPriceE18)
        external
        view
        returns (uint256);

    // ════════════════════════════════════════════════════════════════════════
    //  4. LTV RISK MEASUREMENT
    // ════════════════════════════════════════════════════════════════════════

    function calcLtvBps(uint256 debtUsdE18, uint256 collUsdE18) external view returns (uint256);

    function applyCollateralPremiumE36(uint256 collValueE36, uint256 premiumE18) external view returns (uint256);

    function applyDebtPremiumE36(uint256 debtValueE36, uint256 premiumE18) external view returns (uint256);

    function calcLtvBpsE36(uint256 adjustedDebtE36, uint256 adjustedCollE36) external view returns (uint256);

    function calcLtvDeviationUpBps(uint256 currentLtvBps, uint256 targetLtvBps) external view returns (uint256);

    function calcLtvDeviationDownBps(uint256 currentLtvBps, uint256 targetLtvBps) external view returns (uint256);

    // ════════════════════════════════════════════════════════════════════════
    //  5. BORROW / LEVERAGE SIZING
    // ════════════════════════════════════════════════════════════════════════

    function calcTargetDebtUsdE18(uint256 collUsdE18, uint256 targetLtvBps) external view returns (uint256);

    function calcBorrowValueForTargetLtvE18(uint256 collateralValueE18, uint256 targetLtvBps)
        external
        view
        returns (uint256);

    function calcBorrowValueForCollateralOnlyDepositE18(
        uint256 gmCollateralE18,
        uint256 depositGmE18,
        uint256 gmPriceE18,
        uint256 targetLtvBps
    ) external view returns (uint256);

    function calcRebalanceDelta(uint256 gapUsdE18, uint256 targetLtvBps) external view returns (uint256);

    function calcRatioPreservingBorrow(uint256 amountGmE18, uint256 wbtcDebtE8, uint256 gmCollateralE18)
        external
        view
        returns (uint256);

    // ════════════════════════════════════════════════════════════════════════
    //  6. SLIPPAGE & WRAP/UNWRAP EXPECTATION
    // ════════════════════════════════════════════════════════════════════════

    function applySlippage(uint256 amount, uint256 slippageBps) external view returns (uint256);

    function calcExpectedGmOutE18(uint256 borrowWbtcE8, uint256 wbtcPriceUsdE18, uint256 gmPriceUsdE18)
        external
        view
        returns (uint256);

    function calcGmReceivedMinE18(
        uint256 borrowWbtcE8,
        uint256 userSlippageBps,
        uint256 wbtcPriceE8,
        uint256 gmPriceE18
    ) external view returns (uint256);

    function calcExpectedWbtcOutLongSideE8(
        uint256 gmToSellE18,
        uint256 gmPriceUsdE18,
        uint256 wbtcPriceUsdE18,
        uint256 longShareBps
    ) external view returns (uint256);

    // ════════════════════════════════════════════════════════════════════════
    //  7. POST-ACTION POSITION PROJECTION
    // ════════════════════════════════════════════════════════════════════════

    function calcPostDepositLtvBps(
        uint256 gmCollateralE18,
        uint256 depositGmE18,
        uint256 minGmFromWrapE18,
        uint256 gmPriceE18,
        uint256 wbtcDebtE8,
        uint256 borrowWbtcE8,
        uint256 wbtcPriceE18
    ) external view returns (uint256);

    function calcPostRebalanceUpPosition(
        uint256 currentGmCollateralE18,
        uint256 minGmOutE18,
        uint256 currentWbtcDebtE8,
        uint256 borrowWbtcE8
    ) external view returns (uint256 postCollateralE18, uint256 postDebtE8);

    function calcPostRebalanceDownPosition(
        uint256 currentGmCollateralE18,
        uint256 gmToSellE18,
        uint256 currentWbtcDebtE8,
        uint256 minWbtcOutE8
    ) external view returns (uint256 postCollateralE18, uint256 postDebtE8);

    // ════════════════════════════════════════════════════════════════════════
    //  8. WITHDRAW FLOW
    // ════════════════════════════════════════════════════════════════════════

    function calcWithdrawRawRatioInitialE18(uint256 gmCollateralE18, uint256 wbtcDebtE8)
        external
        view
        returns (uint256);

    function calcWithdrawBorrowFromRatio(uint256 currentCollateralE18, uint256 rawRatioScale, uint256 rawRatioE18)
        external
        view
        returns (uint256);

    function calcProRataGm(uint256 gmCollateralE18, uint256 sharesToWithdraw, uint256 totalShares)
        external
        view
        returns (uint256);

    function calcProRataRedeem(uint256 tokenBalance, uint256 sharesToBurn, uint256 totalShares)
        external
        view
        returns (uint256);

    function calcOwnerEligibleWithdrawShares(
        uint256 navUsdE18,
        uint256 managerAccruedFeeUsdE18,
        uint256 totalSharesE18
    ) external view returns (uint256);

    function calcManagerMaxFeeWithdrawShares(
        uint256 navUsdE18,
        uint256 managerAccruedFeeUsdE18,
        uint256 totalSharesE18
    ) external view returns (uint256);

    function calcWbtcToUserFromSurplusAndBorrow(uint256 currentSurplusE8, uint256 wbtcToBorrowE8)
        external
        view
        returns (uint256);

    function calcWbtcToUserFromDebtRepay(uint256 targetDebtE8, uint256 adjustedDebtE8)
        external
        view
        returns (uint256);

    // ════════════════════════════════════════════════════════════════════════
    //  9. DOLOMITE BORROW-INDEX SCALING
    // ════════════════════════════════════════════════════════════════════════

    function calcScaledByIndexE18(uint256 parAmount, uint256 indexE18) external view returns (uint256);

    function calcDebtScaledByIndexRatio(uint256 currentDebtE8, uint256 snapshotIndexE18, uint256 currentIndexE18)
        external
        view
        returns (uint256);

    // ════════════════════════════════════════════════════════════════════════
    //  10. FEE MATH  (Enzyme-style HWM over absolute profit)
    // ════════════════════════════════════════════════════════════════════════

    function calcProfitUsdE18(uint256 navUsdE18, uint256 totalDepositedUsdE18, uint256 totalWithdrawnUsdE18)
        external
        view
        returns (uint256);

    function calcWithdrawnUsdE18(
        uint256 gmAmountE18,
        uint256 gmPriceUsdE18,
        uint256 wbtcAmountE8,
        uint256 wbtcPriceUsdE18
    ) external view returns (uint256);

    function calcPerformanceFeeByHwmProfit(
        uint256 currentProfitUsdE18,
        uint256 prevHwmProfitUsdE18,
        uint256 performanceFeeBps
    ) external view returns (uint256 profitDeltaUsdE18, uint256 performanceFeeUsdE18);

    function calcNextHighWaterMarkProfit(uint256 currentProfitUsdE18, uint256 prevHwmProfitUsdE18)
        external
        view
        returns (uint256);

    function calcNextAccruedManagerFee(uint256 prevAccruedUsdE18, uint256 addedFeeUsdE18)
        external
        view
        returns (uint256);

    function calcNextAccruedManagerFeeAfterWithdraw(uint256 prevAccruedUsdE18, uint256 withdrawnFeeUsdE18)
        external
        view
        returns (uint256);

    // ════════════════════════════════════════════════════════════════════════
    //  11. DEPOSIT ACCOUNTING HELPERS
    // ════════════════════════════════════════════════════════════════════════

    function calcPendingTotalGmE18(uint256 pendingSnapshotGmE18, uint256 pendingAmountGmE18)
        external
        view
        returns (uint256);

    function calcRefundEthWei(uint256 msgValueWei, uint256 spentWei) external view returns (uint256);

    // ════════════════════════════════════════════════════════════════════════
    //  12. TIME / BLOCK GATES
    // ════════════════════════════════════════════════════════════════════════

    function calcKeeperDeadlineTimestamp(uint256 nowTimestamp, uint256 keeperDeadlineSeconds)
        external
        view
        returns (uint256);

    function calcUnstuckNotBefore(uint256 deadline, uint256 graceSeconds) external view returns (uint256);

    function calcCooldownEndBlock(uint256 currentBlockNumber, uint256 cooldownBlocks)
        external
        view
        returns (uint256);

    function calcRemainingCooldownBlocks(uint256 cooldownEndBlock, uint256 currentBlockNumber)
        external
        view
        returns (uint256);

    // ════════════════════════════════════════════════════════════════════════
    //  13. GENERIC ARITHMETIC IDIOMS
    // ════════════════════════════════════════════════════════════════════════

    function calcAbsDiff(uint256 a, uint256 b) external view returns (uint256);

    function subFloorZero(uint256 a, uint256 b) external view returns (uint256);

    function calcBpsRatio(uint256 numerator, uint256 denominator) external view returns (uint256);

    function mulDiv(uint256 a, uint256 b, uint256 c) external view returns (uint256);

    function mulDivCeil(uint256 a, uint256 b, uint256 c) external view returns (uint256);
}
