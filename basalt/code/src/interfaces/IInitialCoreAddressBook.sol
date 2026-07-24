// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

interface IInitialCoreAddressBook {
    function vaultCore() external view returns (address);
    function depositHandler() external view returns (address);
    function withdrawHandler() external view returns (address);
    function managerHandler() external view returns (address);
    function asyncRecoveryHandler() external view returns (address);
    function feeAccountingHandler() external view returns (address);
    function extensionHandler1() external view returns (address);
    function extensionHandler2() external view returns (address);
    function extensionHandler3() external view returns (address);
    function basaltState() external view returns (address);
    function basaltMath() external view returns (address);
    function dolomiteVault() external view returns (address);
}
