// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

interface IGovernance {
    event TimelockSet(address indexed timelock);
    event ParameterProposed(bytes32 indexed key, uint256 value, address indexed target);
    event ParameterCommitted(bytes32 indexed key, uint256 value, address indexed target, uint64 executedAt);

    function setTimelock(address timelock) external;

    function proposeParameter(address target, bytes32 key, uint256 value, bytes calldata callData) external returns (uint256 proposalId);

    function executeParameter(uint256 proposalId) external;
}

