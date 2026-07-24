// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

library Math {
    uint128 internal constant X18 = 1e18;
    error InvalidUInt256();
    error InvalidUInt128();
    error InvalidInt256();
    error InvalidInt128();

    function mulX18(int128 x, int128 y) internal pure returns (int128) {
        return safeInt128((int256(x) * y) / int128(X18));
    }
    function mulX18(uint128 x, uint128 y) internal pure returns (uint128) {
        return safeUInt128((uint256(x) * y) / X18);
    }
    function mulDiv(int128 a, int128 b, int128 c) internal pure returns (int128) {
        return safeInt128((int256(a) * int256(b)) / int256(c));
    }
    function abs(int128 n) internal pure returns (uint128) { unchecked { return uint128(n >= 0 ? n : -n); } }
    function unscale(uint256 scaledAmount, address token) internal view returns (uint256) {
        uint8 decimals = IERC20Metadata(token).decimals();
        return _unscale(scaledAmount, decimals);
    }
    function floorAndUnscale(uint256 scaledAmount, address token) internal view returns (uint256 floored, uint256 originalAmount) {
        uint8 decimals = IERC20Metadata(token).decimals();
        originalAmount = _unscale(scaledAmount, decimals);
        floored = _scale(originalAmount, decimals);
    }
    function safeUInt256(int256 n) internal pure returns (uint256) { if (n < 0) revert InvalidUInt256(); return uint256(n); }
    function safeUInt128(int128 n) internal pure returns (uint128) { if (n < 0) revert InvalidUInt128(); return uint128(n); }
    function safeUInt128(uint256 n) internal pure returns (uint128) { if (n > type(uint128).max) revert InvalidUInt128(); return uint128(n); }
    function safeInt256(uint256 n) internal pure returns (int256) { if (n > uint256(type(int256).max)) revert InvalidInt256(); return int256(n); }
    function safeInt128(uint128 n) internal pure returns (int128) { if (n > uint128(type(int128).max)) revert InvalidInt128(); return int128(n); }
    function safeInt128(int256 n) internal pure returns (int128) { if (n > type(int128).max || n < type(int128).min) revert InvalidInt128(); return int128(n); }
    function _scale(uint256 rawAmount, uint8 decimals) internal pure returns (uint256) { return (rawAmount * X18) / 10 ** decimals; }
    function _unscale(uint256 scaledAmount, uint8 decimals) internal pure returns (uint256) { return (scaledAmount * 10 ** decimals) / X18; }
}