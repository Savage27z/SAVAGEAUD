// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IBasaltMath} from "../../interfaces/IBasaltMath.sol";
import {IFeeAccountingHandlerVaultCore} from "../../interfaces/IFeeAccountingHandlerVaultCore.sol";
import {IWithdrawHandlerVaultCore} from "../../interfaces/IWithdrawHandlerVaultCore.sol";
import {BasaltConstants} from "../../libraries/BasaltConstants.sol";
import {BasaltMath} from "../../pure/BasaltMath.sol";
import {VaultState} from "../../core/VaultState.sol";
import {FeeAccountingHandler} from "../FeeAccountingHandler.sol";
import {WithdrawHandlerCalculations} from "./WithdrawHandlerCalculations.sol";
import {WithdrawBranch, WithdrawContext, WithdrawPreview} from "./WithdrawHandlerTypes.sol";

library WithdrawHandlerViewHelpers {
    // ────────────────────────────────────────────────────────────────────────
    //  WITHDRAW PREVIEW ELIGIBILITY HELPERS
    // ────────────────────────────────────────────────────────────────────────

    function fillWithdrawPreviewEligibility(
        IWithdrawHandlerVaultCore targetVaultCore,
        BasaltMath basaltMath,
        WithdrawContext memory withdrawContext
    ) internal view returns (WithdrawPreview memory withdrawPreview) {
        VaultState vaultState = VaultState(targetVaultCore.basaltState());
        withdrawPreview.withdrawContext = withdrawContext;
        withdrawPreview.currentManagerAccruedFeeUsdE18 = vaultState.managerAccruedFeeUsdE18();
        withdrawPreview.previewManagerAccruedFeeUsdE18 = readPreviewManagerAccruedFeeUsdE18(targetVaultCore, basaltMath);

        withdrawPreview.ownerEligibleSharesE18 = WithdrawHandlerCalculations.calcOwnerEligibleWithdrawShares(
            basaltMath,
            withdrawContext.navUsdE18,
            withdrawPreview.previewManagerAccruedFeeUsdE18,
            BasaltConstants.SHARE_UNIT
        );
        withdrawContext.managerAccruedFeeUsdE18 = withdrawPreview.previewManagerAccruedFeeUsdE18;
        withdrawContext.ownerEligibleSharesE18 = withdrawPreview.ownerEligibleSharesE18;
        withdrawPreview.isShareEligibleToWithdraw =
            withdrawContext.sharesToWithdrawE18 <= withdrawPreview.ownerEligibleSharesE18;
        withdrawPreview.withdrawContext = withdrawContext;
    }

    function readPreviewManagerAccruedFeeUsdE18(IWithdrawHandlerVaultCore targetVaultCore, BasaltMath basaltMath)
        internal
        view
        returns (uint256 previewManagerAccruedFeeUsdE18)
    {
        (
            uint256 currentNavUsdE18,
            uint256 feeBaseUsdE18,
            uint256 netProfitUsdE18,
            uint256 performanceFeeUsdE18,
            uint256 nextHighWaterMarkNavUsdE18,
            uint256 nextManagerAccruedFeeUsdE18
        ) = FeeAccountingHandler(targetVaultCore.feeAccountingHandler()).calculateManagerFee(
            IFeeAccountingHandlerVaultCore(address(targetVaultCore)), IBasaltMath(address(basaltMath))
        );

        // We only surface `nextManagerAccruedFeeUsdE18` here; the rest of the tuple is
        // consumed by the production fee flow. Silence the unused-local warnings by touching
        // each value — the optimizer removes these reads.
        currentNavUsdE18;
        feeBaseUsdE18;
        netProfitUsdE18;
        performanceFeeUsdE18;
        nextHighWaterMarkNavUsdE18;
        previewManagerAccruedFeeUsdE18 = nextManagerAccruedFeeUsdE18;
    }

    // ────────────────────────────────────────────────────────────────────────
    //  WITHDRAW PREVIEW OUTPUT HELPERS
    // ────────────────────────────────────────────────────────────────────────

    function fillWithdrawPreviewOutputs(BasaltMath basaltMath, WithdrawPreview memory withdrawPreview)
        internal
        pure
        returns (WithdrawPreview memory)
    {
        WithdrawContext memory withdrawContext = withdrawPreview.withdrawContext;

        if (withdrawContext.branch == WithdrawBranch.AsyncDebt) {
            withdrawPreview.gmToSellE18 = WithdrawHandlerCalculations.calcGmToSell(
                basaltMath,
                withdrawContext.gmCollateralE18,
                withdrawContext.sharesToWithdrawE18,
                BasaltConstants.SHARE_UNIT
            );
            withdrawContext.gmToSellE18 = withdrawPreview.gmToSellE18;
        } else if (withdrawContext.branch == WithdrawBranch.SyncGmWithSurplus) {
            withdrawPreview.gmToReceiveE18 = WithdrawHandlerCalculations.calcGmToReturn(
                basaltMath,
                withdrawContext.gmCollateralE18,
                withdrawContext.sharesToWithdrawE18,
                BasaltConstants.SHARE_UNIT
            );
            withdrawPreview.wbtcToReceiveE8 = WithdrawHandlerCalculations.calcSurplusToReturn(
                basaltMath,
                withdrawContext.wbtcSurplusE8,
                withdrawContext.sharesToWithdrawE18,
                BasaltConstants.SHARE_UNIT
            );
            withdrawContext.gmToReturnE18 = withdrawPreview.gmToReceiveE18;
            withdrawContext.surplusToReturnE8 = withdrawPreview.wbtcToReceiveE8;
        } else if (withdrawContext.branch == WithdrawBranch.SyncGmOnly) {
            withdrawPreview.gmToReceiveE18 = WithdrawHandlerCalculations.calcGmToReturn(
                basaltMath,
                withdrawContext.gmCollateralE18,
                withdrawContext.sharesToWithdrawE18,
                BasaltConstants.SHARE_UNIT
            );
            withdrawContext.gmToReturnE18 = withdrawPreview.gmToReceiveE18;
        } else if (withdrawContext.branch == WithdrawBranch.SyncWbtcSurplusOnly) {
            withdrawPreview.wbtcToReceiveE8 = WithdrawHandlerCalculations.calcSurplusToReturn(
                basaltMath,
                withdrawContext.wbtcSurplusE8,
                withdrawContext.sharesToWithdrawE18,
                BasaltConstants.SHARE_UNIT
            );
            withdrawContext.surplusToReturnE8 = withdrawPreview.wbtcToReceiveE8;
        }

        withdrawPreview.withdrawContext = withdrawContext;
        return withdrawPreview;
    }
}
