// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {BasaltMath} from "../pure/BasaltMath.sol";
import {VaultState} from "../core/VaultState.sol";
import {IManagerHandler} from "../interfaces/IManagerHandler.sol";
import {IManagerHandlerVaultCore} from "../interfaces/IManagerHandlerVaultCore.sol";
import {IManagerHandlerVaultCoreNftFactory} from "../interfaces/IManagerHandlerVaultCoreNftFactory.sol";
import {ManagerHandlerCalculations} from "./managerHandlerLibraries/ManagerHandlerCalculations.sol";
import {ManagerHandlerExecutors} from "./managerHandlerLibraries/ManagerHandlerExecutors.sol";
import {ManagerHandlerReaders} from "./managerHandlerLibraries/ManagerHandlerReaders.sol";
import {ManagerHandlerRequirements} from "./managerHandlerLibraries/ManagerHandlerRequirements.sol";
import {
    REBALANCE_KIND_LTV,
    LtvAlreadyAtTarget,
    NoCollateral,
    NotProtocolManager,
    RebalanceNotPending,
    RebalanceSnapshot,
    RebalanceStillPending,
    WrongRebalanceKind,
    ZeroRebalanceAmount
} from "./managerHandlerLibraries/ManagerHandlerTypes.sol";

contract ManagerHandler is ReentrancyGuard, IManagerHandler {
    // ────────────────────────────────────────────────────────────────────────
    //  EVENTS
    // ────────────────────────────────────────────────────────────────────────

    event RebalanceInitiated(
        address indexed caller, bool isLoopUp, uint256 amount, uint256 minOut, bool isInitiatedByNftOwner
    );
    event RebalanceFinalized(address indexed caller, bool success, uint256 ltvBefore, uint256 ltvAfter);
    event PendingRebalanceCleared();

    event TargetLtvUpdated(uint256 nextTargetLtvBps);
    event KeeperDeadlineUpdated(uint256 nextKeeperDeadline);
    event RebalanceSlippageCapUpdated(uint256 bps);
    event UnwrapLongShareBpsUpdated(uint256 bps);
    event RebalanceThresholdUpBpsUpdated(uint256 bps);
    event RebalanceThresholdDownBpsUpdated(uint256 bps);
    event ManagerHeartbeat(address indexed caller);

    // ────────────────────────────────────────────────────────────────────────
    //  MODIFIERS
    // ────────────────────────────────────────────────────────────────────────

    modifier onlyProtocolManager(IManagerHandlerVaultCore targetVaultCore) {
        address protocolManager = IManagerHandlerVaultCoreNftFactory(targetVaultCore.FACTORY()).protocolManager();
        if (msg.sender != protocolManager) revert NotProtocolManager();
        _;
    }

    // ════════════════════════════════════════════════════════════════════════
    //  PROTOCOL MANAGER (`VaultCoreNftFactory.protocolManager`) — vault tuning
    // ════════════════════════════════════════════════════════════════════════

    function setTargetLtv(IManagerHandlerVaultCore targetVaultCore, uint256 nextTargetLtvBps)
        external
        onlyProtocolManager(targetVaultCore)
    {
        ManagerHandlerRequirements.requireAllIdle(targetVaultCore);
        ManagerHandlerRequirements.requireCooldownPassed(targetVaultCore);
        ManagerHandlerRequirements.requireTargetLtvInBounds(nextTargetLtvBps);
        ManagerHandlerExecutors.configureSetTargetLtvBps(targetVaultCore, nextTargetLtvBps);
        ManagerHandlerExecutors.bumpLastManagerAction(targetVaultCore);
        emit TargetLtvUpdated(nextTargetLtvBps);
    }

    function setKeeperDeadline(IManagerHandlerVaultCore targetVaultCore, uint256 nextKeeperDeadline)
        external
        onlyProtocolManager(targetVaultCore)
    {
        ManagerHandlerRequirements.requireAllIdle(targetVaultCore);
        ManagerHandlerRequirements.requireCooldownPassed(targetVaultCore);
        ManagerHandlerExecutors.configureSetKeeperDeadline(targetVaultCore, nextKeeperDeadline);
        ManagerHandlerExecutors.bumpLastManagerAction(targetVaultCore);
        emit KeeperDeadlineUpdated(nextKeeperDeadline);
    }

    function setRebalanceSlippageCapBps(IManagerHandlerVaultCore targetVaultCore, uint256 bps)
        external
        onlyProtocolManager(targetVaultCore)
    {
        ManagerHandlerRequirements.requireAllIdle(targetVaultCore);
        ManagerHandlerRequirements.requireCooldownPassed(targetVaultCore);
        ManagerHandlerRequirements.requireSlippageCapInBounds(bps);
        ManagerHandlerExecutors.configureSetRebalanceSlippageCapBps(targetVaultCore, bps);
        ManagerHandlerExecutors.bumpLastManagerAction(targetVaultCore);
        emit RebalanceSlippageCapUpdated(bps);
    }

    function setUnwrapLongShareBps(IManagerHandlerVaultCore targetVaultCore, uint256 bps)
        external
        onlyProtocolManager(targetVaultCore)
    {
        ManagerHandlerRequirements.requireAllIdle(targetVaultCore);
        ManagerHandlerRequirements.requireCooldownPassed(targetVaultCore);
        ManagerHandlerRequirements.requireUnwrapLongShareInBounds(bps);
        ManagerHandlerExecutors.configureSetUnwrapLongShareBps(targetVaultCore, bps);
        ManagerHandlerExecutors.bumpLastManagerAction(targetVaultCore);
        emit UnwrapLongShareBpsUpdated(bps);
    }

    function setRebalanceThresholdUpBps(IManagerHandlerVaultCore targetVaultCore, uint256 bps)
        external
        onlyProtocolManager(targetVaultCore)
    {
        ManagerHandlerRequirements.requireAllIdle(targetVaultCore);
        ManagerHandlerRequirements.requireCooldownPassed(targetVaultCore);
        ManagerHandlerRequirements.requireRebalanceThresholdInBounds(bps);
        ManagerHandlerExecutors.configureSetRebalanceThresholdUpBps(targetVaultCore, bps);
        ManagerHandlerExecutors.bumpLastManagerAction(targetVaultCore);
        emit RebalanceThresholdUpBpsUpdated(bps);
    }

    function setRebalanceThresholdDownBps(IManagerHandlerVaultCore targetVaultCore, uint256 bps)
        external
        onlyProtocolManager(targetVaultCore)
    {
        ManagerHandlerRequirements.requireAllIdle(targetVaultCore);
        ManagerHandlerRequirements.requireCooldownPassed(targetVaultCore);
        ManagerHandlerRequirements.requireRebalanceThresholdInBounds(bps);
        ManagerHandlerExecutors.configureSetRebalanceThresholdDownBps(targetVaultCore, bps);
        ManagerHandlerExecutors.bumpLastManagerAction(targetVaultCore);
        emit RebalanceThresholdDownBpsUpdated(bps);
    }

    function pingHeartbeat(IManagerHandlerVaultCore targetVaultCore)
        external
        onlyProtocolManager(targetVaultCore)
    {
        ManagerHandlerExecutors.bumpLastManagerAction(targetVaultCore);
        emit ManagerHeartbeat(msg.sender);
    }

    // ════════════════════════════════════════════════════════════════════════
    //  LTV REBALANCE — manager anytime; vault NFT owner only past thresholds
    // ════════════════════════════════════════════════════════════════════════

    // protocolManager: any LTV ≠ target. NFT owner: only past thresholds.
    function rebalance(IManagerHandlerVaultCore targetVaultCore, uint256 managerSlippageBps)
        external
        payable
        nonReentrant
    {
        ManagerHandlerRequirements.requireAllIdle(targetVaultCore);
        ManagerHandlerRequirements.requireCooldownPassed(targetVaultCore);
        ManagerHandlerRequirements.requireValidSlippage(targetVaultCore, managerSlippageBps);
        ManagerHandlerRequirements.requireSequencerUp();

        bool isProtocolManager = msg.sender
            == IManagerHandlerVaultCoreNftFactory(targetVaultCore.FACTORY()).protocolManager();
        if (!isProtocolManager) {
            ManagerHandlerRequirements.requireVaultNftOwner(targetVaultCore);
        }

        BasaltMath basaltMath = BasaltMath(targetVaultCore.basaltMath());
        RebalanceSnapshot memory rebalanceSnapshot = ManagerHandlerReaders.readDolomiteSnapshot(targetVaultCore);
        if (rebalanceSnapshot.totalGmCollateralE18 == 0) revert NoCollateral();

        (uint256 collUsdE18, uint256 debtUsdE18, uint256 currentLtv) =
            ManagerHandlerCalculations.calcCollDebtUsdAndLtvBps(basaltMath, rebalanceSnapshot);

        VaultState vaultState = ManagerHandlerReaders.readVaultState(targetVaultCore);
        uint256 targetLtv = vaultState.targetLtvBps();

        if (currentLtv == targetLtv) {
            revert LtvAlreadyAtTarget(collUsdE18, debtUsdE18);
        }
        if (!isProtocolManager) {
            ManagerHandlerRequirements.requireNftOwnerRebalanceDeviation(targetVaultCore, currentLtv, targetLtv);
        }

        bool initiatedByVaultNftOwner = !isProtocolManager;

        if (currentLtv > targetLtv) {
            uint256 gmToSellE18 = ManagerHandlerCalculations.gmToSellForRebalanceDown(
                basaltMath, rebalanceSnapshot, collUsdE18, debtUsdE18, targetLtv
            );
            _rebalanceDownToLtv(
                targetVaultCore, basaltMath, gmToSellE18, managerSlippageBps, rebalanceSnapshot, initiatedByVaultNftOwner
            );
        } else {
            uint256 borrowWbtcE8 = ManagerHandlerCalculations.borrowWbtcForRebalanceUp(
                basaltMath, rebalanceSnapshot, collUsdE18, debtUsdE18, targetLtv
            );
            _rebalanceUpToLtv(
                targetVaultCore, basaltMath, borrowWbtcE8, managerSlippageBps, rebalanceSnapshot, initiatedByVaultNftOwner
            );
        }
    }

    function finalizeRebalance(IManagerHandlerVaultCore targetVaultCore) external nonReentrant {
        ManagerHandlerRequirements.requireCallerIsProtocolManagerOrVaultNftOwner(targetVaultCore);
        VaultState vaultState = ManagerHandlerReaders.readVaultState(targetVaultCore);
        if (vaultState.rebalanceState() != VaultState.State.PENDING) revert RebalanceNotPending();
        if (vaultState.pendingRebalanceKind() != uint8(REBALANCE_KIND_LTV)) revert WrongRebalanceKind();
        if (ManagerHandlerReaders.readIsVaultFrozen(targetVaultCore)) revert RebalanceStillPending();

        uint256 ltvBeforeBps = vaultState.pendingRebalanceLtvSnapshotBps();
        BasaltMath basaltMath = BasaltMath(targetVaultCore.basaltMath());
        RebalanceSnapshot memory rebalanceSnapshot = ManagerHandlerReaders.readDolomiteSnapshot(targetVaultCore);
        (,, uint256 ltvAfterBps) = ManagerHandlerCalculations.calcCollDebtUsdAndLtvBps(basaltMath, rebalanceSnapshot);

        ManagerHandlerExecutors.clearPendingRebalanceAccounting(targetVaultCore);
        emit PendingRebalanceCleared();
        emit RebalanceFinalized(msg.sender, true, ltvBeforeBps, ltvAfterBps);
    }

    // ════════════════════════════════════════════════════════════════════════
    //  PUBLIC VIEWS
    // ════════════════════════════════════════════════════════════════════════

    function currentLtvBps(IManagerHandlerVaultCore targetVaultCore) external view returns (uint256) {
        BasaltMath basaltMath = BasaltMath(targetVaultCore.basaltMath());
        RebalanceSnapshot memory rebalanceSnapshot = ManagerHandlerReaders.readDolomiteSnapshot(targetVaultCore);
        return ManagerHandlerCalculations.currentLtvBpsFromSnapshot(basaltMath, rebalanceSnapshot);
    }

    // ════════════════════════════════════════════════════════════════════════
    //  INTERNAL — LTV REBALANCE BRANCHES
    // ════════════════════════════════════════════════════════════════════════

    function _rebalanceUpToLtv(
        IManagerHandlerVaultCore targetVaultCore,
        BasaltMath basaltMath,
        uint256 borrowWbtcE8,
        uint256 managerSlippageBps,
        RebalanceSnapshot memory rebalanceSnapshot,
        bool initiatedByVaultNftOwner
    ) internal {
        ManagerHandlerRequirements.requireAsyncPreChecks(targetVaultCore, managerSlippageBps);
        if (borrowWbtcE8 == 0) revert ZeroRebalanceAmount();

        uint256 expectedGmOutE18 =
            ManagerHandlerCalculations.calcExpectedGmOutE18(targetVaultCore, borrowWbtcE8, rebalanceSnapshot);
        uint256 minGmOutE18 = ManagerHandlerCalculations.applySlippage(basaltMath, expectedGmOutE18, managerSlippageBps);
        if (minGmOutE18 == 0) revert ZeroRebalanceAmount();

        (uint256 postCollateralE18, uint256 postDebtE8) = basaltMath.calcPostRebalanceUpPosition(
            rebalanceSnapshot.totalGmCollateralE18, minGmOutE18, rebalanceSnapshot.totalWbtcDebtE8, borrowWbtcE8
        );
        ManagerHandlerRequirements.requirePostLtvSafe(basaltMath, postCollateralE18, postDebtE8);

        address dolomite = ManagerHandlerReaders.readDolomiteIsolationVault(targetVaultCore);
        VaultState vaultState = ManagerHandlerReaders.readVaultState(targetVaultCore);
        uint256 keeperDeadlineSeconds = vaultState.keeperDeadline();
        address initiator = msg.sender;
        uint256 ltvBpsBeforeAsyncStep = ManagerHandlerCalculations.currentLtvBpsFromSnapshot(basaltMath, rebalanceSnapshot);

        ManagerHandlerExecutors.setPendingRebalanceLtvUp(targetVaultCore, initiator, ltvBpsBeforeAsyncStep, keeperDeadlineSeconds);
        ManagerHandlerExecutors.dolomiteAsyncWrapForRebalance(
            targetVaultCore, dolomite, borrowWbtcE8, minGmOutE18, msg.value
        );

        emit RebalanceInitiated(msg.sender, true, borrowWbtcE8, minGmOutE18, initiatedByVaultNftOwner);
    }

    function _rebalanceDownToLtv(
        IManagerHandlerVaultCore targetVaultCore,
        BasaltMath basaltMath,
        uint256 gmToSellE18,
        uint256 managerSlippageBps,
        RebalanceSnapshot memory rebalanceSnapshot,
        bool initiatedByVaultNftOwner
    ) internal {
        ManagerHandlerRequirements.requireAsyncPreChecks(targetVaultCore, managerSlippageBps);
        if (gmToSellE18 == 0) revert ZeroRebalanceAmount();
        if (gmToSellE18 > rebalanceSnapshot.totalGmCollateralE18) {
            gmToSellE18 = rebalanceSnapshot.totalGmCollateralE18;
        }

        uint256 expectedWbtcOutE8 =
            ManagerHandlerCalculations.calcExpectedWbtcOutE8(targetVaultCore, gmToSellE18, rebalanceSnapshot);
        uint256 minWbtcOutE8 =
            ManagerHandlerCalculations.applySlippage(basaltMath, expectedWbtcOutE8, managerSlippageBps);
        if (minWbtcOutE8 == 0) revert ZeroRebalanceAmount();

        (uint256 postCollateralE18, uint256 postDebtE8) = basaltMath.calcPostRebalanceDownPosition(
            rebalanceSnapshot.totalGmCollateralE18, gmToSellE18, rebalanceSnapshot.totalWbtcDebtE8, minWbtcOutE8
        );
        ManagerHandlerRequirements.requirePostLtvSafe(basaltMath, postCollateralE18, postDebtE8);

        address dolomite = ManagerHandlerReaders.readDolomiteIsolationVault(targetVaultCore);
        VaultState vaultState = ManagerHandlerReaders.readVaultState(targetVaultCore);
        uint256 keeperDeadlineSeconds = vaultState.keeperDeadline();
        address initiator = msg.sender;
        uint256 ltvBpsBeforeAsyncStep = ManagerHandlerCalculations.currentLtvBpsFromSnapshot(basaltMath, rebalanceSnapshot);

        ManagerHandlerExecutors.setPendingRebalanceLtvDown(targetVaultCore, initiator, ltvBpsBeforeAsyncStep, keeperDeadlineSeconds);
        ManagerHandlerExecutors.dolomiteAsyncUnwrapForRebalance(
            targetVaultCore, dolomite, gmToSellE18, minWbtcOutE8, msg.value
        );

        emit RebalanceInitiated(msg.sender, false, gmToSellE18, minWbtcOutE8, initiatedByVaultNftOwner);
    }
}
