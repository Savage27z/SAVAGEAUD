// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

interface IManagerHandlerVaultCore {
    function FACTORY() external view returns (address);
    function basaltState() external view returns (address);
    function basaltMath() external view returns (address);
    function feeAccountingHandler() external view returns (address);

    function universalCall(address initiator, address target, bytes calldata data, uint256 value, bool useDelegateCall)
        external
        payable
        returns (bytes memory);
}
