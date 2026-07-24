// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

interface IVaultFactory {
    function executionFee() external view returns (uint256);
    function createVault(address account) external returns (address);
    function getVaultByAccount(address account) external view returns (address);
}

interface IDepositHandlerVaultCore {
    function FACTORY() external view returns (address);
    function basaltMath() external view returns (address);
    function basaltState() external view returns (address);
    function feeAccountingHandler() external view returns (address);
    function universalCall(address initiator, address target, bytes calldata data, uint256 value, bool useDelegateCall)
        external
        payable
        returns (bytes memory);
}
