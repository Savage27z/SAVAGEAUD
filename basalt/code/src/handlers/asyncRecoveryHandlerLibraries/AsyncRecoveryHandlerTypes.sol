// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// ────────────────────────────────────────────────────────────────────────────
//  HANDLER INTERFACES
// ────────────────────────────────────────────────────────────────────────────

interface IAsyncRecoveryHandlerVaultCore {
    function FACTORY() external view returns (address);
    function basaltMath() external view returns (address);
    function basaltState() external view returns (address);
    function universalCall(address initiator, address target, bytes calldata data, uint256 value, bool useDelegateCall)
        external
        payable
        returns (bytes memory result);
}

interface IAsyncRecoveryHandlerVaultCoreNftFactory {
    function ownerOfVault(address vaultCore) external view returns (address owner);
    function protocolManager() external view returns (address);
}

// ────────────────────────────────────────────────────────────────────────────
//  ERRORS
// ────────────────────────────────────────────────────────────────────────────

error ZeroAddress();
error NothingPending();
error TooEarly(uint256 unstuckNotBefore);
error NotFrozenAnymore();
error InvalidRebalanceDirection();
error NotOurKey();
error WrongAccount();
error LiquidationOnlyDolomite();
error UnwrapperNotRegistered();
error WrapperNotRegistered();
error NotVaultNftOwner();
error NotManagerOrNftOwner();

// ────────────────────────────────────────────────────────────────────────────
//  ASYNC RECOVERY TYPES
// ────────────────────────────────────────────────────────────────────────────

enum AsyncRecoveryOperation {
    None,
    Wrap,
    Unwrap
}

struct AsyncRecoveryPendingOperation {
    AsyncRecoveryOperation operation;
    uint256 deadline;
    address initiator;
}
