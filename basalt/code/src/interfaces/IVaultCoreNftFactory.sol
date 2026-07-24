// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

interface IVaultCoreNftFactory {
    function owner() external view returns (address);
    function ownerOfVault(address vaultCore) external view returns (address owner);
    function protocolManager() external view returns (address);
}
