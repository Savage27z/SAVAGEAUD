// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IVaultCoreNftFactory} from "../../interfaces/IVaultCoreNftFactory.sol";
import {NotManager, NotHandler, NotNftOwner, NotManagerOrNftOwner} from "./VaultCoreTypes.sol";

library VaultCoreRequirements {
    function requireProtocolManager(address factory) internal view {
        if (msg.sender != IVaultCoreNftFactory(factory).protocolManager()) revert NotManager();
    }

    function requireNftOwner(address factory, address vaultCore) internal view {
        if (msg.sender != IVaultCoreNftFactory(factory).ownerOfVault(vaultCore)) revert NotNftOwner();
    }

    function requireProtocolManagerOrVaultNftOwner(address factory, address vaultCore) internal view {
        IVaultCoreNftFactory f = IVaultCoreNftFactory(factory);
        if (msg.sender == f.protocolManager()) return;
        if (msg.sender != f.ownerOfVault(vaultCore)) revert NotManagerOrNftOwner();
    }
}
