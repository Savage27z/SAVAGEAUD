// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// ════════════════════════════════════════════════════════════════════════════
//  ManagerHandler — rebalance kinds, errors, Dolomite snapshot struct
// ════════════════════════════════════════════════════════════════════════════

uint8 constant REBALANCE_KIND_NONE = 0;
uint8 constant REBALANCE_KIND_LTV = 1;
uint8 constant REBALANCE_KIND_ABSORB_SURPLUS = 2;

uint8 constant REBALANCE_DIR_NONE = 0;
uint8 constant REBALANCE_DIR_UP = 1;
uint8 constant REBALANCE_DIR_DOWN = 2;

error NotIdle();
error CooldownNotPassed(uint256 blocksRemaining);
error PostSettlementLtvTooHigh(uint256 ltv, uint256 max);
error NoCollateral();
error InvalidSlippage(uint256 slippageBps);
error SlippageExceedsCap(uint256 slippageBps, uint256 capBps);
error RebalanceNotPending();
error SlippageTooTight(uint256 provided);
error WrongRebalanceKind();
error NotVaultNftOwner();
error NotManagerOrNftOwner();
error LtvAlreadyAtTarget(uint256 collUsdE18, uint256 debtUsdE18);
error RebalanceWithinNftOwnerBand(uint256 currentLtvBps, uint256 targetLtvBps);
error ZeroRebalanceAmount();
error RebalanceStillPending();
error AsyncOperationPending();
error NotProtocolManager();
error InvalidTargetLtv(uint256 nextTargetLtvBps, uint256 minTargetLtvBps, uint256 maxTargetLtvBps);
error InvalidSlippageCap(uint256 nextBps, uint256 minBps, uint256 maxBps);
error InvalidThreshold(uint256 nextBps, uint256 minBps, uint256 maxBps);
error InvalidUnwrapLongShare(uint256 nextBps, uint256 minBps, uint256 maxBps);

struct RebalanceSnapshot {
    uint256 totalGmCollateralE18;
    uint256 totalWbtcDebtE8;
    uint256 gmPriceUsdE18;
    uint256 wbtcPriceUsdE18;
}

library ManagerHandlerTypes {}
