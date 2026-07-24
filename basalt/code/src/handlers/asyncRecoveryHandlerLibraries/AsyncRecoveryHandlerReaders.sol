// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {VaultState} from "../../core/VaultState.sol";
import {BasaltAddresses} from "../../libraries/BasaltAddresses.sol";
import {IDolomiteIsolationVault} from "../../interfaces/IDolomiteVault.sol";
import {
    IUpgradeableAsyncIsolationModeUnwrapperTrader,
    IUpgradeableAsyncIsolationModeWrapperTrader,
    IGmxV2Registry
} from "../../interfaces/IDolomiteAsyncTraders.sol";
import {
    REBALANCE_DIR_DOWN,
    REBALANCE_DIR_UP,
    REBALANCE_KIND_ABSORB_SURPLUS,
    REBALANCE_KIND_LTV
} from "../managerHandlerLibraries/ManagerHandlerTypes.sol";
import {
    AsyncRecoveryOperation,
    AsyncRecoveryPendingOperation,
    IAsyncRecoveryHandlerVaultCore,
    IAsyncRecoveryHandlerVaultCoreNftFactory,
    InvalidRebalanceDirection
} from "./AsyncRecoveryHandlerTypes.sol";

library AsyncRecoveryHandlerReaders {
    // ────────────────────────────────────────────────────────────────────────
    //  EXTERNAL REGISTRY READERS
    // ────────────────────────────────────────────────────────────────────────

    function readWrapperAddress() internal view returns (address) {
        return IGmxV2Registry(BasaltAddresses.GMX_V2_REGISTRY).getWrapperByToken(BasaltAddresses.VAULT_FACTORY);
    }

    function readUnwrapperAddress() internal view returns (address) {
        return IGmxV2Registry(BasaltAddresses.GMX_V2_REGISTRY).getUnwrapperByToken(BasaltAddresses.VAULT_FACTORY);
    }

    function readDepositInfo(address wrapper, bytes32 key)
        internal
        view
        returns (IUpgradeableAsyncIsolationModeWrapperTrader.DepositInfo memory)
    {
        return IUpgradeableAsyncIsolationModeWrapperTrader(wrapper).getDepositInfo(key);
    }

    function readWithdrawalInfo(address unwrapper, bytes32 key)
        internal
        view
        returns (IUpgradeableAsyncIsolationModeUnwrapperTrader.WithdrawalInfo memory)
    {
        return IUpgradeableAsyncIsolationModeUnwrapperTrader(unwrapper).getWithdrawalInfo(key);
    }

    // ────────────────────────────────────────────────────────────────────────
    //  VAULT READERS
    // ────────────────────────────────────────────────────────────────────────

    function readDolomiteIsolationVault(IAsyncRecoveryHandlerVaultCore targetVaultCore)
        internal
        view
        returns (IDolomiteIsolationVault)
    {
        return IDolomiteIsolationVault(VaultState(targetVaultCore.basaltState()).dolomiteIsolationVault());
    }

    function resolvePendingOperation(IAsyncRecoveryHandlerVaultCore targetVaultCore)
        internal
        view
        returns (AsyncRecoveryPendingOperation memory pendingOperation)
    {
        VaultState vaultState = VaultState(targetVaultCore.basaltState());

        if (vaultState.depositState() == VaultState.State.PENDING) {
            pendingOperation.operation = AsyncRecoveryOperation.Wrap;
            pendingOperation.deadline = vaultState.pendingDepositDeadline();
            pendingOperation.initiator = IAsyncRecoveryHandlerVaultCoreNftFactory(targetVaultCore.FACTORY()).ownerOfVault(
                address(targetVaultCore)
            );
            return pendingOperation;
        }

        if (vaultState.withdrawState() == VaultState.State.PENDING) {
            pendingOperation.operation = AsyncRecoveryOperation.Unwrap;
            pendingOperation.deadline = vaultState.pendingWithdrawDeadline();
            pendingOperation.initiator = vaultState.pendingWithdrawer();
            return pendingOperation;
        }

        if (vaultState.rebalanceState() == VaultState.State.PENDING) {
            pendingOperation.deadline = vaultState.pendingRebalanceDeadline();
            pendingOperation.initiator = vaultState.pendingRebalanceInitiator();

            uint8 kind = vaultState.pendingRebalanceKind();
            uint8 direction = vaultState.pendingRebalanceDirection();

            if (kind == uint8(REBALANCE_KIND_ABSORB_SURPLUS)) {
                pendingOperation.operation = AsyncRecoveryOperation.Wrap;
                return pendingOperation;
            }

            if (kind == uint8(REBALANCE_KIND_LTV)) {
                if (direction == uint8(REBALANCE_DIR_UP)) {
                    pendingOperation.operation = AsyncRecoveryOperation.Wrap;
                    return pendingOperation;
                }

                if (direction == uint8(REBALANCE_DIR_DOWN)) {
                    pendingOperation.operation = AsyncRecoveryOperation.Unwrap;
                    return pendingOperation;
                }
            }

            revert InvalidRebalanceDirection();
        }
    }

}
