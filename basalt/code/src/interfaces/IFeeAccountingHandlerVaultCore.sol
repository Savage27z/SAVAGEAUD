// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

interface IFeeAccountingHandlerVaultCore {
    function FACTORY() external view returns (address);
    function depositHandler() external view returns (address);
    function withdrawHandler() external view returns (address);
    function managerHandler() external view returns (address);
    function asyncRecoveryHandler() external view returns (address);
    function feeAccountingHandler() external view returns (address);
    function extensionHandler1() external view returns (address);
    function extensionHandler2() external view returns (address);
    function extensionHandler3() external view returns (address);

    function basaltState() external view returns (address);
    function universalCall(address initiator, address target, bytes calldata data, uint256 value, bool useDelegateCall)
        external
        payable
        returns (bytes memory);
}
