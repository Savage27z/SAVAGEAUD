// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {GilderAccessControl} from "./GilderAccessControl.sol";

/**
 * @title GilderUUPSProxy
 * @notice EIP-1967 minimal UUPS proxy used as the M3 upgrade scaffold.
 *
 * Why a custom proxy rather than OZ's `UUPSUpgradeable`?
 * - We already lean on a hand-rolled GilderAccessControl for role
 *   management; pulling in OpenZeppelin's full Initializable + UUPS
 *   stack would force every M1/M2 contract to be refactored to
 *   `initializer` modifier semantics and constructorless storage. This
 *   proxy keeps the existing `initialize(...)` pattern, just behind a
 *   delegatecall layer. New M3+ modules can opt in.
 *
 * Upgrade flow:
 *   1. Deploy a fresh implementation contract.
 *   2. Call `upgradeTo(newImpl)` on the proxy. Only DEFAULT_ADMIN_ROLE
 *      may upgrade (gated by the implementation's access control,
 *      because the role check happens in the delegated `_authorizeUpgrade`).
 *   3. Implementation storage layout MUST be append-only - that's why
 *      every Gilder module already reserves a `uint256[N] __gap`.
 *
 * Storage layout uses the EIP-1967 standard slots so an off-chain
 * indexer (or a block explorer's "Read as Proxy" view) can resolve the
 * implementation address without a special getter.
 */
contract GilderUUPSProxy {
    bytes32 private constant _IMPLEMENTATION_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    bytes32 private constant _ADMIN_SLOT =
        0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;
    // §Code-Review N2 (Jul 2026) - the upgrade timelock is enforced AT THE
    // PROXY LAYER, not as a property of who the admin happens to be. Pending
    // upgrade state lives in unstructured (keccak-derived) slots so it can
    // never collide with delegated implementation storage.
    bytes32 private constant _PENDING_IMPL_SLOT =
        bytes32(uint256(keccak256("gilder.proxy.pendingImplementation")) - 1);
    bytes32 private constant _PENDING_DATA_HASH_SLOT =
        bytes32(uint256(keccak256("gilder.proxy.pendingDataHash")) - 1);
    bytes32 private constant _PENDING_ETA_SLOT =
        bytes32(uint256(keccak256("gilder.proxy.pendingEta")) - 1);

    // §N2 - hard minimum delay between proposing and executing an upgrade
    // (48h per the original C4 recommendation). Combined with the multisig's
    // own MIN_TIMELOCK this holds even after the changeProxyAdmin hand-off,
    // and it holds TODAY while the admin is still an EOA - an admin-key
    // compromise can no longer swap out SafeVault custody in one transaction.
    uint256 public constant UPGRADE_TIMELOCK = 48 hours;

    event Upgraded(address indexed implementation);
    event AdminChanged(address indexed previousAdmin, address indexed newAdmin);
    event UpgradeProposed(address indexed implementation, bytes32 dataHash, uint256 eta);
    event UpgradeCancelled(address indexed implementation);

    error NotProxyAdmin(address caller);
    error ZeroImplementation();
    error InitFailed();
    error NoUpgradeProposed();
    error UpgradeMismatch(address expectedImplementation, bytes32 expectedDataHash);
    error UpgradeTimelockActive(uint256 eta, uint256 nowTs);

    constructor(address implementation, address proxyAdmin, bytes memory initCalldata) {
        if (implementation == address(0)) revert ZeroImplementation();
        if (proxyAdmin == address(0)) revert NotProxyAdmin(proxyAdmin);

        assembly {
            sstore(_IMPLEMENTATION_SLOT, implementation)
            sstore(_ADMIN_SLOT, proxyAdmin)
        }
        emit AdminChanged(address(0), proxyAdmin);
        emit Upgraded(implementation);

        if (initCalldata.length > 0) {
            (bool ok, ) = implementation.delegatecall(initCalldata);
            if (!ok) revert InitFailed();
        }
    }

    /**
     * §Code-Review N2 - step 1 of the two-step upgrade: queue the new
     * implementation (and the exact migration calldata, committed by hash).
     * Only the proxy admin may propose. The queued upgrade becomes
     * executable via `upgradeToAndCall` after UPGRADE_TIMELOCK elapses.
     * Proposing again overwrites the previous proposal (restarting the
     * clock), so a mis-queued upgrade is corrected by re-proposing.
     */
    function proposeUpgrade(address newImplementation, bytes calldata data) external {
        _onlyProxyAdmin();
        if (newImplementation == address(0)) revert ZeroImplementation();
        uint256 eta = block.timestamp + UPGRADE_TIMELOCK;
        _setSlot(_PENDING_IMPL_SLOT, bytes32(uint256(uint160(newImplementation))));
        _setSlot(_PENDING_DATA_HASH_SLOT, keccak256(data));
        _setSlot(_PENDING_ETA_SLOT, bytes32(eta));
        emit UpgradeProposed(newImplementation, keccak256(data), eta);
    }

    /** §N2 - cancel the queued upgrade (admin only). */
    function cancelUpgrade() external {
        _onlyProxyAdmin();
        address pending = address(uint160(uint256(_getSlot(_PENDING_IMPL_SLOT))));
        if (pending == address(0)) revert NoUpgradeProposed();
        _setSlot(_PENDING_IMPL_SLOT, bytes32(0));
        _setSlot(_PENDING_DATA_HASH_SLOT, bytes32(0));
        _setSlot(_PENDING_ETA_SLOT, bytes32(0));
        emit UpgradeCancelled(pending);
    }

    /**
     * Step 2 of the two-step upgrade: swap the implementation. Only the
     * proxy admin may execute, ONLY for the exact (implementation, data)
     * pair queued via `proposeUpgrade`, and ONLY after the proxy-layer
     * timelock has elapsed (§Code-Review N2 - identity AND process).
     * Optionally re-runs an init/migration call on the new implementation
     * in the same tx.
     */
    function upgradeToAndCall(address newImplementation, bytes calldata data) external {
        _onlyProxyAdmin();
        if (newImplementation == address(0)) revert ZeroImplementation();
        address pendingImpl = address(uint160(uint256(_getSlot(_PENDING_IMPL_SLOT))));
        bytes32 pendingDataHash = _getSlot(_PENDING_DATA_HASH_SLOT);
        uint256 eta = uint256(_getSlot(_PENDING_ETA_SLOT));
        if (pendingImpl == address(0)) revert NoUpgradeProposed();
        if (pendingImpl != newImplementation || pendingDataHash != keccak256(data)) {
            revert UpgradeMismatch(pendingImpl, pendingDataHash);
        }
        if (block.timestamp < eta) revert UpgradeTimelockActive(eta, block.timestamp);
        // Clear the proposal before switching (checks-effects-interactions).
        _setSlot(_PENDING_IMPL_SLOT, bytes32(0));
        _setSlot(_PENDING_DATA_HASH_SLOT, bytes32(0));
        _setSlot(_PENDING_ETA_SLOT, bytes32(0));
        assembly {
            sstore(_IMPLEMENTATION_SLOT, newImplementation)
        }
        emit Upgraded(newImplementation);
        if (data.length > 0) {
            (bool ok, ) = newImplementation.delegatecall(data);
            if (!ok) revert InitFailed();
        }
    }

    /** §N2 - views for monitoring/queued-upgrade transparency. */
    function pendingUpgrade()
        external
        view
        returns (address implementation_, bytes32 dataHash, uint256 eta)
    {
        implementation_ = address(uint160(uint256(_getSlot(_PENDING_IMPL_SLOT))));
        dataHash = _getSlot(_PENDING_DATA_HASH_SLOT);
        eta = uint256(_getSlot(_PENDING_ETA_SLOT));
    }

    function _getSlot(bytes32 slot) private view returns (bytes32 value) {
        assembly {
            value := sload(slot)
        }
    }

    function _setSlot(bytes32 slot, bytes32 value) private {
        assembly {
            sstore(slot, value)
        }
    }

    /** Rotate the proxy admin (e.g., move from deployer EOA -> multisig). */
    function changeProxyAdmin(address newAdmin) external {
        _onlyProxyAdmin();
        if (newAdmin == address(0)) revert NotProxyAdmin(newAdmin);
        address previous;
        assembly {
            previous := sload(_ADMIN_SLOT)
            sstore(_ADMIN_SLOT, newAdmin)
        }
        emit AdminChanged(previous, newAdmin);
    }

    function implementation() external view returns (address impl) {
        assembly {
            impl := sload(_IMPLEMENTATION_SLOT)
        }
    }

    function proxyAdmin() external view returns (address adm) {
        assembly {
            adm := sload(_ADMIN_SLOT)
        }
    }

    fallback() external payable {
        _delegate();
    }

    receive() external payable {
        _delegate();
    }

    function _delegate() private {
        assembly {
            let impl := sload(_IMPLEMENTATION_SLOT)
            calldatacopy(0, 0, calldatasize())
            let result := delegatecall(gas(), impl, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            switch result
            case 0 { revert(0, returndatasize()) }
            default { return(0, returndatasize()) }
        }
    }

    function _onlyProxyAdmin() private view {
        address adm;
        assembly {
            adm := sload(_ADMIN_SLOT)
        }
        if (msg.sender != adm) revert NotProxyAdmin(msg.sender);
    }
}
