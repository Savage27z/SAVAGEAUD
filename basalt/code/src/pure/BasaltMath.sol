// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";
import {BasaltConstants} from "../libraries/BasaltConstants.sol";
import {IBasaltMath} from "../interfaces/IBasaltMath.sol";

contract BasaltMath is IBasaltMath {
    uint256 public constant BPS = BasaltConstants.BPS;
    uint256 public constant SHARE_UNIT = BasaltConstants.SHARE_UNIT;

    // ════════════════════════════════════════════════════════════════════════
    //  1. PRICE SCALE CONVERSIONS
    // ════════════════════════════════════════════════════════════════════════

    // E28 → E18.
    function toWbtcPriceE18FromE28(uint256 wbtcPriceE28) external pure returns (uint256) {
        return wbtcPriceE28 / 1e10;
    }

    // E28 → E8.
    function toWbtcPriceE8FromE28(uint256 wbtcPriceE28) external pure returns (uint256) {
        return wbtcPriceE28 / 1e20;
    }

    // E18 → E8.
    function toWbtcPriceE8FromE18(uint256 wbtcPriceE18) external pure returns (uint256) {
        return wbtcPriceE18 / 1e10;
    }

    // ════════════════════════════════════════════════════════════════════════
    //  2. USD VALUATION  (token amount → USD)
    // ════════════════════════════════════════════════════════════════════════

    // gm × gmPrice / 1e18.
    function calcCollUsdE18(uint256 gmCollateralE18, uint256 gmPriceUsdE18) external pure returns (uint256) {
        return Math.mulDiv(gmCollateralE18, gmPriceUsdE18, 1e18);
    }

    // wbtc × wbtcPrice / 1e8.
    function calcDebtUsdE18(uint256 wbtcDebtE8, uint256 wbtcPriceUsdE18) external pure returns (uint256) {
        return Math.mulDiv(wbtcDebtE8, wbtcPriceUsdE18, 1e8);
    }

    function calcGmValueE18(uint256 gmAmountE18, uint256 gmPriceE18) external pure returns (uint256) {
        return Math.mulDiv(gmAmountE18, gmPriceE18, 1e18);
    }

    // gm × gmPrice in E36.
    function calcCollValueE36(uint256 gmCollateralE18, uint256 gmPriceE18) external pure returns (uint256) {
        return gmCollateralE18 * gmPriceE18;
    }

    // wbtc × wbtcPrice in E36.
    function calcDebtValueE36(uint256 wbtcDebtE8, uint256 wbtcPriceE28) external pure returns (uint256) {
        return wbtcDebtE8 * wbtcPriceE28;
    }

    // NAV = (collUsd + surplusUsd) − debtUsd, floored at 0.
    function calcNavUsdE18(
        uint256 gmCollateralE18,
        uint256 wbtcSurplusE8,
        uint256 wbtcDebtE8,
        uint256 gmPriceUsdE18,
        uint256 wbtcPriceUsdE18
    ) external pure returns (uint256) {
        uint256 gmCollateralUsdE18 = Math.mulDiv(gmCollateralE18, gmPriceUsdE18, 1e18);
        uint256 wbtcSurplusUsdE18 = Math.mulDiv(wbtcSurplusE8, wbtcPriceUsdE18, 1e8);
        uint256 wbtcDebtUsdE18 = Math.mulDiv(wbtcDebtE8, wbtcPriceUsdE18, 1e8);
        uint256 grossAssetsUsdE18 = gmCollateralUsdE18 + wbtcSurplusUsdE18;
        return grossAssetsUsdE18 > wbtcDebtUsdE18 ? grossAssetsUsdE18 - wbtcDebtUsdE18 : 0;
    }

    // ════════════════════════════════════════════════════════════════════════
    //  3. USD → TOKEN INVERSION  (USD value → token amount)
    // ════════════════════════════════════════════════════════════════════════

    function calcGmFromUsdE18(uint256 usdValueE18, uint256 gmPriceUsdE18) external pure returns (uint256) {
        return Math.mulDiv(usdValueE18, 1e18, gmPriceUsdE18);
    }

    function calcWbtcFromUsdE18(uint256 usdValueE18, uint256 wbtcPriceUsdE18) external pure returns (uint256) {
        return Math.mulDiv(usdValueE18, 1e8, wbtcPriceUsdE18);
    }

    // borrow-USD E18 → WBTC E8.
    function calcBorrowWbtcE8FromBorrowValueE18(uint256 borrowValueE18, uint256 wbtcPriceE18)
        external
        pure
        returns (uint256)
    {
        return Math.mulDiv(borrowValueE18, 1e8, wbtcPriceE18);
    }

    // ════════════════════════════════════════════════════════════════════════
    //  4. LTV RISK MEASUREMENT
    // ════════════════════════════════════════════════════════════════════════

    // debt × BPS / coll.
    function calcLtvBps(uint256 debtUsdE18, uint256 collUsdE18) external pure returns (uint256) {
        if (collUsdE18 == 0) return 0;
        return Math.mulDiv(debtUsdE18, BPS, collUsdE18);
    }

    // shrink coll by Dolomite premium.
    function applyCollateralPremiumE36(uint256 collValueE36, uint256 premiumE18) external pure returns (uint256) {
        return Math.mulDiv(collValueE36, 1e18, 1e18 + premiumE18);
    }

    // grow debt by Dolomite premium.
    function applyDebtPremiumE36(uint256 debtValueE36, uint256 premiumE18) external pure returns (uint256) {
        return Math.mulDiv(debtValueE36, 1e18 + premiumE18, 1e18);
    }

    // LTV from premium-adjusted E36; uint256.max when coll == 0.
    function calcLtvBpsE36(uint256 adjustedDebtE36, uint256 adjustedCollE36) external pure returns (uint256) {
        if (adjustedCollE36 == 0) return type(uint256).max;
        return Math.mulDiv(adjustedDebtE36, BPS, adjustedCollE36);
    }

    // max(current − target, 0).
    function calcLtvDeviationUpBps(uint256 currentLtvBps, uint256 targetLtvBps) external pure returns (uint256) {
        return currentLtvBps > targetLtvBps ? currentLtvBps - targetLtvBps : 0;
    }

    // max(target − current, 0).
    function calcLtvDeviationDownBps(uint256 currentLtvBps, uint256 targetLtvBps) external pure returns (uint256) {
        return targetLtvBps > currentLtvBps ? targetLtvBps - currentLtvBps : 0;
    }

    // ════════════════════════════════════════════════════════════════════════
    //  5. BORROW / LEVERAGE SIZING
    // ════════════════════════════════════════════════════════════════════════

    // coll × ltv / BPS.
    function calcTargetDebtUsdE18(uint256 collUsdE18, uint256 targetLtvBps) external pure returns (uint256) {
        return Math.mulDiv(collUsdE18, targetLtvBps, BPS);
    }

    // coll × ltv / (BPS − ltv); borrow lands at targetLtv.
    function calcBorrowValueForTargetLtvE18(uint256 collateralValueE18, uint256 targetLtvBps)
        external
        pure
        returns (uint256)
    {
        return Math.mulDiv(collateralValueE18, targetLtvBps, BPS - targetLtvBps);
    }

    function calcBorrowValueForCollateralOnlyDepositE18(
        uint256 gmCollateralE18,
        uint256 depositGmE18,
        uint256 gmPriceE18,
        uint256 targetLtvBps
    ) external pure returns (uint256) {
        uint256 collateralValueE18 = Math.mulDiv(gmCollateralE18 + depositGmE18, gmPriceE18, 1e18);
        return Math.mulDiv(collateralValueE18, targetLtvBps, BPS - targetLtvBps);
    }

    // gap × BPS / (BPS − ltv); LTV gap → coll delta.
    function calcRebalanceDelta(uint256 gapUsdE18, uint256 targetLtvBps) external pure returns (uint256) {
        return Math.mulDiv(gapUsdE18, BPS, BPS - targetLtvBps);
    }

    // amountGm × debt / coll; keeps pool ratio invariant.
    function calcRatioPreservingBorrow(uint256 amountGmE18, uint256 wbtcDebtE8, uint256 gmCollateralE18)
        external
        pure
        returns (uint256)
    {
        return Math.mulDiv(amountGmE18, wbtcDebtE8, gmCollateralE18);
    }

    // ════════════════════════════════════════════════════════════════════════
    //  6. SLIPPAGE & WRAP/UNWRAP EXPECTATION
    // ════════════════════════════════════════════════════════════════════════

    // amount × (BPS − slippage) / BPS.
    function applySlippage(uint256 amount, uint256 slippageBps) external pure returns (uint256) {
        return (amount * (BPS - slippageBps)) / BPS;
    }

    // parity GM out, no slippage.
    function calcExpectedGmOutE18(uint256 borrowWbtcE8, uint256 wbtcPriceUsdE18, uint256 gmPriceUsdE18)
        external
        pure
        returns (uint256)
    {
        return Math.mulDiv(borrowWbtcE8 * wbtcPriceUsdE18, 1e10, gmPriceUsdE18);
    }

    // min GM out after user slippage.
    function calcGmReceivedMinE18(
        uint256 borrowWbtcE8,
        uint256 userSlippageBps,
        uint256 wbtcPriceE8,
        uint256 gmPriceE18
    ) external pure returns (uint256) {
        uint256 borrowValueE18 = borrowWbtcE8 * wbtcPriceE8 * 1e2;
        return Math.mulDiv(borrowValueE18 * (BPS - userSlippageBps), 1e18, gmPriceE18 * BPS);
    }

    // long-side share of parity unwrap out.
    function calcExpectedWbtcOutLongSideE8(
        uint256 gmToSellE18,
        uint256 gmPriceUsdE18,
        uint256 wbtcPriceUsdE18,
        uint256 longShareBps
    ) external pure returns (uint256) {
        uint256 fullParityE8 = Math.mulDiv(gmToSellE18, gmPriceUsdE18, wbtcPriceUsdE18 * 1e10);
        return Math.mulDiv(fullParityE8, longShareBps, BPS);
    }

    // ════════════════════════════════════════════════════════════════════════
    //  7. POST-ACTION POSITION PROJECTION
    // ════════════════════════════════════════════════════════════════════════

    // projected LTV after (deposit + wrap + borrow).
    function calcPostDepositLtvBps(
        uint256 gmCollateralE18,
        uint256 depositGmE18,
        uint256 minGmFromWrapE18,
        uint256 gmPriceE18,
        uint256 wbtcDebtE8,
        uint256 borrowWbtcE8,
        uint256 wbtcPriceE18
    ) external pure returns (uint256) {
        uint256 collateralValueE18 = Math.mulDiv(gmCollateralE18 + depositGmE18 + minGmFromWrapE18, gmPriceE18, 1e18);
        uint256 debtValueE18 = Math.mulDiv(wbtcDebtE8 + borrowWbtcE8, wbtcPriceE18, 1e8);
        if (collateralValueE18 == 0) return 0;
        return Math.mulDiv(debtValueE18, BPS, collateralValueE18);
    }

    // (coll+gmOut, debt+borrow).
    function calcPostRebalanceUpPosition(
        uint256 currentGmCollateralE18,
        uint256 minGmOutE18,
        uint256 currentWbtcDebtE8,
        uint256 borrowWbtcE8
    ) external pure returns (uint256 postCollateralE18, uint256 postDebtE8) {
        postCollateralE18 = currentGmCollateralE18 + minGmOutE18;
        postDebtE8 = currentWbtcDebtE8 + borrowWbtcE8;
    }

    // (coll−gmSell, max(debt−wbtcOut, 0)).
    function calcPostRebalanceDownPosition(
        uint256 currentGmCollateralE18,
        uint256 gmToSellE18,
        uint256 currentWbtcDebtE8,
        uint256 minWbtcOutE8
    ) external pure returns (uint256 postCollateralE18, uint256 postDebtE8) {
        postCollateralE18 = currentGmCollateralE18 - gmToSellE18;
        postDebtE8 = currentWbtcDebtE8 > minWbtcOutE8 ? currentWbtcDebtE8 - minWbtcOutE8 : 0;
    }

    // ════════════════════════════════════════════════════════════════════════
    //  8. WITHDRAW FLOW
    // ════════════════════════════════════════════════════════════════════════

    // ceil(coll × 1e18 / debt); snapshot ratio at withdraw init.
    function calcWithdrawRawRatioInitialE18(uint256 gmCollateralE18, uint256 wbtcDebtE8)
        external
        pure
        returns (uint256)
    {
        return Math.mulDiv(gmCollateralE18, 1e18, wbtcDebtE8, Math.Rounding.Ceil);
    }

    // currColl × rawRatioScale / rawRatioE18; preserves rawRatio.
    function calcWithdrawBorrowFromRatio(uint256 currentCollateralE18, uint256 rawRatioScale, uint256 rawRatioE18)
        external
        pure
        returns (uint256)
    {
        return Math.mulDiv(currentCollateralE18, rawRatioScale, rawRatioE18);
    }

    // pro-rata GM for shares.
    function calcProRataGm(uint256 gmCollateralE18, uint256 sharesToWithdraw, uint256 totalShares)
        external
        pure
        returns (uint256)
    {
        return Math.mulDiv(gmCollateralE18, sharesToWithdraw, totalShares);
    }

    // pro-rata token for shares.
    function calcProRataRedeem(uint256 tokenBalance, uint256 sharesToBurn, uint256 totalShares)
        external
        pure
        returns (uint256)
    {
        return Math.mulDiv(tokenBalance, sharesToBurn, totalShares);
    }

    // totalShares × (NAV − accrued) / NAV.
    function calcOwnerEligibleWithdrawShares(
        uint256 navUsdE18,
        uint256 managerAccruedFeeUsdE18,
        uint256 totalSharesE18
    ) external pure returns (uint256) {
        if (navUsdE18 == 0 || managerAccruedFeeUsdE18 >= navUsdE18) return 0;
        return Math.mulDiv(totalSharesE18, navUsdE18 - managerAccruedFeeUsdE18, navUsdE18);
    }

    // min(totalShares × accrued/NAV, complement of owner slice).
    function calcManagerMaxFeeWithdrawShares(
        uint256 navUsdE18,
        uint256 managerAccruedFeeUsdE18,
        uint256 totalSharesE18
    ) external pure returns (uint256) {
        if (navUsdE18 == 0 || managerAccruedFeeUsdE18 == 0) return 0;
        uint256 ownerEligible;
        if (managerAccruedFeeUsdE18 >= navUsdE18) {
            ownerEligible = 0;
        } else {
            ownerEligible = Math.mulDiv(totalSharesE18, navUsdE18 - managerAccruedFeeUsdE18, navUsdE18);
        }
        uint256 feeBound = Math.mulDiv(totalSharesE18, managerAccruedFeeUsdE18, navUsdE18);
        uint256 complement = totalSharesE18 - ownerEligible;
        return feeBound < complement ? feeBound : complement;
    }

    // surplus + borrow.
    function calcWbtcToUserFromSurplusAndBorrow(uint256 currentSurplusE8, uint256 wbtcToBorrowE8)
        external
        pure
        returns (uint256)
    {
        return currentSurplusE8 + wbtcToBorrowE8;
    }

    // max(target − adjusted, 0).
    function calcWbtcToUserFromDebtRepay(uint256 targetDebtE8, uint256 adjustedDebtE8)
        external
        pure
        returns (uint256)
    {
        if (adjustedDebtE8 >= targetDebtE8) return 0;
        return targetDebtE8 - adjustedDebtE8;
    }

    // ════════════════════════════════════════════════════════════════════════
    //  9. DOLOMITE BORROW-INDEX SCALING
    // ════════════════════════════════════════════════════════════════════════

    // par × index / 1e18; par → wei.
    function calcScaledByIndexE18(uint256 parAmount, uint256 indexE18) external pure returns (uint256) {
        return Math.mulDiv(parAmount, indexE18, 1e18);
    }

    // debt × snapshotIdx / currIdx; strips accrued interest.
    function calcDebtScaledByIndexRatio(uint256 currentDebtE8, uint256 snapshotIndexE18, uint256 currentIndexE18)
        external
        pure
        returns (uint256)
    {
        if (currentIndexE18 <= snapshotIndexE18) return currentDebtE8;
        return Math.mulDiv(currentDebtE8, snapshotIndexE18, currentIndexE18);
    }

    // ════════════════════════════════════════════════════════════════════════
    //  10. FEE MATH  (Enzyme-style HWM over absolute profit)
    // ════════════════════════════════════════════════════════════════════════
    //   profit = max(NAV − deposited + withdrawn, 0)
    //   HWM   := max(profit, HWM)
    //   delta  = max(profit − HWMprev, 0)
    //   fee    = delta × feeBps / BPS
    //   withdraw(manager): accrued -= paidOutUsd

    // profit = NAV + withdrawn − deposited, floored at 0.
    function calcProfitUsdE18(uint256 navUsdE18, uint256 totalDepositedUsdE18, uint256 totalWithdrawnUsdE18)
        external
        pure
        returns (uint256)
    {
        uint256 gross = navUsdE18 + totalWithdrawnUsdE18;
        return gross > totalDepositedUsdE18 ? gross - totalDepositedUsdE18 : 0;
    }

    // gm·gmPrice + wbtc·wbtcPrice.
    function calcWithdrawnUsdE18(
        uint256 gmAmountE18,
        uint256 gmPriceUsdE18,
        uint256 wbtcAmountE8,
        uint256 wbtcPriceUsdE18
    ) external pure returns (uint256) {
        uint256 gmUsdE18 = Math.mulDiv(gmAmountE18, gmPriceUsdE18, 1e18);
        uint256 wbtcUsdE18 = Math.mulDiv(wbtcAmountE8, wbtcPriceUsdE18, 1e8);
        return gmUsdE18 + wbtcUsdE18;
    }

    // (delta, fee) where delta = max(profit − prevHwm, 0).
    function calcPerformanceFeeByHwmProfit(
        uint256 currentProfitUsdE18,
        uint256 prevHwmProfitUsdE18,
        uint256 performanceFeeBps
    ) external pure returns (uint256 profitDeltaUsdE18, uint256 performanceFeeUsdE18) {
        if (currentProfitUsdE18 <= prevHwmProfitUsdE18) return (0, 0);
        profitDeltaUsdE18 = currentProfitUsdE18 - prevHwmProfitUsdE18;
        performanceFeeUsdE18 = profitDeltaUsdE18 * performanceFeeBps / BPS;
    }

    // monotonic max(profit, prevHwm).
    function calcNextHighWaterMarkProfit(uint256 currentProfitUsdE18, uint256 prevHwmProfitUsdE18)
        external
        pure
        returns (uint256)
    {
        return currentProfitUsdE18 > prevHwmProfitUsdE18 ? currentProfitUsdE18 : prevHwmProfitUsdE18;
    }

    // prev + added.
    function calcNextAccruedManagerFee(uint256 prevAccruedUsdE18, uint256 addedFeeUsdE18)
        external
        pure
        returns (uint256)
    {
        return prevAccruedUsdE18 + addedFeeUsdE18;
    }

    // max(prev − sub, 0).
    function calcNextAccruedManagerFeeAfterWithdraw(uint256 prevAccruedUsdE18, uint256 withdrawnFeeUsdE18)
        external
        pure
        returns (uint256)
    {
        return prevAccruedUsdE18 > withdrawnFeeUsdE18 ? prevAccruedUsdE18 - withdrawnFeeUsdE18 : 0;
    }

    // ════════════════════════════════════════════════════════════════════════
    //  11. DEPOSIT ACCOUNTING HELPERS
    // ════════════════════════════════════════════════════════════════════════

    // pre-op snapshot + queued.
    function calcPendingTotalGmE18(uint256 pendingSnapshotGmE18, uint256 pendingAmountGmE18)
        external
        pure
        returns (uint256)
    {
        return pendingSnapshotGmE18 + pendingAmountGmE18;
    }

    // msg.value − spent.
    function calcRefundEthWei(uint256 msgValueWei, uint256 spentWei) external pure returns (uint256) {
        return msgValueWei - spentWei;
    }

    // ════════════════════════════════════════════════════════════════════════
    //  12. TIME / BLOCK GATES
    // ════════════════════════════════════════════════════════════════════════

    // now + deadline.
    function calcKeeperDeadlineTimestamp(uint256 nowTimestamp, uint256 keeperDeadlineSeconds)
        external
        pure
        returns (uint256)
    {
        return nowTimestamp + keeperDeadlineSeconds;
    }

    // deadline + grace.
    function calcUnstuckNotBefore(uint256 deadline, uint256 graceSeconds) external pure returns (uint256) {
        return deadline + graceSeconds;
    }

    // currentBlock + cooldown.
    function calcCooldownEndBlock(uint256 currentBlockNumber, uint256 cooldownBlocks)
        external
        pure
        returns (uint256)
    {
        return currentBlockNumber + cooldownBlocks;
    }

    // max(cooldownEnd − current, 0).
    function calcRemainingCooldownBlocks(uint256 cooldownEndBlockNum, uint256 currentBlockNumber)
        external
        pure
        returns (uint256)
    {
        return cooldownEndBlockNum > currentBlockNumber ? cooldownEndBlockNum - currentBlockNumber : 0;
    }

    // ════════════════════════════════════════════════════════════════════════
    //  13. GENERIC ARITHMETIC IDIOMS
    // ════════════════════════════════════════════════════════════════════════

    // |a − b|.
    function calcAbsDiff(uint256 a, uint256 b) external pure returns (uint256) {
        return a > b ? a - b : b - a;
    }

    // max(a − b, 0).
    function subFloorZero(uint256 a, uint256 b) external pure returns (uint256) {
        return a > b ? a - b : 0;
    }

    // numerator × BPS / denominator, 0 if denom == 0.
    function calcBpsRatio(uint256 numerator, uint256 denominator) external pure returns (uint256) {
        if (denominator == 0) return 0;
        return Math.mulDiv(numerator, BPS, denominator);
    }

    // floor mulDiv.
    function mulDiv(uint256 a, uint256 b, uint256 c) external pure returns (uint256) {
        return Math.mulDiv(a, b, c);
    }

    // ceil mulDiv.
    function mulDivCeil(uint256 a, uint256 b, uint256 c) external pure returns (uint256) {
        return Math.mulDiv(a, b, c, Math.Rounding.Ceil);
    }
}
