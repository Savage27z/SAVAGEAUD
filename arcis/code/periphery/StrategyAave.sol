// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseStrategy} from "./BaseStrategy.sol";
import {ErrorLib} from "../libraries/ErrorLib.sol";

/// @title StrategyAave
/// @author Arcis Protocol
/// @notice Deploys USDC into Aave V3 lending pool on Base
/// @dev Deposits USDC -> receives aUSDC -> earns supply APY.
///      On withdrawal, redeems aUSDC for USDC + accrued interest.
///
///      Aave V3 Base addresses (verify before mainnet deploy):
///      - Pool: 0xA238Dd80C259a72e81d7e4664a9801593F98d1c5
///      - aUSDC: set in constructor
contract StrategyAave is BaseStrategy {
    /// @notice Aave V3 Pool (IPool interface)
    address public immutable aavePool;

    /// @notice aUSDC token (interest-bearing USDC receipt)
    address public immutable aToken;

    constructor(
        address _vault,
        address _usdc,
        address _aavePool,
        address _aToken
    ) BaseStrategy(_vault, _usdc) {
        if (_aavePool == address(0) || _aToken == address(0)) revert ErrorLib.ZeroAddress();
        aavePool = _aavePool;
        aToken = _aToken;

        // Approve Aave Pool to spend USDC
        _safeApprove(_usdc, _aavePool, type(uint256).max);
    }

    /// @notice Override
    function deploy(uint256 amount) external override onlyVault whenActive returns (uint256 deployed) {
        // Aave V3 Pool.supply(asset, amount, onBehalfOf, referralCode)
        (bool success,) = aavePool.call(
            abi.encodeWithSignature(
                "supply(address,uint256,address,uint16)",
                usdc,
                amount,
                address(this), // aUSDC minted to this strategy
                0              // no referral
            )
        );
        if (!success) revert ErrorLib.CallFailed();

        _deployedAmount += amount;
        deployed = amount;
        emit Deployed(amount);
    }

    /// @notice Override
    function withdrawFromStrategy(uint256 amount) external override onlyVault returns (uint256 withdrawn) {
        // Aave V3 Pool.withdraw(asset, amount, to)
        (bool success, bytes memory data) = aavePool.call(
            abi.encodeWithSignature(
                "withdraw(address,uint256,address)",
                usdc,
                amount,
                vault // send USDC directly to vault
            )
        );
        if (!success) revert ErrorLib.CallFailed();

        withdrawn = abi.decode(data, (uint256));
        _deployedAmount = _deployedAmount > withdrawn ? _deployedAmount - withdrawn : 0;
        emit Withdrawn(withdrawn);
    }

    /// @notice Override
    function totalValue() external view override returns (uint256) {
        // aToken balance = principal + accrued interest
        return _balanceOf(aToken, address(this));
    }

    /// @notice Override
    function currentAPY() external view override returns (uint256) {
        // Fetch current liquidity rate from Aave
        // Pool.getReserveData(asset) returns ReserveData struct
        // liquidityRate is at a specific offset, in RAY (1e27)
        (bool success, bytes memory data) = aavePool.staticcall(
            abi.encodeWithSignature("getReserveData(address)", usdc)
        );

        if (!success || data.length < 64) return 0;

        // liquidityRate is the second uint256 in the struct (index 1)
        // Convert from RAY (1e27) to BPS
        uint256 liquidityRate;
        assembly {
            liquidityRate := mload(add(data, 64))
        }

        // RAY to BPS: rate * 10000 / 1e27
        return liquidityRate / 1e23;
    }

    /// @notice Override
    function availableLiquidity() external view override returns (uint256) {
        return _balanceOf(aToken, address(this));
    }

    /// @notice Override
    function harvest() external override returns (uint256 harvested) {
        // Aave auto-compounds via aToken rebasing
        // Just update deployed amount to reflect new total
        uint256 currentValue = _balanceOf(aToken, address(this));
        if (currentValue > _deployedAmount) {
            harvested = currentValue - _deployedAmount;
            _deployedAmount = currentValue;
            emit Harvested(harvested);
        }
    }

    /// @notice Override
    function emergencyWithdraw() external override onlyOwner returns (uint256 recovered) {
        uint256 balance = _balanceOf(aToken, address(this));
        if (balance == 0) return 0;

        (bool success, bytes memory data) = aavePool.call(
            abi.encodeWithSignature(
                "withdraw(address,uint256,address)",
                usdc,
                type(uint256).max, // withdraw all
                vault
            )
        );
        if (!success) revert ErrorLib.CallFailed();

        recovered = abi.decode(data, (uint256));
        _deployedAmount = 0;
        active = false;
        emit Withdrawn(recovered);
    }
}
