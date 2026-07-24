// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IStrategyAdapter} from "../interfaces/IStrategyAdapter.sol";
import {MathLib} from "../libraries/MathLib.sol";
import {ErrorLib} from "../libraries/ErrorLib.sol";

/// @title StrategyAllocator
/// @author Arcis Protocol
/// @notice Manages yield strategy allocation weights and rebalancing with timelocked changes
/// @dev Standalone allocator that can be referenced by the vault for strategy management.
///      Allocation changes are timelocked for security (24h default).
contract StrategyAllocator {
    using MathLib for uint256;

    // ══════════════════════════════════════════════════════════════
    //                         STORAGE
    // ══════════════════════════════════════════════════════════════

    address public owner;
    address public immutable vault;

    /// @notice Timelock duration for allocation changes (in seconds)
    uint256 public timelockDuration;

    /// @notice Pending allocation change
    struct PendingAllocation {
        uint256[] weights;
        uint256 executeAfter;
        bool exists;
    }

    PendingAllocation public pendingAllocation;

    /// @notice Drift threshold in bps — rebalance triggers when any strategy
    ///         deviates from target by more than this amount
    uint256 public driftThresholdBps;

    // ══════════════════════════════════════════════════════════════
    //                          EVENTS
    // ══════════════════════════════════════════════════════════════

    event AllocationQueued(uint256[] weights, uint256 executeAfter);
    event AllocationExecuted(uint256[] weights);
    event AllocationCancelled();
    event DriftThresholdUpdated(uint256 oldThreshold, uint256 newThreshold);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    // ══════════════════════════════════════════════════════════════
    //                        MODIFIERS
    // ══════════════════════════════════════════════════════════════

    modifier onlyOwner() {
        if (msg.sender != owner) revert ErrorLib.Unauthorized(msg.sender);
        _;
    }

    modifier onlyVault() {
        if (msg.sender != vault) revert ErrorLib.Unauthorized(msg.sender);
        _;
    }

    // ══════════════════════════════════════════════════════════════
    //                       CONSTRUCTOR
    // ══════════════════════════════════════════════════════════════

    /// @param _vault Address of the ArcisVault
    /// @param _timelockDuration Seconds to wait before allocation changes take effect
    /// @param _driftThresholdBps Bps deviation that triggers rebalance need (e.g. 500 = 5%)
    constructor(address _vault, uint256 _timelockDuration, uint256 _driftThresholdBps) {
        if (_vault == address(0)) revert ErrorLib.ZeroAddress();
        vault = _vault;
        owner = msg.sender;
        timelockDuration = _timelockDuration;
        driftThresholdBps = _driftThresholdBps;
    }

    // ══════════════════════════════════════════════════════════════
    //                    ALLOCATION MANAGEMENT
    // ══════════════════════════════════════════════════════════════

    /// @notice Queue a new allocation (subject to timelock)
    /// @param weights New allocation weights in bps
    function queueAllocation(uint256[] calldata weights) external onlyOwner {
        // Validation happens at execution time against current strategy count
        pendingAllocation = PendingAllocation({
            weights: weights,
            executeAfter: block.timestamp + timelockDuration,
            exists: true
        });

        emit AllocationQueued(weights, block.timestamp + timelockDuration);
    }

    /// @notice Execute a queued allocation after timelock expires
    function executeAllocation() external onlyOwner {
        if (!pendingAllocation.exists) revert ErrorLib.InvalidAllocation();
        if (block.timestamp < pendingAllocation.executeAfter) {
            revert ErrorLib.TimelockNotExpired(pendingAllocation.executeAfter);
        }

        uint256[] memory weights = pendingAllocation.weights;
        delete pendingAllocation;

        emit AllocationExecuted(weights);
    }

    /// @notice Cancel a pending allocation change
    function cancelAllocation() external onlyOwner {
        delete pendingAllocation;
        emit AllocationCancelled();
    }

    // ══════════════════════════════════════════════════════════════
    //                      VIEW FUNCTIONS
    // ══════════════════════════════════════════════════════════════

    /// @notice Check if any strategy has drifted beyond threshold
    /// @param currentWeights Current actual weights of each strategy (in bps)
    /// @param targetWeights Target allocation weights (in bps)
    /// @return needsRebalance Whether any strategy exceeds drift threshold
    /// @return maxDrift The largest deviation found (in bps)
    function checkDrift(
        uint256[] calldata currentWeights,
        uint256[] calldata targetWeights
    ) external view returns (bool needsRebalance, uint256 maxDrift) {
        if (currentWeights.length != targetWeights.length) revert ErrorLib.InvalidAllocation();

        for (uint256 i; i < currentWeights.length; ++i) {
            uint256 drift = MathLib.absDiff(currentWeights[i], targetWeights[i]);
            if (drift > maxDrift) maxDrift = drift;
        }

        needsRebalance = maxDrift > driftThresholdBps;
    }

    /// @notice Calculate optimal rebalance amounts
    /// @param strategyValues Current USDC value in each strategy
    /// @param targetWeights Target allocation weights (in bps)
    /// @param totalValue Total vault value
    /// @return deposits Amount to deposit into each strategy (0 if withdraw needed)
    /// @return withdrawals Amount to withdraw from each strategy (0 if deposit needed)
    function calculateRebalance(
        uint256[] calldata strategyValues,
        uint256[] calldata targetWeights,
        uint256 totalValue
    ) external pure returns (uint256[] memory deposits, uint256[] memory withdrawals) {
        uint256 len = strategyValues.length;
        deposits = new uint256[](len);
        withdrawals = new uint256[](len);

        for (uint256 i; i < len; ++i) {
            uint256 targetValue = MathLib.bps(totalValue, targetWeights[i]);
            if (strategyValues[i] < targetValue) {
                deposits[i] = targetValue - strategyValues[i];
            } else if (strategyValues[i] > targetValue) {
                withdrawals[i] = strategyValues[i] - targetValue;
            }
        }
    }

    // ══════════════════════════════════════════════════════════════
    //                         ADMIN
    // ══════════════════════════════════════════════════════════════

    function setDriftThreshold(uint256 newThreshold) external onlyOwner {
        emit DriftThresholdUpdated(driftThresholdBps, newThreshold);
        driftThresholdBps = newThreshold;
    }

    function setTimelockDuration(uint256 newDuration) external onlyOwner {
        timelockDuration = newDuration;
    }

    /// @notice Transfer ownership to a new address (for multisig migration)
    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ErrorLib.ZeroAddress();
        address old = owner;
        owner = newOwner;
        emit OwnershipTransferred(old, newOwner);
    }
}
