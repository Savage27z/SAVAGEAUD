// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IRoleRegistry} from "./IRoleRegistry.sol";
import {IBeHYPEToken} from "./IBeHYPE.sol";
import {IStakingCore} from "./IStakingCore.sol";

/**
 * @title IWithdrawManager
 * @notice Interface for the WithdrawalQueue contract
 * @dev Defines all public and external functions for withdrawal management
 */
interface IWithdrawManager {

    /* ========== STRUCTS ========== */
    
    struct WithdrawalEntry {
        address user;              // Address of the user
        uint256 beHypeAmount;      // Amount of beHYPE tokens locked for withdrawal
        uint256 hypeAmount;        // Amount of HYPE to be withdrawn
        bool claimed;            // Whether the withdrawal has been claimed
    }

    /* ========== ERRORS ========== */

    error WithdrawalsPaused();
    error InvalidAmount();
    error InsufficientBeHYPEBalance();
    error NotAuthorized();
    error IndexOutOfBounds();
    error CanOnlyFinalizeForward();
    error WithdrawalNotClaimable();
    error InvalidWithdrawalID();
    error TransferFailed();
    error WithdrawalsNotPaused();
    error InsufficientHYPELiquidity();
    error InstantWithdrawalRateLimitExceeded();
    error InvalidInstantWithdrawalFee();
    error AlreadyClaimed();
    error InsufficientMinimumAmountOut();

    /* ========== EVENTS ========== */
    
    event WithdrawalQueued(
        address indexed user,
        uint256 indexed withdrawalId,
        uint256 beHypeAmount,
        uint256 hypeAmount,
        uint256 queueIndex
    );
    
    event WithdrawalsBatchFinalized(uint256 upToIndex);

    event WithdrawalClaimed(
        address indexed user,
        uint256 indexed withdrawalId,
        uint256 hypeAmount
    );
    
    event InstantWithdrawal(
        address indexed user,
        uint256 beHypeAmountWithdrawn,
        uint256 hypeAmountReceived,
        uint256 beHypeInstantWithdrawalFee
    );
    
    event InstantWithdrawalFeeInBpsUpdated(uint256 instantWithdrawalFeeInBps);
    
    event InstantWithdrawalCapacityUpdated(uint256 capacity);
    
    event InstantWithdrawalRefillRateUpdated(uint256 refillRate);
    
    /* ========== MAIN FUNCTIONS ========== */
    
    /**
     * @notice Queue a withdrawal request
     * @param beHYPEAmount Amount of beHYPE tokens to withdraw
     * @param instant Whether to withdraw instantly for a fee or queue
     * @param minAmountOut Minimum amount of HYPE to receive (protection against exchange rate changes)
     * @return withdrawalId The ID of the withdrawal request
     */
    function withdraw(uint256 beHYPEAmount, bool instant, uint256 minAmountOut) external returns (uint256 withdrawalId);
    
    /**
     * @notice Finalize withdrawals up to a specific index (protocol governor only)
     * @param index Index up to which withdrawals should be finalized
     */
    function finalizeWithdrawals(uint256 index) external;
    
    /* ========== VIEW FUNCTIONS ========== */
    
    /**
     * @notice Get the count of pending (unfinalized) withdrawals
     * @return uint256 Number of pending withdrawals
     */
    function getPendingWithdrawalsCount() external view returns (uint256);
    
    /**
     * @notice Check if a withdrawal amount can be instant withdrawn
     * @param beHYPEAmount Amount of beHYPE tokens to withdraw
     * @return bool True if the withdrawal can be instant withdrawn
     */
    function canInstantWithdraw(uint256 beHYPEAmount) external view returns (bool);
    
    /**
     * @notice Get a withdrawal entry from the queue
     * @param index Index of the withdrawal entry
     * @return WithdrawalEntry The withdrawal entry
     */
    function getWithdrawalQueue(uint256 index) external view returns (WithdrawalEntry memory);

    /**
     * @notice Check if a withdrawal can be claimed
     * @param withdrawalId The ID of the withdrawal
     * @return bool True if the withdrawal can be claimed
     */
    function canClaimWithdrawal(uint256 withdrawalId) external view returns (bool);

    /**
     * @notice Get the amount of hype requested for withdrawal
     * @return uint256 The amount of hype requested for withdrawal
     */
    function hypeRequestedForWithdraw() external view returns (uint256);
    
    /* ========== ADMIN FUNCTIONS ========== */
    
    /**
     * @notice Pause withdrawals
     * @dev Only callable by the role registry
     */
    function pauseWithdrawals() external;
    
    /**
     * @notice Unpause withdrawals
     * @dev Only callable by the role registry
     */
    function unpauseWithdrawals() external;
    
    /**
     * @notice Set the instant withdrawal fee in basis points
     * @param _instantWithdrawalFeeInBps The new instant withdrawal fee in basis points
     * @dev Only callable by the protocol guardian
     */
    function setInstantWithdrawalFeeInBps(uint16 _instantWithdrawalFeeInBps) external;
    
    /**
     * @notice Set the instant withdrawal capacity
     * @param capacity The new instant withdrawal capacity
     * @dev Only callable by the protocol admin
     */
    function setInstantWithdrawalCapacity(uint256 capacity) external;
    
    /**
     * @notice Set the instant withdrawal refill rate per second
     * @param refillRate The new instant withdrawal refill rate per second
     * @dev Only callable by the protocol admin
     */
    function setInstantWithdrawalRefillRatePerSecond(uint256 refillRate) external;
    
}
