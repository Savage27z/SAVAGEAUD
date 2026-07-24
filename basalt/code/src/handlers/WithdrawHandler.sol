// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {BasaltAddresses} from "../libraries/BasaltAddresses.sol";
import {BasaltConstants} from "../libraries/BasaltConstants.sol";
import {DolomiteReader} from "../libraries/DolomiteReader.sol";
import {IDolomiteMargin} from "../interfaces/IDolomiteMargin.sol";
import {IWithdrawHandler} from "../interfaces/IWithdrawHandler.sol";
import {IWithdrawHandlerVaultCore} from "../interfaces/IWithdrawHandlerVaultCore.sol";
import {IWithdrawHandlerVaultCoreNftFactory} from "../interfaces/IWithdrawHandlerVaultCoreNftFactory.sol";
import {BasaltMath} from "../pure/BasaltMath.sol";
import {VaultState} from "../core/VaultState.sol";
import {WithdrawHandlerCalculations} from "./withdrawHandlerLibraries/WithdrawHandlerCalculations.sol";
import {WithdrawHandlerExecutors} from "./withdrawHandlerLibraries/WithdrawHandlerExecutors.sol";
import {WithdrawHandlerReaders} from "./withdrawHandlerLibraries/WithdrawHandlerReaders.sol";
import {WithdrawHandlerRequirements} from "./withdrawHandlerLibraries/WithdrawHandlerRequirements.sol";
import {WithdrawHandlerViewHelpers} from "./withdrawHandlerLibraries/WithdrawHandlerViewHelpers.sol";
import {
    NotIdle,
    NothingToWithdraw,
    WithdrawBranch,
    WithdrawContext,
    WithdrawPreview,
    WithdrawSharePolicy
} from "./withdrawHandlerLibraries/WithdrawHandlerTypes.sol";

contract WithdrawHandler is ReentrancyGuard, IWithdrawHandler {
    // ────────────────────────────────────────────────────────────────────────
    //  EVENTS
    // ────────────────────────────────────────────────────────────────────────

    event AsyncWithdrawInitiated(address indexed withdrawer, uint256 shares, uint256 gmToSell, uint256 minWbtcOut);
    event SyncGmWithdraw(address indexed withdrawer, uint256 shares, uint256 gmReturned);
    event SyncGmWithSurplusWithdraw(
        address indexed withdrawer, uint256 shares, uint256 gmReturned, uint256 wbtcReturned
    );
    event SyncWbtcSurplusWithdraw(address indexed withdrawer, uint256 shares, uint256 wbtcReturned);
    event WithdrawFinalized(address indexed withdrawer, uint256 shares, uint256 wbtcOut, bool success);

    // ────────────────────────────────────────────────────────────────────────
    //  MODIFIERS
    // ────────────────────────────────────────────────────────────────────────

    modifier onlyVaultNftOwner(IWithdrawHandlerVaultCore targetVaultCore) {
        WithdrawHandlerRequirements.requireVaultNftOwner(targetVaultCore);
        _;
    }

    // ════════════════════════════════════════════════════════════════════════
    //  NFT OWNER EXTERNAL WRITE FUNCTIONS
    // ════════════════════════════════════════════════════════════════════════

    function withdraw(IWithdrawHandlerVaultCore targetVaultCore, uint256 sharesToWithdraw, uint256 minWbtcOutE8)
        external
        payable
        nonReentrant
        onlyVaultNftOwner(targetVaultCore)
    {
        WithdrawHandlerRequirements.requireAllIdle(targetVaultCore);
        WithdrawHandlerRequirements.requireCooldownPassed(targetVaultCore);
        WithdrawHandlerRequirements.requireValidPositionShareToWithdraw(sharesToWithdraw);
        WithdrawHandlerRequirements.requireSequencerUp();
        WithdrawHandlerExecutors.accrueManagerFeeBeforeWithdraw(targetVaultCore);
        WithdrawHandlerRequirements.requireSharesWithinOwnerEligibleWithdraw(targetVaultCore, sharesToWithdraw);

        address withdrawer = IWithdrawHandlerVaultCoreNftFactory(targetVaultCore.FACTORY())
            .ownerOfVault(address(targetVaultCore));
        _executeWithdrawBranch(
            targetVaultCore, withdrawer, sharesToWithdraw, minWbtcOutE8, WithdrawSharePolicy.OwnerEligible
        );
    }

    // protocol-manager-only fee leg; capped by calcManagerMaxFeeWithdrawShares.
    function withdrawManagerFeeShares(IWithdrawHandlerVaultCore targetVaultCore, uint256 sharesToWithdraw, uint256 minWbtcOutE8)
        external
        payable
        nonReentrant
    {
        WithdrawHandlerRequirements.requireProtocolManager(targetVaultCore);
        WithdrawHandlerRequirements.requireAllIdle(targetVaultCore);
        WithdrawHandlerRequirements.requireCooldownPassed(targetVaultCore);
        WithdrawHandlerRequirements.requireValidPositionShareToWithdraw(sharesToWithdraw);
        WithdrawHandlerRequirements.requireSequencerUp();
        WithdrawHandlerExecutors.accrueManagerFeeBeforeWithdraw(targetVaultCore);
        WithdrawHandlerRequirements.requireSharesWithinManagerFeeWithdraw(targetVaultCore, sharesToWithdraw);

        _executeWithdrawBranch(
            targetVaultCore, msg.sender, sharesToWithdraw, minWbtcOutE8, WithdrawSharePolicy.ManagerFee
        );
    }

    // ════════════════════════════════════════════════════════════════════════
    //  MANAGER OR VAULT NFT OWNER — FINALIZE
    // ════════════════════════════════════════════════════════════════════════

    function finalizeWithdraw(IWithdrawHandlerVaultCore targetVaultCore) external nonReentrant {
        WithdrawHandlerRequirements.requireCallerIsProtocolManagerOrVaultNftOwner(targetVaultCore);
        VaultState vaultState = VaultState(targetVaultCore.basaltState());
        WithdrawHandlerRequirements.requireWithdrawPending(vaultState);
        WithdrawHandlerRequirements.requireCooldownPassed(targetVaultCore);
        WithdrawHandlerRequirements.requireVaultNotFrozen(targetVaultCore);
        WithdrawHandlerRequirements.requireSequencerUp();

        address withdrawer = vaultState.pendingWithdrawer();
        uint256 shares = vaultState.pendingWithdrawSharesE18();
        uint256 snapshotCollateralE18 = vaultState.pendingWithdrawCollateralSnapshotE18();
        uint256 rawRatioE18 = vaultState.pendingWithdrawRawRatioInitialE18();
        uint256 rawRatioScale = BasaltConstants.RAW_RATIO_SCALE;
        bool isManagerFee = vaultState.pendingWithdrawIsManagerFee();

        BasaltMath basaltMath = BasaltMath(targetVaultCore.basaltMath());
        uint256 currentCollateralE18 = WithdrawHandlerReaders.readVaultGmCollateralE18(targetVaultCore);

        // keeper did not execute async unwrap → no GM movement
        if (currentCollateralE18 == snapshotCollateralE18) {
            WithdrawHandlerExecutors.clearPendingWithdraw(targetVaultCore);
            emit WithdrawFinalized(withdrawer, shares, 0, false);
            return;
        }

        uint256 currentDebtE8 = WithdrawHandlerReaders.readVaultWbtcDebtE8(targetVaultCore);

        if (currentDebtE8 > 0) {
            _finalizeWithDebt(
                targetVaultCore,
                basaltMath,
                withdrawer,
                shares,
                currentCollateralE18,
                currentDebtE8,
                rawRatioE18,
                rawRatioScale,
                vaultState.pendingWithdrawBorrowIndexE18(),
                isManagerFee
            );
        } else {
            _finalizeWithSurplus(
                targetVaultCore,
                basaltMath,
                withdrawer,
                shares,
                currentCollateralE18,
                rawRatioE18,
                rawRatioScale,
                isManagerFee
            );
        }
    }

    // ════════════════════════════════════════════════════════════════════════
    //  PUBLIC VIEW FUNCTIONS
    // ════════════════════════════════════════════════════════════════════════

    function collectWithdrawContext(
        IWithdrawHandlerVaultCore targetVaultCore,
        address withdrawer,
        uint256 positionShareToWithdrawE18,
        uint256 minWbtcOutE8
    ) public view returns (WithdrawContext memory withdrawContext) {
        withdrawContext.withdrawer = withdrawer;
        withdrawContext.sharesToWithdrawE18 = positionShareToWithdrawE18;
        withdrawContext.minWbtcOutE8 = minWbtcOutE8;
        withdrawContext.gmCollateralE18 = WithdrawHandlerReaders.readVaultGmCollateralE18(targetVaultCore);
        withdrawContext.wbtcDebtE8 = WithdrawHandlerReaders.readVaultWbtcDebtE8(targetVaultCore);
        withdrawContext.wbtcSurplusE8 = WithdrawHandlerReaders.readVaultWbtcSurplusE8(targetVaultCore);
        withdrawContext.totalSharesE18 = BasaltConstants.SHARE_UNIT;
        withdrawContext.navUsdE18 = WithdrawHandlerReaders.readVaultNavUsdE18(targetVaultCore);
    }

    function selectWithdrawBranch(
        IWithdrawHandlerVaultCore targetVaultCore,
        address withdrawer,
        uint256 positionShareToWithdrawE18,
        uint256 minWbtcOutE8,
        WithdrawSharePolicy sharePolicy
    ) public view returns (WithdrawContext memory withdrawContext) {
        WithdrawHandlerRequirements.requireValidPositionShareToWithdraw(positionShareToWithdrawE18);
        if (sharePolicy == WithdrawSharePolicy.OwnerEligible) {
            WithdrawHandlerRequirements.requireSharesWithinOwnerEligibleWithdraw(
                targetVaultCore, positionShareToWithdrawE18
            );
        } else {
            WithdrawHandlerRequirements.requireSharesWithinManagerFeeWithdraw(
                targetVaultCore, positionShareToWithdrawE18
            );
        }

        withdrawContext = collectWithdrawContext(targetVaultCore, withdrawer, positionShareToWithdrawE18, minWbtcOutE8);

        if (withdrawContext.gmCollateralE18 > 0 && withdrawContext.wbtcDebtE8 > 0) {
            withdrawContext.branch = WithdrawBranch.AsyncDebt;
        } else if (withdrawContext.gmCollateralE18 > 0 && withdrawContext.wbtcSurplusE8 > 0) {
            withdrawContext.branch = WithdrawBranch.SyncGmWithSurplus;
        } else if (withdrawContext.gmCollateralE18 > 0) {
            withdrawContext.branch = WithdrawBranch.SyncGmOnly;
        } else if (withdrawContext.wbtcSurplusE8 > 0) {
            withdrawContext.branch = WithdrawBranch.SyncWbtcSurplusOnly;
        } else {
            revert NothingToWithdraw();
        }
    }

    function previewWithdraw(IWithdrawHandlerVaultCore targetVaultCore, uint256 positionShareToWithdrawE18)
        public
        view
        returns (WithdrawPreview memory withdrawPreview)
    {
        WithdrawHandlerRequirements.requireValidPositionShareToWithdraw(positionShareToWithdrawE18);

        BasaltMath basaltMath = BasaltMath(targetVaultCore.basaltMath());
        address withdrawer = IWithdrawHandlerVaultCoreNftFactory(targetVaultCore.FACTORY())
            .ownerOfVault(address(targetVaultCore));
        WithdrawContext memory withdrawContext =
            selectWithdrawBranch(targetVaultCore, withdrawer, positionShareToWithdrawE18, 0, WithdrawSharePolicy.OwnerEligible);

        withdrawPreview =
            WithdrawHandlerViewHelpers.fillWithdrawPreviewEligibility(targetVaultCore, basaltMath, withdrawContext);
        withdrawPreview = WithdrawHandlerViewHelpers.fillWithdrawPreviewOutputs(basaltMath, withdrawPreview);
    }

    function managerMaxFeeWithdrawShares(IWithdrawHandlerVaultCore targetVaultCore) external view returns (uint256) {
        uint256 navUsdE18 = WithdrawHandlerReaders.readVaultNavUsdE18(targetVaultCore);
        uint256 managerAccruedFeeUsdE18 = VaultState(targetVaultCore.basaltState()).managerAccruedFeeUsdE18();
        return WithdrawHandlerCalculations.calcManagerMaxFeeWithdrawShares(
            BasaltMath(targetVaultCore.basaltMath()), navUsdE18, managerAccruedFeeUsdE18, BasaltConstants.SHARE_UNIT
        );
    }

    // ════════════════════════════════════════════════════════════════════════
    //  BRANCH ROUTING HELPER
    // ════════════════════════════════════════════════════════════════════════

    function _executeWithdrawBranch(
        IWithdrawHandlerVaultCore targetVaultCore,
        address withdrawer,
        uint256 sharesToWithdraw,
        uint256 minWbtcOutE8,
        WithdrawSharePolicy sharePolicy
    ) internal {
        BasaltMath basaltMath = BasaltMath(targetVaultCore.basaltMath());
        WithdrawContext memory withdrawContext =
            selectWithdrawBranch(targetVaultCore, withdrawer, sharesToWithdraw, minWbtcOutE8, sharePolicy);
        bool isManagerFee = sharePolicy == WithdrawSharePolicy.ManagerFee;

        if (withdrawContext.branch == WithdrawBranch.AsyncDebt) {
            _execAsyncWithdraw(
                targetVaultCore,
                basaltMath,
                withdrawContext.withdrawer,
                withdrawContext.sharesToWithdrawE18,
                withdrawContext.minWbtcOutE8,
                withdrawContext.gmCollateralE18,
                withdrawContext.wbtcDebtE8,
                withdrawContext.totalSharesE18,
                isManagerFee
            );
        } else if (withdrawContext.branch == WithdrawBranch.SyncGmWithSurplus) {
            WithdrawHandlerRequirements.requireNoValue();
            _execSyncGmWithSurplus(
                targetVaultCore,
                basaltMath,
                withdrawContext.withdrawer,
                withdrawContext.sharesToWithdrawE18,
                withdrawContext.gmCollateralE18,
                withdrawContext.wbtcSurplusE8,
                withdrawContext.totalSharesE18,
                isManagerFee
            );
        } else if (withdrawContext.branch == WithdrawBranch.SyncGmOnly) {
            WithdrawHandlerRequirements.requireNoValue();
            _execSyncGm(
                targetVaultCore,
                basaltMath,
                withdrawContext.withdrawer,
                withdrawContext.sharesToWithdrawE18,
                withdrawContext.gmCollateralE18,
                withdrawContext.totalSharesE18,
                isManagerFee
            );
        } else if (withdrawContext.branch == WithdrawBranch.SyncWbtcSurplusOnly) {
            WithdrawHandlerRequirements.requireNoValue();
            _execSyncWbtcSurplus(
                targetVaultCore,
                basaltMath,
                withdrawContext.withdrawer,
                withdrawContext.sharesToWithdrawE18,
                withdrawContext.wbtcSurplusE8,
                withdrawContext.totalSharesE18,
                isManagerFee
            );
        }
    }

    // ════════════════════════════════════════════════════════════════════════
    //  ASYNC WITHDRAW BRANCH
    // ════════════════════════════════════════════════════════════════════════

    function _execAsyncWithdraw(
        IWithdrawHandlerVaultCore targetVaultCore,
        BasaltMath basaltMath,
        address withdrawer,
        uint256 sharesToWithdrawE18,
        uint256 minWbtcOutE8,
        uint256 gmCollateralE18,
        uint256 debtE8,
        uint256 totalSharesE18,
        bool isManagerFee
    ) internal {
        uint256 gmToSellE18 = WithdrawHandlerCalculations.calcGmToSell(
            basaltMath, gmCollateralE18, sharesToWithdrawE18, totalSharesE18
        );
        uint256 rawRatioInitialE18 =
            WithdrawHandlerCalculations.calcRawRatioInitial(basaltMath, gmCollateralE18, debtE8);
        uint256 borrowIndexE18 = DolomiteReader.getWbtcBorrowIndexE18(IDolomiteMargin(BasaltAddresses.DOLOMITE_MARGIN));

        WithdrawHandlerExecutors.setPendingWithdraw(
            targetVaultCore,
            withdrawer,
            sharesToWithdrawE18,
            gmToSellE18,
            minWbtcOutE8,
            gmCollateralE18,
            debtE8,
            rawRatioInitialE18,
            borrowIndexE18,
            isManagerFee
        );
        WithdrawHandlerExecutors.asyncUnwrap(targetVaultCore, gmToSellE18, minWbtcOutE8, msg.value);

        emit AsyncWithdrawInitiated(withdrawer, sharesToWithdrawE18, gmToSellE18, minWbtcOutE8);
    }

    // ════════════════════════════════════════════════════════════════════════
    //  SYNC WITHDRAW BRANCHES
    // ════════════════════════════════════════════════════════════════════════

    function _execSyncGm(
        IWithdrawHandlerVaultCore targetVaultCore,
        BasaltMath basaltMath,
        address withdrawer,
        uint256 sharesToWithdrawE18,
        uint256 gmCollateralE18,
        uint256 totalSharesE18,
        bool isManagerFee
    ) internal {
        uint256 gmToReturnE18 = WithdrawHandlerCalculations.calcGmToReturn(
            basaltMath, gmCollateralE18, sharesToWithdrawE18, totalSharesE18
        );

        WithdrawHandlerExecutors.withdrawGmToUser(targetVaultCore, withdrawer, gmToReturnE18);
        _recordWithdrawnUsdByPolicy(targetVaultCore, gmToReturnE18, 0, isManagerFee);

        emit SyncGmWithdraw(withdrawer, sharesToWithdrawE18, gmToReturnE18);
    }

    function _execSyncGmWithSurplus(
        IWithdrawHandlerVaultCore targetVaultCore,
        BasaltMath basaltMath,
        address withdrawer,
        uint256 sharesToWithdrawE18,
        uint256 gmCollateralE18,
        uint256 surplusE8,
        uint256 totalSharesE18,
        bool isManagerFee
    ) internal {
        uint256 gmToReturnE18 = WithdrawHandlerCalculations.calcGmToReturn(
            basaltMath, gmCollateralE18, sharesToWithdrawE18, totalSharesE18
        );
        uint256 surplusToReturnE8 =
            WithdrawHandlerCalculations.calcSurplusToReturn(basaltMath, surplusE8, sharesToWithdrawE18, totalSharesE18);

        WithdrawHandlerExecutors.withdrawGmToUser(targetVaultCore, withdrawer, gmToReturnE18);
        if (surplusToReturnE8 > 0) {
            WithdrawHandlerExecutors.withdrawWbtcToUser(targetVaultCore, withdrawer, surplusToReturnE8);
        }
        _recordWithdrawnUsdByPolicy(targetVaultCore, gmToReturnE18, surplusToReturnE8, isManagerFee);

        emit SyncGmWithSurplusWithdraw(withdrawer, sharesToWithdrawE18, gmToReturnE18, surplusToReturnE8);
    }

    function _execSyncWbtcSurplus(
        IWithdrawHandlerVaultCore targetVaultCore,
        BasaltMath basaltMath,
        address withdrawer,
        uint256 sharesToWithdrawE18,
        uint256 surplusE8,
        uint256 totalSharesE18,
        bool isManagerFee
    ) internal {
        uint256 surplusToReturnE8 = WithdrawHandlerCalculations.calcSurplusToReturn(
            basaltMath, surplusE8, sharesToWithdrawE18, totalSharesE18
        );

        if (surplusToReturnE8 > 0) {
            WithdrawHandlerExecutors.withdrawWbtcToUser(targetVaultCore, withdrawer, surplusToReturnE8);
        }
        _recordWithdrawnUsdByPolicy(targetVaultCore, 0, surplusToReturnE8, isManagerFee);

        emit SyncWbtcSurplusWithdraw(withdrawer, sharesToWithdrawE18, surplusToReturnE8);
    }

    // dispatch per policy: owner-leg → recordWithdrawnUsd; fee-leg → recordManagerFeeWithdrawnUsd
    function _recordWithdrawnUsdByPolicy(
        IWithdrawHandlerVaultCore targetVaultCore,
        uint256 gmAmountE18,
        uint256 wbtcAmountE8,
        bool isManagerFee
    ) internal {
        if (isManagerFee) {
            WithdrawHandlerExecutors.recordManagerFeeWithdrawnUsd(targetVaultCore, gmAmountE18, wbtcAmountE8);
        } else {
            WithdrawHandlerExecutors.recordWithdrawnUsd(targetVaultCore, gmAmountE18, wbtcAmountE8);
        }
    }

    // ════════════════════════════════════════════════════════════════════════
    //  FINALIZE BRANCHES
    // ════════════════════════════════════════════════════════════════════════

    function _finalizeWithSurplus(
        IWithdrawHandlerVaultCore targetVaultCore,
        BasaltMath basaltMath,
        address withdrawer,
        uint256 shares,
        uint256 currentCollateralE18,
        uint256 rawRatioE18,
        uint256 rawRatioScale,
        bool isManagerFee
    ) internal {
        uint256 currentSurplusE8 = WithdrawHandlerReaders.readVaultWbtcSurplusE8(targetVaultCore);
        uint256 wbtcToBorrowE8 = WithdrawHandlerCalculations.calcWbtcToBorrowForRatio(
            basaltMath, currentCollateralE18, rawRatioScale, rawRatioE18
        );
        uint256 wbtcToUserE8 = basaltMath.calcWbtcToUserFromSurplusAndBorrow(currentSurplusE8, wbtcToBorrowE8);

        uint256 actualOut = WithdrawHandlerExecutors.withdrawWbtcToUser(targetVaultCore, withdrawer, wbtcToUserE8);
        _recordWithdrawnUsdByPolicy(targetVaultCore, 0, actualOut, isManagerFee);
        WithdrawHandlerExecutors.clearPendingWithdraw(targetVaultCore);

        emit WithdrawFinalized(withdrawer, shares, actualOut, true);
    }

    function _finalizeWithDebt(
        IWithdrawHandlerVaultCore targetVaultCore,
        BasaltMath basaltMath,
        address withdrawer,
        uint256 shares,
        uint256 currentCollateralE18,
        uint256 currentDebtE8,
        uint256 rawRatioE18,
        uint256 rawRatioScale,
        uint256 snapshotIndexE18,
        bool isManagerFee
    ) internal {
        uint256 currentIndexE18 = DolomiteReader.getWbtcBorrowIndexE18(IDolomiteMargin(BasaltAddresses.DOLOMITE_MARGIN));

        uint256 adjustedDebtE8 = WithdrawHandlerCalculations.calcAdjustedDebtForBorrowIndex(
            basaltMath, currentDebtE8, snapshotIndexE18, currentIndexE18
        );
        uint256 targetDebtE8 = WithdrawHandlerCalculations.calcTargetDebtForRatio(
            basaltMath, currentCollateralE18, rawRatioScale, rawRatioE18
        );

        uint256 wbtcToUserE8 = basaltMath.calcWbtcToUserFromDebtRepay(targetDebtE8, adjustedDebtE8);
        uint256 actualOut = 0;
        if (wbtcToUserE8 > 0) {
            actualOut = WithdrawHandlerExecutors.withdrawWbtcToUser(targetVaultCore, withdrawer, wbtcToUserE8);
            _recordWithdrawnUsdByPolicy(targetVaultCore, 0, actualOut, isManagerFee);
        }
        WithdrawHandlerExecutors.clearPendingWithdraw(targetVaultCore);

        emit WithdrawFinalized(withdrawer, shares, actualOut, true);
    }
}
