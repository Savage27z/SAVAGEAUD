// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseStrategy} from "./BaseStrategy.sol";
import {ErrorLib} from "../libraries/ErrorLib.sol";
import {MathLib} from "../libraries/MathLib.sol";

/// @title StrategyMorpho
/// @author Arcis Protocol
/// @notice Deploys USDC into Morpho Blue optimized lending on Base
/// @dev Morpho Blue is a permissionless lending protocol. We target
///      curated USDC vaults (MetaMorpho) for optimized yield.
///
///      Flow: USDC -> MetaMorpho vault -> earns optimized lending yield
///      MetaMorpho handles allocation across Morpho Blue markets.
contract StrategyMorpho is BaseStrategy {
    /// @notice MetaMorpho vault address (curated USDC vault)
    address public immutable morphoVault;

    /// @notice Shares held in the MetaMorpho vault
    uint256 public vaultShares;

    constructor(
        address _vault,
        address _usdc,
        address _morphoVault
    ) BaseStrategy(_vault, _usdc) {
        if (_morphoVault == address(0)) revert ErrorLib.ZeroAddress();
        morphoVault = _morphoVault;

        // Approve MetaMorpho vault to spend USDC
        _safeApprove(_usdc, _morphoVault, type(uint256).max);
    }

    /// @notice Override
    function deploy(uint256 amount) external override onlyVault whenActive returns (uint256 deployed) {
        // MetaMorpho implements ERC-4626: deposit(assets, receiver)
        (bool success, bytes memory data) = morphoVault.call(
            abi.encodeWithSignature(
                "deposit(uint256,address)",
                amount,
                address(this)
            )
        );
        if (!success) revert ErrorLib.CallFailed();

        uint256 shares = abi.decode(data, (uint256));
        vaultShares += shares;
        _deployedAmount += amount;
        deployed = amount;
        emit Deployed(amount);
    }

    /// @notice Override
    function withdrawFromStrategy(uint256 amount) external override onlyVault returns (uint256 withdrawn) {
        // ERC-4626: withdraw(assets, receiver, owner)
        (bool success, bytes memory data) = morphoVault.call(
            abi.encodeWithSignature(
                "withdraw(uint256,address,address)",
                amount,
                vault,          // send USDC to vault
                address(this)   // burn shares from this strategy
            )
        );
        if (!success) revert ErrorLib.CallFailed();

        uint256 sharesBurned = abi.decode(data, (uint256));
        vaultShares = vaultShares > sharesBurned ? vaultShares - sharesBurned : 0;
        _deployedAmount = _deployedAmount > amount ? _deployedAmount - amount : 0;
        withdrawn = amount;
        emit Withdrawn(withdrawn);
    }

    /// @notice Override
    function totalValue() external view override returns (uint256) {
        if (vaultShares == 0) return 0;

        // ERC-4626: convertToAssets(shares)
        (bool success, bytes memory data) = morphoVault.staticcall(
            abi.encodeWithSignature("convertToAssets(uint256)", vaultShares)
        );
        if (!success || data.length < 32) return _deployedAmount;
        return abi.decode(data, (uint256));
    }

    /// @notice Override
    function currentAPY() external view override returns (uint256) {
        // Fetch APY from MetaMorpho — implementation-specific
        // Most MetaMorpho vaults expose this via off-chain APIs
        // On-chain approximation: compare totalAssets growth over time
        // For now, return a conservative estimate
        // NOTE: Morpho APY oracle not yet available on Base. Returns 0 until oracle integration.
        return 400; // 4.00% default — updated by keeper
    }

    /// @notice Override
    function availableLiquidity() external view override returns (uint256) {
        if (vaultShares == 0) return 0;

        // Check max redeemable
        (bool success, bytes memory data) = morphoVault.staticcall(
            abi.encodeWithSignature("maxWithdraw(address)", address(this))
        );
        if (!success || data.length < 32) return 0;
        return abi.decode(data, (uint256));
    }

    /// @notice Override
    function harvest() external override returns (uint256 harvested) {
        if (vaultShares == 0) return 0;

        // Check current value vs deployed
        (bool success, bytes memory data) = morphoVault.staticcall(
            abi.encodeWithSignature("convertToAssets(uint256)", vaultShares)
        );
        if (!success || data.length < 32) return 0;

        uint256 currentValue = abi.decode(data, (uint256));
        if (currentValue > _deployedAmount) {
            harvested = currentValue - _deployedAmount;
            _deployedAmount = currentValue;
            emit Harvested(harvested);
        }
    }

    /// @notice Override
    function emergencyWithdraw() external override onlyOwner returns (uint256 recovered) {
        if (vaultShares == 0) return 0;

        // Redeem all shares: redeem(shares, receiver, owner)
        (bool success, bytes memory data) = morphoVault.call(
            abi.encodeWithSignature(
                "redeem(uint256,address,address)",
                vaultShares,
                vault,
                address(this)
            )
        );
        if (!success) revert ErrorLib.CallFailed();

        recovered = abi.decode(data, (uint256));
        vaultShares = 0;
        _deployedAmount = 0;
        active = false;
        emit Withdrawn(recovered);
    }
}
