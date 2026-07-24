// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IDolomiteIsolationVault} from "../../interfaces/IDolomiteVault.sol";
import {IAsyncRecoveryHandlerVaultCore} from "./AsyncRecoveryHandlerTypes.sol";

library AsyncRecoveryHandlerExecutors {
    // ────────────────────────────────────────────────────────────────────────
    //  ASYNC REQUEST CANCELLATION
    // ────────────────────────────────────────────────────────────────────────

    function cancelAsyncRequest(
        IAsyncRecoveryHandlerVaultCore targetVaultCore,
        IDolomiteIsolationVault dolomiteIsolationVault,
        bytes32 key,
        bool isDepositCancel
    ) internal {
        bytes memory cancelData = isDepositCancel
            ? abi.encodeCall(IDolomiteIsolationVault.cancelDeposit, (key))
            : abi.encodeCall(IDolomiteIsolationVault.cancelWithdrawal, (key));

        callVaultCore(targetVaultCore, address(dolomiteIsolationVault), cancelData, 0);
    }

    // ────────────────────────────────────────────────────────────────────────
    //  VAULT CORE CALL PRIMITIVES
    // ────────────────────────────────────────────────────────────────────────

    function callVaultCore(
        IAsyncRecoveryHandlerVaultCore targetVaultCore,
        address target,
        bytes memory data,
        uint256 value
    ) internal {
        targetVaultCore.universalCall{value: value}(msg.sender, target, data, value, false);
    }
}
