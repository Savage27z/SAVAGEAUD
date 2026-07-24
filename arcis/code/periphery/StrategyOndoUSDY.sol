// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseStrategy} from "./BaseStrategy.sol";
import {ErrorLib} from "../libraries/ErrorLib.sol";
import {MathLib} from "../libraries/MathLib.sol";

/// @title StrategyOndoUSDY
/// @author Arcis Protocol
/// @notice Deploys USDC into Ondo USDY (tokenized US Treasury yield)
/// @dev USDY is a rebasing token backed by US Treasuries and bank deposits.
///      Flow: USDC -> Ondo minting -> USDY (rebasing yield) -> redeem back to USDC
///
///      USDY on Base: verify contract addresses before mainnet deployment.
///      This adapter handles the USDC <-> USDY conversion.
///
///      Note: USDY may have minimum hold periods and KYC requirements.
///      The vault owner is responsible for ensuring the vault address
///      is whitelisted with Ondo if required.
contract StrategyOndoUSDY is BaseStrategy {
    /// @notice USDY token address
    address public immutable usdy;

    /// @notice USDY minting/redemption contract
    address public immutable ondoRouter;

    /// @notice USDY held by this strategy
    uint256 public usdyBalance;

    constructor(
        address _vault,
        address _usdc,
        address _usdy,
        address _ondoRouter
    ) BaseStrategy(_vault, _usdc) {
        if (_usdy == address(0) || _ondoRouter == address(0)) revert ErrorLib.ZeroAddress();
        usdy = _usdy;
        ondoRouter = _ondoRouter;

        // Approve Ondo router to spend USDC for minting
        _safeApprove(_usdc, _ondoRouter, type(uint256).max);
        // Approve Ondo router to spend USDY for redemption
        _safeApprove(_usdy, _ondoRouter, type(uint256).max);
    }

    /// @notice Override
    function deploy(uint256 amount) external override onlyVault whenActive returns (uint256 deployed) {
        // Mint USDY with USDC via Ondo router
        // Interface: mint(uint256 usdcAmount) returns (uint256 usdyMinted)
        uint256 usdyBefore = _balanceOf(usdy, address(this));

        (bool success,) = ondoRouter.call(
            abi.encodeWithSignature("mint(uint256)", amount)
        );
        if (!success) revert ErrorLib.CallFailed();

        uint256 usdyAfter = _balanceOf(usdy, address(this));
        uint256 minted = usdyAfter - usdyBefore;

        usdyBalance += minted;
        _deployedAmount += amount;
        deployed = amount;
        emit Deployed(amount);
    }

    /// @notice Override
    function withdrawFromStrategy(uint256 amount) external override onlyVault returns (uint256 withdrawn) {
        // Convert desired USDC amount to USDY amount needed
        uint256 usdyNeeded = _usdcToUsdy(amount);
        if (usdyNeeded > usdyBalance) usdyNeeded = usdyBalance;

        // Redeem USDY for USDC via Ondo router
        // Interface: redeem(uint256 usdyAmount) returns (uint256 usdcReturned)
        // USDC balance tracked via redeemed amount below

        (bool success,) = ondoRouter.call(
            abi.encodeWithSignature("redeem(uint256)", usdyNeeded)
        );
        if (!success) revert ErrorLib.CallFailed();

        // Transfer redeemed USDC to vault
        uint256 redeemed = _balanceOf(usdc, address(this));
        if (redeemed > 0) {
            _safeTransfer(usdc, vault, redeemed);
        }

        usdyBalance -= usdyNeeded;
        withdrawn = redeemed;
        _deployedAmount = _deployedAmount > withdrawn ? _deployedAmount - withdrawn : 0;
        emit Withdrawn(withdrawn);
    }

    /// @notice Override
    function totalValue() external view override returns (uint256) {
        if (usdyBalance == 0) return 0;
        return _usdyToUsdc(usdyBalance);
    }

    /// @notice Override
    function currentAPY() external view override returns (uint256) {
        // USDY targets ~5% from US Treasury yield
        // Fetch from Ondo oracle if available, otherwise use conservative estimate
        (bool success, bytes memory data) = ondoRouter.staticcall(
            abi.encodeWithSignature("currentYield()")
        );

        if (success && data.length >= 32) {
            return abi.decode(data, (uint256));
        }

        return 475; // 4.75% conservative default
    }

    /// @notice Override
    function availableLiquidity() external view override returns (uint256) {
        // USDY redemption may have delays; check instant availability
        (bool success, bytes memory data) = ondoRouter.staticcall(
            abi.encodeWithSignature("instantRedemptionLimit()")
        );

        if (success && data.length >= 32) {
            uint256 limit = abi.decode(data, (uint256));
            return MathLib.min(limit, _usdyToUsdc(usdyBalance));
        }

        return _usdyToUsdc(usdyBalance);
    }

    /// @notice Override
    function harvest() external override returns (uint256 harvested) {
        // USDY rebases — value increases without balance changing
        // Recalculate total value
        uint256 currentValue = _usdyToUsdc(usdyBalance);
        if (currentValue > _deployedAmount) {
            harvested = currentValue - _deployedAmount;
            _deployedAmount = currentValue;
            emit Harvested(harvested);
        }
    }

    /// @notice Override
    function emergencyWithdraw() external override onlyOwner returns (uint256 recovered) {
        if (usdyBalance == 0) return 0;

        // Try to redeem all USDY
        (bool success,) = ondoRouter.call(
            abi.encodeWithSignature("redeem(uint256)", usdyBalance)
        );

        if (success) {
            recovered = _balanceOf(usdc, address(this));
            if (recovered > 0) {
                _safeTransfer(usdc, vault, recovered);
            }
        } else {
            // If redemption fails, transfer USDY directly to vault for manual handling
            uint256 bal = _balanceOf(usdy, address(this));
            if (bal > 0) {
                _safeTransfer(usdy, vault, bal);
            }
            recovered = 0;
        }

        usdyBalance = 0;
        _deployedAmount = 0;
        active = false;
        emit Withdrawn(recovered);
    }

    // ══════════════════════════════════════════════════════════════
    //                    INTERNAL FUNCTIONS
    // ══════════════════════════════════════════════════════════════

    /// @dev Convert USDY amount to USDC value using oracle price
    function _usdyToUsdc(uint256 usdyAmount) internal view returns (uint256) {
        if (usdyAmount == 0) return 0;

        // USDY price oracle: pricePerShare() returns USDC value per USDY (18 decimals)
        (bool success, bytes memory data) = usdy.staticcall(
            abi.encodeWithSignature("pricePerShare()")
        );

        if (!success || data.length < 32) return usdyAmount; // 1:1 fallback
        uint256 price = abi.decode(data, (uint256));

        // price is 18 decimals, USDY is 18 decimals, USDC is 6 decimals
        return MathLib.mulDiv(usdyAmount, price, 1e30);
    }

    /// @dev Convert USDC amount to USDY amount needed
    function _usdcToUsdy(uint256 usdcAmount) internal view returns (uint256) {
        if (usdcAmount == 0) return 0;

        (bool success, bytes memory data) = usdy.staticcall(
            abi.encodeWithSignature("pricePerShare()")
        );

        if (!success || data.length < 32) return usdcAmount * 1e12; // scale 6->18 fallback
        uint256 price = abi.decode(data, (uint256));

        // Reverse: usdyAmount = usdcAmount * 1e30 / price
        return MathLib.mulDivUp(usdcAmount, 1e30, price);
    }
}
