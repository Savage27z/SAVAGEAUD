// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IBasaltMath} from "../../interfaces/IBasaltMath.sol";
import {BasaltConstants} from "../../libraries/BasaltConstants.sol";
import {IDolomiteIsolationVault} from "../../interfaces/IDolomiteVault.sol";
import {
    IUpgradeableAsyncIsolationModeUnwrapperTrader,
    IUpgradeableAsyncIsolationModeWrapperTrader
} from "../../interfaces/IDolomiteAsyncTraders.sol";
import {
    AsyncRecoveryOperation,
    AsyncRecoveryPendingOperation,
    IAsyncRecoveryHandlerVaultCore,
    IAsyncRecoveryHandlerVaultCoreNftFactory,
    LiquidationOnlyDolomite,
    NotFrozenAnymore,
    NotOurKey,
    NotVaultNftOwner,
    NotManagerOrNftOwner,
    NothingPending,
    TooEarly,
    UnwrapperNotRegistered,
    WrapperNotRegistered,
    WrongAccount,
    ZeroAddress
} from "./AsyncRecoveryHandlerTypes.sol";
import {AsyncRecoveryHandlerCalculations} from "./AsyncRecoveryHandlerCalculations.sol";

library AsyncRecoveryHandlerRequirements {
    // ────────────────────────────────────────────────────────────────────────
    //  ACCESS
    // ────────────────────────────────────────────────────────────────────────

    function requireVaultNftOwner(IAsyncRecoveryHandlerVaultCore targetVaultCore) internal view {
        if (address(targetVaultCore) == address(0)) revert ZeroAddress();

        address vaultNftOwner =
            IAsyncRecoveryHandlerVaultCoreNftFactory(targetVaultCore.FACTORY()).ownerOfVault(address(targetVaultCore));
        if (msg.sender != vaultNftOwner) revert NotVaultNftOwner();
    }

    function requireCallerIsProtocolManagerOrVaultNftOwner(IAsyncRecoveryHandlerVaultCore targetVaultCore)
        internal
        view
    {
        if (address(targetVaultCore) == address(0)) revert ZeroAddress();
        IAsyncRecoveryHandlerVaultCoreNftFactory factory =
            IAsyncRecoveryHandlerVaultCoreNftFactory(targetVaultCore.FACTORY());
        if (msg.sender == factory.protocolManager()) return;
        address vaultNftOwner = factory.ownerOfVault(address(targetVaultCore));
        if (msg.sender != vaultNftOwner) revert NotManagerOrNftOwner();
    }

    // ────────────────────────────────────────────────────────────────────────
    //  PENDING ASYNC
    // ────────────────────────────────────────────────────────────────────────

    function requireVaultHasPendingAsyncOperation(AsyncRecoveryPendingOperation memory pendingOperation) internal pure {
        if (pendingOperation.operation == AsyncRecoveryOperation.None) revert NothingPending();
    }

    // ────────────────────────────────────────────────────────────────────────
    //  TIME
    // ────────────────────────────────────────────────────────────────────────

    function requireUnstuckDelayAfterDeadlineHasPassed(
        IBasaltMath basaltMath,
        AsyncRecoveryPendingOperation memory pendingOperation
    ) internal view {
        uint256 unstuckNotBefore = AsyncRecoveryHandlerCalculations.calcUnstuckNotBefore(basaltMath, pendingOperation);
        if (block.timestamp < unstuckNotBefore) {
            revert TooEarly(unstuckNotBefore);
        }
    }

    function requireUnstuckAllowedForWrite(
        IAsyncRecoveryHandlerVaultCore targetVaultCore,
        AsyncRecoveryPendingOperation memory pendingOperation
    ) internal view {
        requireUnstuckDelayAfterDeadlineHasPassed(IBasaltMath(targetVaultCore.basaltMath()), pendingOperation);
    }

    // ────────────────────────────────────────────────────────────────────────
    //  DOLOMITE FROZEN GATE
    // ────────────────────────────────────────────────────────────────────────

    function requireDolomiteIsolationVaultStillFrozen(IDolomiteIsolationVault dolomiteIsolationVault) internal view {
        if (!dolomiteIsolationVault.isVaultFrozen()) revert NotFrozenAnymore();
    }

    // ────────────────────────────────────────────────────────────────────────
    //  TRADER REGISTRY
    // ────────────────────────────────────────────────────────────────────────

    function requireUnwrapperTraderConfigured(address unwrapperTrader) internal pure {
        if (unwrapperTrader == address(0)) revert UnwrapperNotRegistered();
    }

    function requireWrapperTraderConfigured(address wrapperTrader) internal pure {
        if (wrapperTrader == address(0)) revert WrapperNotRegistered();
    }

    // ────────────────────────────────────────────────────────────────────────
    //  DOLOMITE REQUEST KEY
    // ────────────────────────────────────────────────────────────────────────

    function requireDepositAsyncKeyTargetsThisVaultAndAccount(
        IUpgradeableAsyncIsolationModeWrapperTrader.DepositInfo memory depositInfo,
        IDolomiteIsolationVault dolomiteIsolationVault
    ) internal pure {
        if (depositInfo.vault != address(dolomiteIsolationVault)) revert NotOurKey();
        if (depositInfo.accountNumber != BasaltConstants.DOLOMITE_ISOLATION_ACCOUNT) revert WrongAccount();
    }

    function requireWithdrawalAsyncKeyTargetsThisVaultAndAccount(
        IUpgradeableAsyncIsolationModeUnwrapperTrader.WithdrawalInfo memory withdrawalInfo,
        IDolomiteIsolationVault dolomiteIsolationVault
    ) internal pure {
        if (withdrawalInfo.vault != address(dolomiteIsolationVault)) revert NotOurKey();
        if (withdrawalInfo.accountNumber != BasaltConstants.DOLOMITE_ISOLATION_ACCOUNT) revert WrongAccount();
        if (withdrawalInfo.isLiquidation) revert LiquidationOnlyDolomite();
    }

    // ════════════════════════════════════════════════════════════════════════
    //  VIEW HELPERS
    // ════════════════════════════════════════════════════════════════════════

    function checkVaultHasPendingAsyncOperation(AsyncRecoveryPendingOperation memory pendingOperation)
        internal
        pure
        returns (bool allowed, string memory reasonIfBlocked)
    {
        if (pendingOperation.operation == AsyncRecoveryOperation.None) {
            return (false, "Blocked: vault has no pending async wrap or unwrap to cancel");
        }
        return (true, "");
    }

    function checkUnstuckDelayAfterDeadlineHasPassed(
        IBasaltMath basaltMath,
        AsyncRecoveryPendingOperation memory pendingOperation
    ) internal view returns (bool allowed, string memory reasonIfBlocked) {
        uint256 unstuckNotBefore = AsyncRecoveryHandlerCalculations.calcUnstuckNotBefore(basaltMath, pendingOperation);
        if (block.timestamp < unstuckNotBefore) {
            return (
                false,
                "Blocked: async deadline plus UNSTUCK_GRACE_AFTER_DEADLINE has not passed (TooEarly on-chain)"
            );
        }
        return (true, "");
    }

    function checkDolomiteIsolationVaultStillFrozen(IDolomiteIsolationVault dolomiteIsolationVault)
        internal
        view
        returns (bool allowed, string memory reasonIfBlocked)
    {
        if (!dolomiteIsolationVault.isVaultFrozen()) {
            return (
                false,
                "Blocked: Dolomite isolation vault is not frozen (async cancel only while Dolomite marks vault frozen)"
            );
        }
        return (true, "");
    }

    function checkUnwrapperTraderConfigured(address unwrapperTrader)
        internal
        pure
        returns (bool allowed, string memory reasonIfBlocked)
    {
        if (unwrapperTrader == address(0)) {
            return (false, "Blocked: GMX/Dolomite unwrapper trader is not registered for this vault factory token");
        }
        return (true, "");
    }

    function checkWrapperTraderConfigured(address wrapperTrader)
        internal
        pure
        returns (bool allowed, string memory reasonIfBlocked)
    {
        if (wrapperTrader == address(0)) {
            return (false, "Blocked: GMX/Dolomite wrapper trader is not registered for this vault factory token");
        }
        return (true, "");
    }

    function checkWithdrawalAsyncKeyTargetsThisVaultAndAccount(
        IUpgradeableAsyncIsolationModeUnwrapperTrader.WithdrawalInfo memory withdrawalInfo,
        IDolomiteIsolationVault dolomiteIsolationVault
    ) internal pure returns (bool allowed, string memory reasonIfBlocked) {
        if (withdrawalInfo.vault != address(dolomiteIsolationVault)) {
            return (false, "Blocked: withdrawal key does not reference this vault's Dolomite isolation vault");
        }
        if (withdrawalInfo.accountNumber != BasaltConstants.DOLOMITE_ISOLATION_ACCOUNT) {
            return (false, "Blocked: withdrawal key account number is not the protocol isolation account");
        }
        if (withdrawalInfo.isLiquidation) {
            return (false, "Blocked: Dolomite marks this withdrawal as liquidation-only; Basalt cannot cancel it here");
        }
        return (true, "");
    }

    function checkDepositAsyncKeyTargetsThisVaultAndAccount(
        IUpgradeableAsyncIsolationModeWrapperTrader.DepositInfo memory depositInfo,
        IDolomiteIsolationVault dolomiteIsolationVault
    ) internal pure returns (bool allowed, string memory reasonIfBlocked) {
        if (depositInfo.vault != address(dolomiteIsolationVault)) {
            return (false, "Blocked: deposit key does not reference this vault's Dolomite isolation vault");
        }
        if (depositInfo.accountNumber != BasaltConstants.DOLOMITE_ISOLATION_ACCOUNT) {
            return (false, "Blocked: deposit key account number is not the protocol isolation account");
        }
        return (true, "");
    }
}
