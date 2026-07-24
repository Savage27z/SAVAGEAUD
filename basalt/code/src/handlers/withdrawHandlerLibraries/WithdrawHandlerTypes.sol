// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// ────────────────────────────────────────────────────────────────────────────
//  ERRORS
// ────────────────────────────────────────────────────────────────────────────

error NotIdle();
error CooldownNotPassed(uint256 blocksRemaining);
error InvalidPositionShareToWithdraw(uint256 positionShareToWithdrawE18, uint256 maxPositionShareE18);
error NothingToWithdraw();
error WithdrawNotPending();
error VaultStillFrozen();
error UnexpectedValue();
error SlippageExceeded(uint256 received, uint256 minOut);
error WithdrawTransferFailed(address token, address to, uint256 amount);
error NotVaultNftOwner();
error NotManagerOrNftOwner();
error WithdrawExceedsOwnerEligibleShares(
    uint256 requestedSharesE18, uint256 eligibleSharesE18, uint256 navUsdE18, uint256 managerAccruedFeeUsdE18
);
error WithdrawExceedsManagerFeeShares(
    uint256 requestedSharesE18, uint256 maxManagerFeeSharesE18, uint256 navUsdE18, uint256 managerAccruedFeeUsdE18
);
error NotProtocolManager();

// ────────────────────────────────────────────────────────────────────────────
//  BRANCH TYPES
// ────────────────────────────────────────────────────────────────────────────

enum WithdrawSharePolicy {
    OwnerEligible,
    ManagerFee
}

enum WithdrawBranch {
    AsyncDebt,
    SyncGmWithSurplus,
    SyncGmOnly,
    SyncWbtcSurplusOnly
}

// ────────────────────────────────────────────────────────────────────────────
//  WITHDRAW CONTEXT
// ────────────────────────────────────────────────────────────────────────────

struct WithdrawContext {
    WithdrawBranch branch;
    bool isShareEligibleToWithdraw;
    address withdrawer;
    uint256 sharesToWithdrawE18;
    uint256 minWbtcOutE8;
    uint256 gmCollateralE18;
    uint256 wbtcDebtE8;
    uint256 wbtcSurplusE8;
    uint256 totalSharesE18;
    uint256 navUsdE18;
    uint256 managerAccruedFeeUsdE18;
    uint256 ownerEligibleSharesE18;
    uint256 gmToSellE18;
    uint256 rawRatioInitialE18;
    uint256 borrowIndexE18;
    uint256 gmToReturnE18;
    uint256 surplusToReturnE8;
    uint256 snapshotCollateralE18;
    uint256 currentCollateralE18;
    uint256 currentDebtE8;
    uint256 currentSurplusE8;
    uint256 snapshotBorrowIndexE18;
    uint256 currentBorrowIndexE18;
    uint256 adjustedDebtE8;
    uint256 targetDebtE8;
    uint256 wbtcToUserE8;
    uint256 actualWbtcOutE8;
}

// ────────────────────────────────────────────────────────────────────────────
//  WITHDRAW PREVIEW
// ────────────────────────────────────────────────────────────────────────────

struct WithdrawPreview {
    WithdrawContext withdrawContext;
    bool isShareEligibleToWithdraw;
    uint256 currentManagerAccruedFeeUsdE18;
    uint256 previewManagerAccruedFeeUsdE18;
    uint256 ownerEligibleSharesE18;
    uint256 gmToReceiveE18;
    uint256 wbtcToReceiveE8;
    uint256 gmToSellE18;
}
