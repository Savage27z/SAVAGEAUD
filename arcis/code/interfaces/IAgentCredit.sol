// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IAgentCredit
/// @notice Identity-aware lending for autonomous agents
/// @dev Uses ERC-8004 reputation scores to adjust collateral requirements
interface IAgentCredit {
    struct Loan {
        uint256 id;
        address agent;
        uint256 borrowedAmount;      // USDC borrowed
        uint256 collateralShares;    // raUSDC locked
        uint256 interestRateBps;     // Annual rate in bps
        uint256 accruedInterest;     // Accumulated interest
        uint256 startBlock;          // Block when loan was created
        uint256 lastAccrualBlock;    // Last interest accrual
        bool repaid;
    }

    /// @notice Borrow USDC against raUSDC collateral
    /// @param borrowAmount USDC to borrow
    /// @param collateralShares raUSDC shares to lock as collateral
    /// @return loanId Unique identifier for the loan
    function borrow(uint256 borrowAmount, uint256 collateralShares) external returns (uint256 loanId);

    /// @notice Repay a loan and unlock collateral
    /// @param loanId The loan to repay
    function repay(uint256 loanId) external;

    /// @notice Liquidate an undercollateralized loan
    /// @param loanId The loan to liquidate
    function liquidate(uint256 loanId) external;

    /// @notice Get the required collateral ratio for an agent
    /// @param agent Address with optional ERC-8004 identity
    /// @return ratio Collateral ratio in bps (e.g. 15000 = 150%)
    function getCollateralRatio(address agent) external view returns (uint256 ratio);

    /// @notice Check if a loan is healthy (above liquidation threshold)
    /// @param loanId The loan to check
    /// @return healthy Whether the loan is above liquidation threshold
    /// @return healthFactor Current health factor in WAD (1e18 = 1.0)
    function isHealthy(uint256 loanId) external view returns (bool healthy, uint256 healthFactor);

    event LoanCreated(uint256 indexed loanId, address indexed agent, uint256 borrowed, uint256 collateral);
    event LoanRepaid(uint256 indexed loanId, address indexed agent, uint256 totalRepaid);
    event LoanLiquidated(uint256 indexed loanId, address indexed agent, address indexed liquidator);
    event PoolFunded(address indexed funder, uint256 amount);
    event CollateralRatiosUpdated(uint256[5] ratios);
    event RateDiscountsUpdated(uint256[5] discounts);
    event IdentityRegistryUpdated(address indexed oldRegistry, address indexed newRegistry);
    event Paused(address indexed account);
    event Unpaused(address indexed account);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event BaseRateUpdated(uint256 oldRate, uint256 newRate);
}
