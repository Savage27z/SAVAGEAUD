// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title Arcis Protocol Error Definitions
/// @notice All custom errors used across the protocol
library ErrorLib {
    // ── Vault ──
    error ZeroAmount();
    error ZeroAddress();
    error ZeroShares();
    error InsufficientShares(uint256 requested, uint256 available);
    error InsufficientLiquidity(uint256 requested, uint256 available);
    error VaultCapExceeded(uint256 depositAmount, uint256 remaining);
    error VaultPaused();
    error DepositTooSmall(uint256 amount, uint256 minimum);

    // ── Strategy ──
    error InvalidAllocation();
    error AllocationSumMismatch(uint256 sum);
    error StrategyNotRegistered(address strategy);
    error StrategyAlreadyRegistered(address strategy);
    error TimelockNotExpired(uint256 executeAfter);
    error NoRebalanceNeeded();

    // ── Credit ──
    error NoIdentity(address agent);
    error InsufficientCollateral(uint256 required, uint256 provided);
    error LoanNotFound(uint256 loanId);
    error LoanAlreadyRepaid(uint256 loanId);
    error NotLoanOwner(uint256 loanId, address caller);
    error LoanHealthy(uint256 loanId);

    // ── Bonds ──
    error BondNotActive(uint256 bondId);
    error BondMatured(uint256 bondId);
    error BondNotMatured(uint256 bondId);
    error InsufficientRevenue(uint256 required, uint256 available);
    error AgentNotVerified(address agent);

    // ── Access ──
    error Unauthorized(address caller);
    error OnlyRouter();
    error CallFailed();
    error TransferFailed();
    error ApprovalFailed();
}
