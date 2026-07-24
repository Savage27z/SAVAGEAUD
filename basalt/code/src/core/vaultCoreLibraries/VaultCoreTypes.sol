// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

struct HandlerProposal {
    address oldHandler;
    address newHandler;
    bool exists;
}

struct BasaltAddressesProposal {
    address newBasaltMath;
    address newBasaltState;
    bool exists;
}

error NotManager();
error NotHandler();
error NotNftOwner();
error NotManagerOrNftOwner();
error NoHandlerProposal();
error NoBasaltAddressesProposal();
error UnknownHandler();
error AlreadyInitialized();
error ZeroHandler();
error DuplicateHandler();
error DeadmanAlreadyTriggered();
error DeadmanPeriodNotElapsed(uint256 currentBlock, uint256 unlockAtBlock);

library VaultCoreTypes {}
