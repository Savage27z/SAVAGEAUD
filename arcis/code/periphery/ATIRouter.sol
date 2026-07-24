// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IAgentTreasury} from "../interfaces/IAgentTreasury.sol";
import {IAgentCredit} from "../interfaces/IAgentCredit.sol";
import {ErrorLib} from "../libraries/ErrorLib.sol";

/// @title ATIRouter
/// @author Arcis Protocol
/// @notice Single-call entry point for all agent interactions with Arcis
/// @dev Agents can interact with the vault directly via the ATI interface,
///      but the router provides convenience methods for multi-step operations:
///      - depositAndBorrow: deposit USDC, then borrow against the position
///      - repayAndWithdraw: repay a loan, then withdraw collateral
///      - depositMax: deposit all USDC balance
///      - withdrawMax: withdraw entire position
///
///      The router never holds funds. All operations are atomic.
contract ATIRouter {
    // ══════════════════════════════════════════════════════════════
    //                         STORAGE
    // ══════════════════════════════════════════════════════════════

    address public immutable vault;
    address public immutable credit;
    address public immutable usdc;

    // ══════════════════════════════════════════════════════════════
    //                       CONSTRUCTOR
    // ══════════════════════════════════════════════════════════════

    /// @param _vault ArcisVault address
    /// @param _credit AgentCredit address (address(0) if credit module not yet deployed)
    /// @param _usdc USDC token address
    constructor(address _vault, address _credit, address _usdc) {
        if (_vault == address(0) || _usdc == address(0)) revert ErrorLib.ZeroAddress();
        vault = _vault;
        credit = _credit;
        usdc = _usdc;

        // Approve vault to spend router's USDC (for forwarding deposits)
        _safeApprove(_usdc, _vault, type(uint256).max);

        // Approve credit module to spend router's raUSDC (for forwarding collateral)
        if (_credit != address(0)) {
            _safeApprove(_vault, _credit, type(uint256).max);
        }
    }

    // ══════════════════════════════════════════════════════════════
    //                    VAULT OPERATIONS
    // ══════════════════════════════════════════════════════════════

    /// @notice Deposit USDC into the vault (convenience wrapper)
    /// @param amount USDC amount to deposit
    /// @return shares raUSDC shares minted
    function deposit(uint256 amount) external returns (uint256 shares) {
        _safeTransferFrom(usdc, msg.sender, address(this), amount);
        shares = IAgentTreasury(vault).deposit(amount);
        // Transfer shares to the agent
        _safeTransfer(vault, msg.sender, shares);
    }

    /// @notice Withdraw USDC from the vault (convenience wrapper)
    /// @param shares raUSDC shares to redeem
    /// @return amount USDC returned
    function withdraw(uint256 shares) external returns (uint256 amount) {
        _safeTransferFrom(vault, msg.sender, address(this), shares);
        amount = IAgentTreasury(vault).withdraw(shares);
        _safeTransfer(usdc, msg.sender, amount);
    }

    /// @notice Withdraw entire position
    /// @return amount Total USDC returned
    function withdrawMax() external returns (uint256 amount) {
        // Get agent's full share balance
        (bool success, bytes memory data) = vault.staticcall(
            abi.encodeWithSelector(0x70a08231, msg.sender) // balanceOf
        );
        if (!success) revert ErrorLib.CallFailed();
        uint256 shares = abi.decode(data, (uint256));
        if (shares == 0) return 0;

        _safeTransferFrom(vault, msg.sender, address(this), shares);
        amount = IAgentTreasury(vault).withdraw(shares);
        _safeTransfer(usdc, msg.sender, amount);
    }

    /// @notice Deposit all USDC in agent's wallet
    /// @return shares raUSDC shares minted
    function depositMax() external returns (uint256 shares) {
        (bool success, bytes memory data) = usdc.staticcall(
            abi.encodeWithSelector(0x70a08231, msg.sender)
        );
        if (!success) revert ErrorLib.CallFailed();
        uint256 amount = abi.decode(data, (uint256));
        if (amount == 0) return 0;

        _safeTransferFrom(usdc, msg.sender, address(this), amount);
        shares = IAgentTreasury(vault).deposit(amount);
        _safeTransfer(vault, msg.sender, shares);
    }

    // ══════════════════════════════════════════════════════════════
    //                  COMBINED OPERATIONS
    // ══════════════════════════════════════════════════════════════

    /// @notice Deposit USDC, then immediately borrow against the position
    /// @param depositAmount USDC to deposit as collateral
    /// @param borrowAmount USDC to borrow
    /// @return shares raUSDC shares minted
    /// @return loanId ID of the created loan
    function depositAndBorrow(
        uint256 depositAmount,
        uint256 borrowAmount
    ) external returns (uint256 shares, uint256 loanId) {
        if (credit == address(0)) revert ErrorLib.ZeroAddress();

        // Step 1: Deposit USDC -> raUSDC
        _safeTransferFrom(usdc, msg.sender, address(this), depositAmount);
        shares = IAgentTreasury(vault).deposit(depositAmount);

        // Step 2: Use raUSDC as collateral to borrow
        loanId = IAgentCredit(credit).borrow(borrowAmount, shares);

        // Step 3: Forward borrowed USDC to the agent
        // (credit.borrow sends USDC to msg.sender which is this router)
        _safeTransfer(usdc, msg.sender, borrowAmount);
    }

    /// @notice Repay a loan and withdraw the freed collateral
    /// @param loanId Loan to repay
    /// @return amount USDC from withdrawn collateral
    function repayAndWithdraw(uint256 loanId) external returns (uint256 amount) {
        if (credit == address(0)) revert ErrorLib.ZeroAddress();

        // Get loan details to know repayment amount
        (bool success, bytes memory data) = credit.staticcall(
            abi.encodeWithSignature("totalOwed(uint256)", loanId)
        );
        if (!success) revert ErrorLib.CallFailed();
        uint256 owed = abi.decode(data, (uint256));

        // Step 1: Transfer repayment USDC from agent
        _safeTransferFrom(usdc, msg.sender, address(this), owed);
        _safeApprove(usdc, credit, owed);

        // Step 2: Repay loan (collateral returned to this router)
        IAgentCredit(credit).repay(loanId);

        // Step 3: Get returned collateral shares
        (success, data) = vault.staticcall(
            abi.encodeWithSelector(0x70a08231, address(this))
        );
        if (!success) revert ErrorLib.CallFailed();
        uint256 shares = abi.decode(data, (uint256));

        // Step 4: Withdraw collateral as USDC
        if (shares > 0) {
            amount = IAgentTreasury(vault).withdraw(shares);
            _safeTransfer(usdc, msg.sender, amount);
        }
    }

    // ══════════════════════════════════════════════════════════════
    //                     VIEW FUNCTIONS
    // ══════════════════════════════════════════════════════════════

    /// @notice Get agent's current position value in USDC
    function position(address agent) external view returns (uint256) {
        return IAgentTreasury(vault).balance(agent);
    }

    /// @notice Preview deposit: how many shares for X USDC
    function previewDeposit(uint256 amount) external view returns (uint256) {
        (bool success, bytes memory data) = vault.staticcall(
            abi.encodeWithSignature("previewDeposit(uint256)", amount)
        );
        if (!success) return 0;
        return abi.decode(data, (uint256));
    }

    /// @notice Preview withdraw: how much USDC for X shares
    function previewWithdraw(uint256 shares) external view returns (uint256) {
        (bool success, bytes memory data) = vault.staticcall(
            abi.encodeWithSignature("previewWithdraw(uint256)", shares)
        );
        if (!success) return 0;
        return abi.decode(data, (uint256));
    }

    // ══════════════════════════════════════════════════════════════
    //                    SAFE TOKEN HELPERS
    // ══════════════════════════════════════════════════════════════

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
}
