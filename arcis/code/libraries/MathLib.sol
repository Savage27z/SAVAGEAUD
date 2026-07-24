// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title Arcis Math Library
/// @notice Fixed-point math utilities for share/asset conversions
library MathLib {
    uint256 internal constant WAD = 1e18;

    error DivisionByZero();
    error Overflow();

    /// @notice Multiply then divide with full precision
    function mulDiv(uint256 x, uint256 y, uint256 z) internal pure returns (uint256 result) {
        if (z == 0) revert DivisionByZero();
        result = (x * y) / z;
    }

    /// @notice Multiply then divide, rounding up
    function mulDivUp(uint256 x, uint256 y, uint256 z) internal pure returns (uint256) {
        uint256 result = mulDiv(x, y, z);
        if (mulmod(x, y, z) > 0) {
            if (result == type(uint256).max) revert Overflow();
            result++;
        }
        return result;
    }

    /// @notice Convert assets to shares: shares = assets * totalShares / totalAssets
    /// @dev Uses virtual shares/assets to prevent inflation attacks
    function toShares(
        uint256 assets,
        uint256 totalShares,
        uint256 totalAssets,
        bool roundUp
    ) internal pure returns (uint256) {
        uint256 virtualShares = totalShares + 1;
        uint256 virtualAssets = totalAssets + 1e6;
        if (roundUp) return mulDivUp(assets, virtualShares, virtualAssets);
        return mulDiv(assets, virtualShares, virtualAssets);
    }

    /// @notice Convert shares to assets: assets = shares * totalAssets / totalShares
    function toAssets(
        uint256 shares,
        uint256 totalShares,
        uint256 totalAssets,
        bool roundUp
    ) internal pure returns (uint256) {
        uint256 virtualShares = totalShares + 1;
        uint256 virtualAssets = totalAssets + 1e6;
        if (roundUp) return mulDivUp(shares, virtualAssets, virtualShares);
        return mulDiv(shares, virtualAssets, virtualShares);
    }

    /// @notice Basis points calculation: amount * bps / 10000
    function bps(uint256 amount, uint256 basisPoints) internal pure returns (uint256) {
        return mulDiv(amount, basisPoints, 10_000);
    }

    function min(uint256 a, uint256 b) internal pure returns (uint256) { return a < b ? a : b; }
    function max(uint256 a, uint256 b) internal pure returns (uint256) { return a > b ? a : b; }
    function absDiff(uint256 a, uint256 b) internal pure returns (uint256) { return a > b ? a - b : b - a; }
}
