// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @title Roles
/// @notice Access control role identifiers for the protocol
library Roles {
    bytes32 internal constant ROOT_ADMIN_ROLE = keccak256("ROOT_ADMIN_ROLE");
    bytes32 internal constant EXCHANGE_OPERATOR_ROLE = keccak256("EXCHANGE_OPERATOR_ROLE");
    bytes32 internal constant FEE_MANAGER_ROLE = keccak256("FEE_MANAGER_ROLE");
    bytes32 internal constant SEQUENCER_ROLE = keccak256("SEQUENCER_ROLE");
    bytes32 internal constant OBSDNBE_GENERAL_ROLE = keccak256("OBSDNBE_GENERAL_ROLE");
}