// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IAgentTreasury — Agent Treasury Interface v1.1
/// @author Arcis Protocol (arcis.money)
/// @notice The ATI standard. Three core functions. Two discovery views.
/// @dev Compliant vaults MUST implement deposit, withdraw, balance, asset, totalAssets.
///      Designed for autonomous AI agents to manage treasury capital.
///      No UI required. No human approval flows. Pure contract interaction.
///
///      Changelog v1.1:
///      - Added asset() for token discovery (agents need to know what to approve)
///      - Added totalAssets() for vault health assessment
///      - Added maxDeposit() for cap-aware deposits
///      - Added ATI_VERSION constant for interface versioning
///      - Standardized event parameter order: (agent, assets, shares) for both events
///      - Added ERC-165 interface ID: 0x7a5b2d14
interface IAgentTreasury {

    // ── Core Operations ──

    /// @notice Deposit the underlying asset into the vault
    /// @param amount The amount of the underlying asset to deposit
    /// @return shares The number of vault shares minted to the caller
    /// @dev MUST revert if amount is 0 or below minimum
    /// @dev MUST revert if vault deposit cap is reached
    /// @dev Caller MUST have approved the vault to spend `amount` of asset()
    /// @dev MUST emit Deposit(agent, amount, shares)
    function deposit(uint256 amount) external returns (uint256 shares);

    /// @notice Withdraw the underlying asset by redeeming vault shares
    /// @param shares The number of vault shares to redeem
    /// @return amount The amount of the underlying asset returned (principal + yield)
    /// @dev MUST revert if shares exceeds caller balance
    /// @dev MUST revert if vault has insufficient liquidity
    /// @dev MUST emit Withdraw(agent, amount, shares)
    function withdraw(uint256 shares) external returns (uint256 amount);

    /// @notice Query the current value of an agent's position in the underlying asset
    /// @param agent The address of the agent (or any holder)
    /// @return The current value including accrued yield
    /// @dev MUST NOT revert for any valid address
    /// @dev MUST return 0 for addresses with no position
    function balance(address agent) external view returns (uint256);

    // ── Discovery Views ──

    /// @notice The address of the underlying asset token (e.g. USDC)
    /// @dev MUST return a valid ERC-20 address
    /// @dev Agents call this to discover what token to approve before depositing
    function asset() external view returns (address);

    /// @notice Total value of all assets under management
    /// @dev MUST return the total value denominated in the underlying asset
    /// @dev Agents use this to assess vault health and relative position size
    function totalAssets() external view returns (uint256);

    /// @notice Maximum amount that can be deposited by a given agent
    /// @param agent The address that would deposit
    /// @return The maximum deposit amount (0 if vault is full or paused)
    /// @dev Agents call this before depositing to avoid reverts
    function maxDeposit(address agent) external view returns (uint256);

    // ── Events ──
    // Parameter order standardized: (agent, assets, shares) for both events

    /// @notice Emitted when an agent deposits the underlying asset
    event Deposit(address indexed agent, uint256 amount, uint256 shares);

    /// @notice Emitted when an agent withdraws the underlying asset
    event Withdraw(address indexed agent, uint256 amount, uint256 shares);
}
