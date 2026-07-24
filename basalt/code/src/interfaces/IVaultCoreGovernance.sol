// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

interface IVaultCoreGovernance {
    function proposeHandler(address oldHandler, address newHandler) external;

    function cancelHandlerProposal() external;

    function proposeBasaltAddresses(address newBasaltMath, address newBasaltState) external;

    function cancelBasaltAddressesProposal() external;
}
