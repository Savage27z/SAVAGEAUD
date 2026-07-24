// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IStrategyAdapter
/// @notice Interface for yield source adapters (Aave, Morpho, Ondo, etc.)
/// @dev Each yield source gets its own adapter that implements this interface.
///      The StrategyAllocator routes capital to adapters based on allocation weights.
interface IStrategyAdapter {
    /// @notice Deploy capital into the yield source
    /// @param amount USDC amount to deploy (6 decimals)
    /// @return deployed Actual amount deployed (may differ due to fees)
    function deploy(uint256 amount) external returns (uint256 deployed);

    /// @notice Withdraw capital from the yield source
    /// @param amount USDC amount to withdraw (6 decimals)
    /// @return withdrawn Actual amount withdrawn
    function withdrawFromStrategy(uint256 amount) external returns (uint256 withdrawn);

    /// @notice Total value of assets deployed in this strategy (in USDC)
    /// @return Total USDC value including accrued yield
    function totalValue() external view returns (uint256);

    /// @notice Current APY of this strategy in basis points
    /// @return APY in bps (e.g. 450 = 4.50%)
    function currentAPY() external view returns (uint256);

    /// @notice Maximum amount that can be instantly withdrawn
    /// @return Maximum USDC that can be withdrawn in one tx
    function availableLiquidity() external view returns (uint256);

    /// @notice Whether this strategy is currently active
    function isActive() external view returns (bool);

    /// @notice Harvest any pending yield and reinvest
    /// @return harvested Amount of yield harvested (in USDC)
    function harvest() external returns (uint256 harvested);

    /// @notice Emergency withdraw all funds from the strategy
    /// @return recovered Total USDC recovered
    function emergencyWithdraw() external returns (uint256 recovered);

    /// @notice Emitted when capital is deployed
    event Deployed(uint256 amount);

    /// @notice Emitted when capital is withdrawn
    event Withdrawn(uint256 amount);

    /// @notice Emitted when yield is harvested
    event Harvested(uint256 amount);
}
