// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {IBasaltMath} from "../interfaces/IBasaltMath.sol";
import {BasaltConstants} from "../libraries/BasaltConstants.sol";
import {IDolomiteIsolationVault} from "../interfaces/IDolomiteVault.sol";
import {
    IUpgradeableAsyncIsolationModeUnwrapperTrader,
    IUpgradeableAsyncIsolationModeWrapperTrader
} from "../interfaces/IDolomiteAsyncTraders.sol";
import {
    AsyncRecoveryOperation,
    AsyncRecoveryPendingOperation,
    IAsyncRecoveryHandlerVaultCore
} from "./asyncRecoveryHandlerLibraries/AsyncRecoveryHandlerTypes.sol";
import {AsyncRecoveryHandlerCalculations} from "./asyncRecoveryHandlerLibraries/AsyncRecoveryHandlerCalculations.sol";
import {AsyncRecoveryHandlerExecutors} from "./asyncRecoveryHandlerLibraries/AsyncRecoveryHandlerExecutors.sol";
import {AsyncRecoveryHandlerReaders} from "./asyncRecoveryHandlerLibraries/AsyncRecoveryHandlerReaders.sol";
import {AsyncRecoveryHandlerRequirements} from "./asyncRecoveryHandlerLibraries/AsyncRecoveryHandlerRequirements.sol";

contract AsyncRecoveryHandler is ReentrancyGuard {
    constructor(address, address, address) {}

    // ────────────────────────────────────────────────────────────────────────
    //  EVENTS
    // ────────────────────────────────────────────────────────────────────────

    event UnstuckRequested(bytes32 indexed key, bool isDepositCancel, address indexed caller);

    // ────────────────────────────────────────────────────────────────────────
    //  CONSTANTS
    // ────────────────────────────────────────────────────────────────────────

    uint256 public constant UNSTUCK_GRACE_AFTER_DEADLINE = BasaltConstants.UNSTUCK_GRACE_AFTER_DEADLINE;

    // ────────────────────────────────────────────────────────────────────────
    //  MODIFIERS
    // ────────────────────────────────────────────────────────────────────────

    modifier onlyProtocolManagerOrVaultNftOwner(IAsyncRecoveryHandlerVaultCore targetVaultCore) {
        AsyncRecoveryHandlerRequirements.requireCallerIsProtocolManagerOrVaultNftOwner(targetVaultCore);
        _;
    }

    // ════════════════════════════════════════════════════════════════════════
    //  PROTOCOL MANAGER OR VAULT NFT OWNER
    // ════════════════════════════════════════════════════════════════════════

    function unstuckPending(IAsyncRecoveryHandlerVaultCore targetVaultCore, bytes32 key)
        external
        nonReentrant
        onlyProtocolManagerOrVaultNftOwner(targetVaultCore)
    {
        AsyncRecoveryPendingOperation memory pendingOperation =
            AsyncRecoveryHandlerReaders.resolvePendingOperation(targetVaultCore);
        AsyncRecoveryHandlerRequirements.requireVaultHasPendingAsyncOperation(pendingOperation);
        AsyncRecoveryHandlerRequirements.requireUnstuckAllowedForWrite(targetVaultCore, pendingOperation);

        IDolomiteIsolationVault dolomiteIsolationVault =
            AsyncRecoveryHandlerReaders.readDolomiteIsolationVault(targetVaultCore);
        AsyncRecoveryHandlerRequirements.requireDolomiteIsolationVaultStillFrozen(dolomiteIsolationVault);

        bool isDepositCancel = pendingOperation.operation == AsyncRecoveryOperation.Wrap;
        if (!isDepositCancel) {
            address unwrapperTrader = AsyncRecoveryHandlerReaders.readUnwrapperAddress();
            AsyncRecoveryHandlerRequirements.requireUnwrapperTraderConfigured(unwrapperTrader);
            IUpgradeableAsyncIsolationModeUnwrapperTrader.WithdrawalInfo memory withdrawalInfo =
                AsyncRecoveryHandlerReaders.readWithdrawalInfo(unwrapperTrader, key);
            AsyncRecoveryHandlerRequirements.requireWithdrawalAsyncKeyTargetsThisVaultAndAccount(
                withdrawalInfo, dolomiteIsolationVault
            );
        } else {
            address wrapperTrader = AsyncRecoveryHandlerReaders.readWrapperAddress();
            AsyncRecoveryHandlerRequirements.requireWrapperTraderConfigured(wrapperTrader);
            IUpgradeableAsyncIsolationModeWrapperTrader.DepositInfo memory depositInfo =
                AsyncRecoveryHandlerReaders.readDepositInfo(wrapperTrader, key);
            AsyncRecoveryHandlerRequirements.requireDepositAsyncKeyTargetsThisVaultAndAccount(
                depositInfo, dolomiteIsolationVault
            );
        }

        AsyncRecoveryHandlerExecutors.cancelAsyncRequest(targetVaultCore, dolomiteIsolationVault, key, isDepositCancel);
        emit UnstuckRequested(key, isDepositCancel, msg.sender);
    }

    // ════════════════════════════════════════════════════════════════════════
    //  PUBLIC VIEW FUNCTIONS
    // ════════════════════════════════════════════════════════════════════════

    function canUnstuckWith(IAsyncRecoveryHandlerVaultCore targetVaultCore, bytes32 key)
        external
        view
        onlyProtocolManagerOrVaultNftOwner(targetVaultCore)
        returns (bool allowed, string memory reasonIfBlocked)
    {
        AsyncRecoveryPendingOperation memory pendingOperation =
            AsyncRecoveryHandlerReaders.resolvePendingOperation(targetVaultCore);

        (allowed, reasonIfBlocked) =
            AsyncRecoveryHandlerRequirements.checkVaultHasPendingAsyncOperation(pendingOperation);
        if (!allowed) return (false, reasonIfBlocked);

        (allowed, reasonIfBlocked) = AsyncRecoveryHandlerRequirements.checkUnstuckDelayAfterDeadlineHasPassed(
            IBasaltMath(targetVaultCore.basaltMath()), pendingOperation
        );
        if (!allowed) return (false, reasonIfBlocked);

        IDolomiteIsolationVault dolomiteIsolationVault =
            AsyncRecoveryHandlerReaders.readDolomiteIsolationVault(targetVaultCore);
        (allowed, reasonIfBlocked) =
            AsyncRecoveryHandlerRequirements.checkDolomiteIsolationVaultStillFrozen(dolomiteIsolationVault);
        if (!allowed) return (false, reasonIfBlocked);

        bool isDepositCancel = pendingOperation.operation == AsyncRecoveryOperation.Wrap;
        if (!isDepositCancel) {
            address unwrapperTrader = AsyncRecoveryHandlerReaders.readUnwrapperAddress();
            (allowed, reasonIfBlocked) =
                AsyncRecoveryHandlerRequirements.checkUnwrapperTraderConfigured(unwrapperTrader);
            if (!allowed) return (false, reasonIfBlocked);

            IUpgradeableAsyncIsolationModeUnwrapperTrader.WithdrawalInfo memory withdrawalInfo =
                AsyncRecoveryHandlerReaders.readWithdrawalInfo(unwrapperTrader, key);
            (allowed, reasonIfBlocked) = AsyncRecoveryHandlerRequirements.checkWithdrawalAsyncKeyTargetsThisVaultAndAccount(
                withdrawalInfo, dolomiteIsolationVault
            );
            if (!allowed) return (false, reasonIfBlocked);
        } else {
            address wrapperTrader = AsyncRecoveryHandlerReaders.readWrapperAddress();
            (allowed, reasonIfBlocked) = AsyncRecoveryHandlerRequirements.checkWrapperTraderConfigured(wrapperTrader);
            if (!allowed) return (false, reasonIfBlocked);

            IUpgradeableAsyncIsolationModeWrapperTrader.DepositInfo memory depositInfo =
                AsyncRecoveryHandlerReaders.readDepositInfo(wrapperTrader, key);
            (allowed, reasonIfBlocked) = AsyncRecoveryHandlerRequirements.checkDepositAsyncKeyTargetsThisVaultAndAccount(
                depositInfo, dolomiteIsolationVault
            );
            if (!allowed) return (false, reasonIfBlocked);
        }

        return (true, "");
    }

    function nextUnstuckAt(IAsyncRecoveryHandlerVaultCore targetVaultCore)
        external
        view
        onlyProtocolManagerOrVaultNftOwner(targetVaultCore)
        returns (uint256 unstuckNotBefore, uint256 deprecatedSecondReturn)
    {
        AsyncRecoveryPendingOperation memory pendingOperation =
            AsyncRecoveryHandlerReaders.resolvePendingOperation(targetVaultCore);
        if (pendingOperation.operation == AsyncRecoveryOperation.None) return (0, 0);

        unstuckNotBefore = AsyncRecoveryHandlerCalculations.calcUnstuckNotBefore(
            IBasaltMath(targetVaultCore.basaltMath()), pendingOperation
        );
        deprecatedSecondReturn = 0;
    }
}
