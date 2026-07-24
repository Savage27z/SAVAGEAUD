// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IStrategyAdapter} from "../interfaces/IStrategyAdapter.sol";
import {ErrorLib} from "../libraries/ErrorLib.sol";

/// @title BaseStrategy
/// @notice Shared logic for all yield strategy adapters
/// @dev Concrete adapters (Aave, Morpho, Ondo) inherit from this.
///      Handles access control, pausing, and safe token transfers.
abstract contract BaseStrategy is IStrategyAdapter {
    address public immutable vault;
    address public immutable usdc;
    address public owner;

    bool public active;
    uint256 internal _deployedAmount;

    modifier onlyVault() {
        if (msg.sender != vault) revert ErrorLib.Unauthorized(msg.sender);
        _;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert ErrorLib.Unauthorized(msg.sender);
        _;
    }

    modifier whenActive() {
        if (!active) revert ErrorLib.StrategyNotRegistered(address(this));
        _;
    }

    constructor(address _vault, address _usdc) {
        if (_vault == address(0) || _usdc == address(0)) revert ErrorLib.ZeroAddress();
        vault = _vault;
        usdc = _usdc;
        owner = msg.sender;
        active = true;
    }

    function isActive() external view override returns (bool) {
        return active;
    }

    function setActive(bool _active) external onlyOwner {
        active = _active;
    }

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ErrorLib.ZeroAddress();
        owner = newOwner;
        // Event omitted — use owner() view to check
    }

    // ── Safe token helpers ──

    function _safeTransfer(address token, address to, uint256 amount) internal {
        (bool success, bytes memory data) = token.call(
            abi.encodeWithSelector(0xa9059cbb, to, amount)
        );
        if (!success || (data.length > 0 && !abi.decode(data, (bool)))) revert ErrorLib.TransferFailed();
    }

    function _safeTransferFrom(address token, address from, address to, uint256 amount) internal {
        (bool success, bytes memory data) = token.call(
            abi.encodeWithSelector(0x23b872dd, from, to, amount)
        );
        if (!success || (data.length > 0 && !abi.decode(data, (bool)))) revert ErrorLib.TransferFailed();
    }

    function _safeApprove(address token, address spender, uint256 amount) internal {
        (bool success, bytes memory data) = token.call(
            abi.encodeWithSelector(0x095ea7b3, spender, amount)
        );
        if (!success || (data.length > 0 && !abi.decode(data, (bool)))) revert ErrorLib.TransferFailed();
    }

    function _balanceOf(address token, address account) internal view returns (uint256) {
        (bool success, bytes memory data) = token.staticcall(
            abi.encodeWithSelector(0x70a08231, account)
        );
        if (!success || data.length < 32) return 0;
        return abi.decode(data, (uint256));
    }
}
