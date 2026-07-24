// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BasaltConstants} from "../libraries/BasaltConstants.sol";
import {
    AlreadyInitialized,
    DolomiteIsolationVaultAlreadyInitialized,
    InvalidManagementFee,
    ManagementFeeCannotIncrease,
    InvalidKeeperDeadline,
    InvalidTargetLtv,
    VaultNotIdle,
    NotVaultCore
} from "./vaultStateLibraries/VaultStateTypes.sol";

contract VaultState {
    enum State {
        IDLE,
        PENDING
    }

    // ════════════════════════════════════════════════════════════════════════
    //  BINDINGS
    // ════════════════════════════════════════════════════════════════════════

    address public vaultCoreClone;
    address public dolomiteIsolationVault;

    // ════════════════════════════════════════════════════════════════════════
    //  STATE MACHINE FLAGS
    // ════════════════════════════════════════════════════════════════════════

    State public depositState;
    State public withdrawState;
    State public rebalanceState;

    // ════════════════════════════════════════════════════════════════════════
    //  PENDING DEPOSIT ACCOUNTING
    // ════════════════════════════════════════════════════════════════════════

    uint256 public pendingDepositAmountGmE18;
    uint256 public pendingDepositGmPriceE18;
    uint256 public pendingDepositGmCollateralSnapshotE18;
    uint256 public pendingDepositDeadline;

    // ════════════════════════════════════════════════════════════════════════
    //  PENDING WITHDRAW ACCOUNTING
    // ════════════════════════════════════════════════════════════════════════

    address public pendingWithdrawer;
    uint256 public pendingWithdrawSharesE18;
    uint256 public pendingWithdrawGmToSellE18;
    uint256 public pendingWithdrawCollateralSnapshotE18;
    uint256 public pendingWithdrawWbtcDebtSnapshotE8;
    uint256 public pendingWithdrawRawRatioInitialE18;
    uint256 public pendingWithdrawMinWbtcOutE8;
    uint256 public pendingWithdrawBorrowIndexE18;
    uint256 public pendingWithdrawDeadline;
    bool public pendingWithdrawIsManagerFee;

    // ════════════════════════════════════════════════════════════════════════
    //  PENDING REBALANCE ACCOUNTING
    // ════════════════════════════════════════════════════════════════════════

    uint8 public pendingRebalanceKind;
    uint8 public pendingRebalanceDirection;
    address public pendingRebalanceInitiator;
    uint256 public pendingRebalanceLtvSnapshotBps;
    uint256 public pendingRebalanceDeadline;

    // ════════════════════════════════════════════════════════════════════════
    //  ACCOUNTING TOTALS + HWM
    // ════════════════════════════════════════════════════════════════════════

    uint256 public totalDepositedGmE18;
    uint256 public totalDepositedUsdE18;
    uint256 public totalWithdrawnUsdE18;
    uint256 public highWaterMarkProfitUsdE18;
    uint256 public managerAccruedFeeUsdE18;

    // ════════════════════════════════════════════════════════════════════════
    //  LAST FINALIZED DEPOSIT SNAPSHOT
    // ════════════════════════════════════════════════════════════════════════

    uint256 public lastFinalizedNavUsdE18;
    uint256 public lastFinalizedGmCollateralE18;
    uint256 public lastFinalizedWbtcDebtE8;

    // ════════════════════════════════════════════════════════════════════════
    //  COOLDOWN
    // ════════════════════════════════════════════════════════════════════════

    uint256 public globalActionCooldownEndBlock;

    // ════════════════════════════════════════════════════════════════════════
    //  CONFIG (bounded)
    // ════════════════════════════════════════════════════════════════════════

    uint256 public managementFeeBps;
    uint256 public keeperDeadline;
    uint256 public targetLtvBps;

    // ════════════════════════════════════════════════════════════════════════
    //  REBALANCE CONFIG
    // ════════════════════════════════════════════════════════════════════════

    uint256 public rebalanceThresholdUpBps;
    uint256 public rebalanceThresholdDownBps;
    uint256 public rebalanceSlippageCapBps;
    uint256 public unwrapLongShareBps;

    // ════════════════════════════════════════════════════════════════════════
    //  DEADMAN SWITCH
    // ════════════════════════════════════════════════════════════════════════

    uint256 public lastManagerActionBlock;
    bool public managerDeadmanTriggered;

    address private constant DISABLED_IMPL_SENTINEL = address(uint160(uint256(keccak256("BASALT_VAULT_STATE_IMPL"))));

    // ════════════════════════════════════════════════════════════════════════
    //  INIT
    // ════════════════════════════════════════════════════════════════════════

    constructor() {
        vaultCoreClone = DISABLED_IMPL_SENTINEL;
    }

    function initialize(address vaultCore, address /* initialManager */) external {
        if (vaultCoreClone != address(0)) revert AlreadyInitialized();
        vaultCoreClone = vaultCore;
        depositState = State.IDLE;
        withdrawState = State.IDLE;
        rebalanceState = State.IDLE;
        managementFeeBps = BasaltConstants.MANAGER_FEE_BPS;
        keeperDeadline = BasaltConstants.DEFAULT_KEEPER_DEADLINE;
        targetLtvBps = BasaltConstants.DEFAULT_TARGET_LTV_BPS;
        rebalanceThresholdUpBps = BasaltConstants.DEFAULT_REBALANCE_THRESHOLD_UP_BPS;
        rebalanceThresholdDownBps = BasaltConstants.DEFAULT_REBALANCE_THRESHOLD_DOWN_BPS;
        rebalanceSlippageCapBps = BasaltConstants.DEFAULT_REBALANCE_SLIPPAGE_CAP_BPS;
        unwrapLongShareBps = BasaltConstants.DEFAULT_UNWRAP_LONG_SHARE_BPS;
        lastManagerActionBlock = block.number;
    }

    modifier onlyVaultCore() {
        if (msg.sender != vaultCoreClone) revert NotVaultCore();
        _;
    }

    function setDolomiteIsolationVault(address nextDolomiteIsolationVault) external onlyVaultCore {
        if (dolomiteIsolationVault != address(0)) revert DolomiteIsolationVaultAlreadyInitialized();
        dolomiteIsolationVault = nextDolomiteIsolationVault;
    }

    // ════════════════════════════════════════════════════════════════════════
    //  STATE MACHINE
    // ════════════════════════════════════════════════════════════════════════

    function setDepositState(State nextDepositState) external onlyVaultCore {
        depositState = nextDepositState;
    }

    function setWithdrawState(State nextWithdrawState) external onlyVaultCore {
        withdrawState = nextWithdrawState;
    }

    function setRebalanceState(State nextRebalanceState) external onlyVaultCore {
        rebalanceState = nextRebalanceState;
    }

    function requireAllIdle() public view {
        if (depositState != State.IDLE || withdrawState != State.IDLE || rebalanceState != State.IDLE) {
            revert VaultNotIdle();
        }
    }

    // ════════════════════════════════════════════════════════════════════════
    //  DEPOSIT FLOW
    // ════════════════════════════════════════════════════════════════════════

    function setPendingDepositAccounting(
        uint256 amountGmE18,
        uint256 gmPriceE18,
        uint256 gmCollateralSnapshotE18,
        uint256 deadline
    ) external onlyVaultCore {
        pendingDepositAmountGmE18 = amountGmE18;
        pendingDepositGmPriceE18 = gmPriceE18;
        pendingDepositGmCollateralSnapshotE18 = gmCollateralSnapshotE18;
        pendingDepositDeadline = deadline;
    }

    function clearPendingDepositAccounting() external onlyVaultCore {
        delete pendingDepositDeadline;
        delete pendingDepositAmountGmE18;
        delete pendingDepositGmPriceE18;
        delete pendingDepositGmCollateralSnapshotE18;
        depositState = State.IDLE;
    }

    function finalizeDepositAccounting(
        uint256 depositedUsdE18,
        uint256 navUsdE18,
        uint256 gmCollateralE18,
        uint256 wbtcDebtE8
    ) external onlyVaultCore {
        totalDepositedGmE18 += pendingDepositAmountGmE18;
        totalDepositedUsdE18 += depositedUsdE18;
        lastFinalizedNavUsdE18 = navUsdE18;
        lastFinalizedGmCollateralE18 = gmCollateralE18;
        lastFinalizedWbtcDebtE8 = wbtcDebtE8;
        delete pendingDepositAmountGmE18;
        delete pendingDepositGmPriceE18;
        delete pendingDepositGmCollateralSnapshotE18;
        delete pendingDepositDeadline;
        depositState = State.IDLE;
    }

    function addDepositedUsdE18(uint256 depositedUsdE18) external onlyVaultCore {
        totalDepositedUsdE18 += depositedUsdE18;
    }

    // ════════════════════════════════════════════════════════════════════════
    //  WITHDRAW FLOW
    // ════════════════════════════════════════════════════════════════════════

    function setPendingWithdrawAccounting(
        address withdrawer,
        uint256 sharesE18,
        uint256 gmToSellE18,
        uint256 collateralSnapshotE18,
        uint256 wbtcDebtSnapshotE8,
        uint256 rawRatioInitialE18,
        uint256 minWbtcOutE8,
        uint256 borrowIndexE18,
        uint256 deadline,
        bool isManagerFee
    ) external onlyVaultCore {
        pendingWithdrawer = withdrawer;
        pendingWithdrawSharesE18 = sharesE18;
        pendingWithdrawGmToSellE18 = gmToSellE18;
        pendingWithdrawCollateralSnapshotE18 = collateralSnapshotE18;
        pendingWithdrawWbtcDebtSnapshotE8 = wbtcDebtSnapshotE8;
        pendingWithdrawRawRatioInitialE18 = rawRatioInitialE18;
        pendingWithdrawMinWbtcOutE8 = minWbtcOutE8;
        pendingWithdrawBorrowIndexE18 = borrowIndexE18;
        pendingWithdrawDeadline = deadline;
        pendingWithdrawIsManagerFee = isManagerFee;
        withdrawState = State.PENDING;
    }

    function clearPendingWithdrawAccounting() external onlyVaultCore {
        delete pendingWithdrawer;
        delete pendingWithdrawSharesE18;
        delete pendingWithdrawGmToSellE18;
        delete pendingWithdrawCollateralSnapshotE18;
        delete pendingWithdrawWbtcDebtSnapshotE8;
        delete pendingWithdrawRawRatioInitialE18;
        delete pendingWithdrawMinWbtcOutE8;
        delete pendingWithdrawBorrowIndexE18;
        delete pendingWithdrawDeadline;
        delete pendingWithdrawIsManagerFee;
        withdrawState = State.IDLE;
    }

    function addWithdrawnUsdE18(uint256 withdrawnUsdE18) external onlyVaultCore {
        totalWithdrawnUsdE18 += withdrawnUsdE18;
    }

    // ════════════════════════════════════════════════════════════════════════
    //  REBALANCE FLOW
    // ════════════════════════════════════════════════════════════════════════

    function setPendingRebalance(
        uint8 kind,
        uint8 direction,
        address initiator,
        uint256 ltvSnapshotBps,
        uint256 deadline
    ) external onlyVaultCore {
        pendingRebalanceKind = kind;
        pendingRebalanceDirection = direction;
        pendingRebalanceInitiator = initiator;
        pendingRebalanceLtvSnapshotBps = ltvSnapshotBps;
        pendingRebalanceDeadline = deadline;
        rebalanceState = State.PENDING;
    }

    function clearPendingRebalance() external onlyVaultCore {
        delete pendingRebalanceKind;
        delete pendingRebalanceDirection;
        delete pendingRebalanceInitiator;
        delete pendingRebalanceLtvSnapshotBps;
        delete pendingRebalanceDeadline;
        rebalanceState = State.IDLE;
    }

    // ════════════════════════════════════════════════════════════════════════
    //  FEE ACCOUNTING (HWM + accrued)
    // ════════════════════════════════════════════════════════════════════════

    function setFeeAccounting(uint256 nextHighWaterMarkProfitUsdE18, uint256 nextManagerAccruedFeeUsdE18)
        external
        onlyVaultCore
    {
        highWaterMarkProfitUsdE18 = nextHighWaterMarkProfitUsdE18;
        managerAccruedFeeUsdE18 = nextManagerAccruedFeeUsdE18;
    }

    function subAccruedManagerFeeUsdE18(uint256 withdrawnFeeUsdE18) external onlyVaultCore {
        managerAccruedFeeUsdE18 =
            managerAccruedFeeUsdE18 > withdrawnFeeUsdE18 ? managerAccruedFeeUsdE18 - withdrawnFeeUsdE18 : 0;
    }

    // ════════════════════════════════════════════════════════════════════════
    //  COOLDOWN
    // ════════════════════════════════════════════════════════════════════════

    function startGlobalActionCooldown(uint256 cooldownEndBlock) external onlyVaultCore {
        globalActionCooldownEndBlock = cooldownEndBlock;
    }

    // ════════════════════════════════════════════════════════════════════════
    //  CONFIG (bounded)
    // ════════════════════════════════════════════════════════════════════════

    function setKeeperDeadline(uint256 nextKeeperDeadline) external onlyVaultCore {
        if (
            nextKeeperDeadline < BasaltConstants.MIN_KEEPER_DEADLINE
                || nextKeeperDeadline > BasaltConstants.MAX_KEEPER_DEADLINE
        ) {
            revert InvalidKeeperDeadline(
                nextKeeperDeadline, BasaltConstants.MIN_KEEPER_DEADLINE, BasaltConstants.MAX_KEEPER_DEADLINE
            );
        }
        keeperDeadline = nextKeeperDeadline;
    }

    function setTargetLtvBps(uint256 nextTargetLtvBps) external onlyVaultCore {
        requireAllIdle();
        if (
            nextTargetLtvBps < BasaltConstants.MIN_TARGET_LTV_BPS
                || nextTargetLtvBps > BasaltConstants.MAX_TARGET_LTV_BPS
        ) {
            revert InvalidTargetLtv(
                nextTargetLtvBps, BasaltConstants.MIN_TARGET_LTV_BPS, BasaltConstants.MAX_TARGET_LTV_BPS
            );
        }
        targetLtvBps = nextTargetLtvBps;
    }

    function setManagementFeeBps(uint256 nextManagementFeeBps) external onlyVaultCore {
        if (nextManagementFeeBps > BasaltConstants.MANAGER_FEE_BPS) {
            revert InvalidManagementFee(nextManagementFeeBps, 0, BasaltConstants.MANAGER_FEE_BPS);
        }
        if (nextManagementFeeBps > managementFeeBps) {
            revert ManagementFeeCannotIncrease(managementFeeBps, nextManagementFeeBps);
        }
        managementFeeBps = nextManagementFeeBps;
    }

    // ════════════════════════════════════════════════════════════════════════
    //  CONFIG (unbounded — caller validates)
    // ════════════════════════════════════════════════════════════════════════

    function setRebalanceSlippageCapBps(uint256 v) external onlyVaultCore {
        rebalanceSlippageCapBps = v;
    }

    function setUnwrapLongShareBps(uint256 v) external onlyVaultCore {
        unwrapLongShareBps = v;
    }

    function setRebalanceThresholdUpBps(uint256 newBps) external onlyVaultCore {
        rebalanceThresholdUpBps = newBps;
    }

    function setRebalanceThresholdDownBps(uint256 newBps) external onlyVaultCore {
        rebalanceThresholdDownBps = newBps;
    }

    // ════════════════════════════════════════════════════════════════════════
    //  DEADMAN SWITCH
    // ════════════════════════════════════════════════════════════════════════

    function bumpLastManagerAction() external onlyVaultCore {
        lastManagerActionBlock = block.number;
    }

    function setManagerDeadmanTriggered() external onlyVaultCore {
        managerDeadmanTriggered = true;
    }
}
