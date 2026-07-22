// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

/// @title IQuiverStrategy — the vault↔strategy boundary.
/// @notice The vault owns share accounting; the strategy owns position mechanics.
///         This interface is the un-retrofittable part of the protocol: every
///         DEX integration (Uniswap V3, V4, forks) implements it, and the vault
///         never changes. Ownership is expressed in liquidity units — the vault
///         is deliberately price-blind.
interface IQuiverStrategy {
    /// @notice Total liquidity units the strategy holds in the pool position.
    function totalLiquidity() external view returns (uint128);

    /// @notice Pool tokens (sorted, as in the underlying pool).
    function token0() external view returns (address);
    function token1() external view returns (address);

    /// @notice True when the current price sits inside the active range.
    function inRange() external view returns (bool);

    /// @notice True when spot has not diverged from the TWAP beyond the bound.
    function isCalm() external view returns (bool);

    /// @notice Quote the exact token amounts a proportional deposit needs.
    /// @dev Amounts are rounded up by one wei so the pool's own rounding on
    ///      mint can never exceed what the vault pulled.
    function quoteDeposit(uint256 amount0Max, uint256 amount1Max)
        external
        view
        returns (uint256 used0, uint256 used1, uint128 liquidity);

    /// @notice Add `amount0`/`amount1` (already transferred in) to the position.
    /// @dev Vault-only. Returns the liquidity actually minted.
    function invest(uint256 amount0, uint256 amount1) external returns (uint128 liquidityAdded);

    /// @notice Pay out `shares / totalShares` of everything (position + idle),
    ///         in kind, to `receiver`. Works in every vault state — this is the
    ///         exit that can never break.
    /// @dev Vault-only. Burns principal only; pending fees stay for harvest.
    function divest(uint256 shares, uint256 totalShares, address receiver)
        external
        returns (uint256 out0, uint256 out1);

    /// @notice Collect fees, take the performance fee, compound the rest.
    /// @dev Permissionless; `callFeeRecipient` earns the caller share.
    function harvest(address callFeeRecipient) external;

    /// @notice Move the position to a new range. Keeper-only within rails
    ///         (cooldown, calm period, width bounds); permissionless as a
    ///         fallback after the position has been out of range too long.
    function rebalance(int24 newTickLower, int24 newTickUpper) external;

    /// @notice Evacuate: burn all liquidity, collect, hold both tokens raw.
    /// @dev Vault-only. Performs zero swaps and zero oracle reads.
    function emergencyExit() external;

    /// @notice Re-enter the position with idle balances after an emergency.
    /// @dev Vault-only.
    function reinvestIdle() external;

    /// @notice Exit the position and sweep all tokens to the successor strategy.
    /// @dev Vault-only; used by the timelocked strategy swap.
    function retireTo(address newStrategy) external;
}
