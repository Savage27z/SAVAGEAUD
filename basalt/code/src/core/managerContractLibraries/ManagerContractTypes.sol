// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {VaultCoreNftFactory} from "../VaultCoreNftFactory.sol";

struct ProtocolManagerProposal {
    VaultCoreNftFactory factory;
    address nextProtocolManager;
    uint256 snapshot;
    uint256 yesWeight;
    uint256 cancelWeight;
    uint256 createdAt;
    bool executed;
    bool cancelled;
}

error NotPendingRole(address caller, address pendingRole);
error NotFeeCollector();
error NotOperational();
error NotConfigurator();
error NotHandlerProposer();
error NotAddressProposer();
error ZeroFeeSplitter();
error ZeroFactory();
error ZeroProtocolManager();
error ZeroRole();
error SnapshotUnavailable();
error ProposalNotFound();
error ProposalCancelled();
error AlreadySigned();
error AlreadySignedOpposite();
error NoVotingWeight();
error NoPastSupply();
error InsufficientFeeParticipantSupport();
error InsufficientCancelSupport();
error AlreadyExecuted();
error ActiveProposalExists(uint256 activeProposalId);
error NotCurrentProtocolManager();
error NotAuthorisedToFinalizeProposal(address caller);
error NotAuthorisedToCollectFees(address caller);

library ManagerContractTypes {}
