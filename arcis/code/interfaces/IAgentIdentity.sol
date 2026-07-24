// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IAgentIdentity
/// @notice ERC-8004 compliant identity registry for AI agents
/// @dev Read-only interface. The registry itself is a separate deployment
///      that tracks agent reputation scores (0-100) based on on-chain history.
///      Arcis contracts use this to determine collateral ratios and bond eligibility.
interface IAgentIdentity {
    /// @notice Get the reputation score of an agent
    /// @param agent Address of the agent wallet
    /// @return score Reputation score from 0 to 100
    function getScore(address agent) external view returns (uint256 score);

    /// @notice Check if an agent has a registered identity
    /// @param agent Address of the agent wallet
    /// @return Whether the agent has any identity record
    function hasIdentity(address agent) external view returns (bool);

    /// @notice Get the total transaction count for an agent
    /// @param agent Address of the agent wallet
    /// @return count Number of on-chain transactions tracked
    function transactionCount(address agent) external view returns (uint256 count);

    /// @notice Get the age of the agent identity (blocks since registration)
    /// @param agent Address of the agent wallet
    /// @return age Number of blocks since identity was created
    function identityAge(address agent) external view returns (uint256 age);

    /// @notice Emitted when a new identity is registered
    event IdentityRegistered(address indexed agent, uint256 initialScore);

    /// @notice Emitted when a score is updated
    event ScoreUpdated(address indexed agent, uint256 oldScore, uint256 newScore);
}
