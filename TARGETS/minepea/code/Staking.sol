// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IPea {
    function burn(uint256 amount) external;
}

/**
 * @title Staking
 * @notice Pure revenue-sharing yield staking for PEA token
 */
contract Staking is Ownable, ReentrancyGuard {
    // ============ Constants ============

    uint256 public constant PRECISION = 1e18;
    uint256 public constant MAX_COMPOUND_FEE = 0.003 ether;

    // ============ External Contracts ============

    IERC20 public immutable pea;
    address public treasury;

    // ============ Global State ============

    uint256 public totalStaked;
    uint256 public accYieldPerShare;           // Accumulated yield per staked token (scaled by PRECISION)
    uint256 public totalYieldDistributed;

    // ============ Config ============

    uint256 public minStake = 1e18 / 10;            // 0.1 PEA minimum
    uint256 public compoundCooldown = 1 days;
    uint256 public compoundFee = 0.00025 ether;  // 0.00025 ETH per compound

    // ============ Per-User State ============

    struct StakeInfo {
        uint256 balance;              // Staked PEA amount
        uint256 pendingRewards;       // Accumulated unclaimed yield
        uint256 compoundFeeReserve;   // ETH deposited for auto-compound fees
        uint64 lastClaimAt;
        uint64 lastDepositAt;
        uint64 lastWithdrawAt;
    }

    mapping(address => StakeInfo) public stakes;
    mapping(address => uint256) public userRewardsDebt;  // Separate mapping for precision

    // ============ Events ============

    event Deposited(address indexed user, uint256 amount, uint256 newBalance);
    event Withdrawn(address indexed user, uint256 amount, uint256 newBalance);
    event YieldClaimed(address indexed user, uint256 amount);
    event YieldCompounded(address indexed user, uint256 amount, address indexed compounder, uint256 fee);
    event YieldDistributed(uint256 amount, uint256 newAccYieldPerShare);
    event YieldBurned(uint256 amount);
    event CompoundFeeDeposited(address indexed user, uint256 amount);
    event CompoundFeeRefunded(address indexed user, uint256 amount);
    event ConfigUpdated(string param, uint256 oldValue, uint256 newValue);

    // ============ Errors ============

    error ZeroAddress();
    error ZeroAmount();
    error InsufficientBalance();
    error InsufficientPendingRewards();
    error InsufficientCompoundFeeReserve();
    error BelowMinimumStake();
    error CompoundCooldownNotMet();
    error OnlyTreasury();
    error TransferFailed();
    error InvalidConfig();

    // ============ Modifiers ============

    modifier onlyTreasury() {
        if (msg.sender != treasury) revert OnlyTreasury();
        _;
    }

    // ============ Constructor ============

    constructor(address _pea, address _treasury) Ownable(msg.sender) {
        if (_pea == address(0)) revert ZeroAddress();
        if (_treasury == address(0)) revert ZeroAddress();

        pea = IERC20(_pea);
        treasury = _treasury;
    }

    // ============ Core Staking Functions ============

    /**
     * @notice Stake PEA tokens, optionally deposit ETH for auto-compound fee reserve
     * @param amount Amount of PEA to stake
     * @dev Send ETH with the call to also fund compound fee reserve
     */
    function deposit(uint256 amount) external payable nonReentrant {
        if (amount == 0) revert ZeroAmount();

        StakeInfo storage stake = stakes[msg.sender];

        // Update rewards before modifying balance (also sets userRewardsDebt)
        _updateRewards(msg.sender);

        uint256 newBalance = stake.balance + amount;
        if (newBalance < minStake) revert BelowMinimumStake();

        // Transfer PEA from user
        if (!pea.transferFrom(msg.sender, address(this), amount)) revert TransferFailed();

        // Update state
        stake.balance = newBalance;
        stake.lastDepositAt = uint64(block.timestamp);
        // Initialize lastClaimAt for new stakers (starts 24h cooldown for autocompounds)
        if (stake.lastClaimAt == 0) {
            stake.lastClaimAt = uint64(block.timestamp);
        }
        totalStaked += amount;

        // Sync debt after balance change
        // For existing stakers, _updateRewards already set this value
        // For new stakers (balance was 0), _updateRewards returned early without setting debt
        userRewardsDebt[msg.sender] = accYieldPerShare;

        // Add any ETH sent as compound fee reserve
        if (msg.value > 0) {
            stake.compoundFeeReserve += msg.value;
            emit CompoundFeeDeposited(msg.sender, msg.value);
        }

        emit Deposited(msg.sender, amount, newBalance);
    }

    /**
     * @notice Withdraw staked PEA tokens
     * @param amount Amount of PEA to withdraw
     */
    function withdraw(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();

        StakeInfo storage stake = stakes[msg.sender];
        if (stake.balance < amount) revert InsufficientBalance();

        // Update rewards before modifying balance (also sets userRewardsDebt)
        _updateRewards(msg.sender);

        uint256 newBalance = stake.balance - amount;

        // If withdrawing all, auto-refund compound fee reserve
        uint256 feeRefund = 0;
        if (newBalance == 0) {
            feeRefund = stake.compoundFeeReserve;
            stake.compoundFeeReserve = 0;
        }

        // Update state
        stake.balance = newBalance;
        stake.lastWithdrawAt = uint64(block.timestamp);
        totalStaked -= amount;

        // Transfer PEA to user
        if (!pea.transfer(msg.sender, amount)) revert TransferFailed();

        // Refund compound fee reserve if applicable
        if (feeRefund > 0) {
            _safeTransferETH(msg.sender, feeRefund);
            emit CompoundFeeRefunded(msg.sender, feeRefund);
        }

        emit Withdrawn(msg.sender, amount, newBalance);
    }

    // ============ Claim Functions ============

    /**
     * @notice Claim all pending yield rewards
     */
    function claimYield() external nonReentrant {
        _updateRewards(msg.sender);

        StakeInfo storage stake = stakes[msg.sender];
        uint256 pending = stake.pendingRewards;
        if (pending == 0) revert InsufficientPendingRewards();

        // Safety net: cap at available yield (contract balance minus staked)
        uint256 availableYield = pea.balanceOf(address(this)) - totalStaked;
        if (pending > availableYield) {
            // Only deduct actually-paid amount, keep remainder for later
            stake.pendingRewards = pending - availableYield;
            pending = availableYield;
        } else {
            stake.pendingRewards = 0;
        }
        stake.lastClaimAt = uint64(block.timestamp);

        if (!pea.transfer(msg.sender, pending)) revert TransferFailed();

        emit YieldClaimed(msg.sender, pending);
    }

    /**
     * @notice Claim partial yield rewards
     * @param amount Amount of yield to claim
     */
    function claimYieldPartial(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();

        _updateRewards(msg.sender);

        StakeInfo storage stake = stakes[msg.sender];
        if (amount > stake.pendingRewards) revert InsufficientPendingRewards();

        // Safety net
        uint256 availableYield = pea.balanceOf(address(this)) - totalStaked;
        if (amount > availableYield) {
            amount = availableYield;
        }

        stake.pendingRewards -= amount;
        stake.lastClaimAt = uint64(block.timestamp);

        if (!pea.transfer(msg.sender, amount)) revert TransferFailed();

        emit YieldClaimed(msg.sender, amount);
    }

    // ============ Compound Functions ============

    /**
     * @notice Compound own pending rewards
     */
    function compound() external nonReentrant {
        _compound(msg.sender, msg.sender, false);
    }

    /**
     * @notice Compound rewards for another user
     * @dev Requires cooldown elapsed and sufficient fee reserve
     * @param user Address to compound for
     */
    function compoundFor(address user) external nonReentrant {
        if (user == address(0)) revert ZeroAddress();

        StakeInfo storage stake = stakes[user];

        // Verify cooldown
        if (block.timestamp < stake.lastClaimAt + compoundCooldown) {
            revert CompoundCooldownNotMet();
        }

        // Verify fee reserve
        if (stake.compoundFeeReserve < compoundFee) {
            revert InsufficientCompoundFeeReserve();
        }

        // Deduct fee from reserve
        stake.compoundFeeReserve -= compoundFee;

        // Execute compound
        _compound(user, msg.sender, true);

        // Pay compounder
        _safeTransferETH(msg.sender, compoundFee);
    }

    /**
     * @notice Internal compound logic
     * @param user User whose rewards to compound
     * @param compounder Address executing the compound
     * @param payFee Whether to charge fee
     */
    function _compound(address user, address compounder, bool payFee) internal {
        _updateRewards(user);

        StakeInfo storage stake = stakes[user];
        uint256 pending = stake.pendingRewards;
        if (pending == 0) revert InsufficientPendingRewards();

        // Safety net
        uint256 availableYield = pea.balanceOf(address(this)) - totalStaked;
        if (pending > availableYield) {
            // Only deduct actually-paid amount, keep remainder for later
            stake.pendingRewards = pending - availableYield;
            pending = availableYield;
        } else {
            stake.pendingRewards = 0;
        }

        // Update timestamp
        stake.lastClaimAt = uint64(block.timestamp);

        // Add to stake (no minimum check on compound since they already have stake)
        stake.balance += pending;
        totalStaked += pending;

        // Update debt for new balance
        userRewardsDebt[user] = accYieldPerShare;

        uint256 fee = payFee ? compoundFee : 0;

        emit YieldCompounded(user, pending, compounder, fee);
    }

    // ============ Compound Fee Reserve Functions ============

    /**
     * @notice Deposit ETH to enable auto-compounding
     */
    function depositCompoundFee() external payable nonReentrant {
        if (msg.value == 0) revert ZeroAmount();

        stakes[msg.sender].compoundFeeReserve += msg.value;

        emit CompoundFeeDeposited(msg.sender, msg.value);
    }

    /**
     * @notice Withdraw unused compound fee reserve
     * @param amount Amount of ETH to withdraw
     */
    function withdrawCompoundFee(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();

        StakeInfo storage stake = stakes[msg.sender];
        if (amount > stake.compoundFeeReserve) revert InsufficientCompoundFeeReserve();

        stake.compoundFeeReserve -= amount;

        _safeTransferETH(msg.sender, amount);

        emit CompoundFeeRefunded(msg.sender, amount);
    }

    // ============ Yield Distribution Functions ============

    /**
     * @notice Distribute yield from Treasury (called after buyback)
     * @dev Only callable by Treasury contract
     * @param amount Amount of PEA to distribute (already transferred to this contract)
     */
    function distributeYield(uint256 amount) external onlyTreasury {
        _distributeYield(amount);
    }

    /**
     * @notice Manually add PEA to stakers
     * @param amount Amount of PEA to add
     */
    function sowPea(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();

        // Transfer PEA from caller
        if (!pea.transferFrom(msg.sender, address(this), amount)) revert TransferFailed();

        _distributeYield(amount);
    }

    /**
     * @notice Internal yield distribution logic
     * @param amount Amount to distribute
     */
    function _distributeYield(uint256 amount) internal {
        if (totalStaked == 0) {
            // No stakers - burn the PEA to prevent loss
            IPea(address(pea)).burn(amount);
            emit YieldBurned(amount);
            return;
        }

        accYieldPerShare += (amount * PRECISION) / totalStaked;
        totalYieldDistributed += amount;

        emit YieldDistributed(amount, accYieldPerShare);
    }

    // ============ Core Math ============

    /**
     * @notice Update user's pending rewards based on accumulator
     * @dev Must be called BEFORE modifying user's balance
     * @param user Address to update
     */
    function _updateRewards(address user) internal {
        StakeInfo storage stake = stakes[user];

        if (stake.balance == 0) return;

        uint256 debt = userRewardsDebt[user];
        if (accYieldPerShare > debt) {
            uint256 accumulated = accYieldPerShare - debt;
            uint256 personalRewards = (accumulated * stake.balance) / PRECISION;
            stake.pendingRewards += personalRewards;
        }

        userRewardsDebt[user] = accYieldPerShare;
    }

    // ============ Admin Functions ============

    /**
     * @notice Update treasury address
     * @param _treasury New treasury address
     */
    function setTreasury(address _treasury) external onlyOwner {
        if (_treasury == address(0)) revert ZeroAddress();
        treasury = _treasury;
    }

    /**
     * @notice Update minimum stake amount
     * @param _minStake New minimum (in wei)
     */
    function setMinStake(uint256 _minStake) external onlyOwner {
        uint256 old = minStake;
        minStake = _minStake;
        emit ConfigUpdated("minStake", old, _minStake);
    }

    /**
     * @notice Update compound cooldown period
     * @param _cooldown New cooldown in seconds
     */
    function setCompoundCooldown(uint256 _cooldown) external onlyOwner {
        uint256 old = compoundCooldown;
        compoundCooldown = _cooldown;
        emit ConfigUpdated("compoundCooldown", old, _cooldown);
    }

    /**
     * @notice Update compound fee (flat ETH per compound)
     * @param _fee New fee in wei
     */
    function setCompoundFee(uint256 _fee) external onlyOwner {
        if (_fee > MAX_COMPOUND_FEE) revert InvalidConfig();
        uint256 old = compoundFee;
        compoundFee = _fee;
        emit ConfigUpdated("compoundFee", old, _fee);
    }

    // ============ View Functions ============

    /**
     * @notice Get pending rewards for a user (includes uncalculated accumulator delta)
     * @param user Address to check
     * @return pending Total pending rewards
     */
    function getPendingRewards(address user) external view returns (uint256 pending) {
        StakeInfo storage stake = stakes[user];
        pending = stake.pendingRewards;

        if (stake.balance > 0) {
            uint256 debt = userRewardsDebt[user];
            if (accYieldPerShare > debt) {
                uint256 accumulated = accYieldPerShare - debt;
                pending += (accumulated * stake.balance) / PRECISION;
            }
        }
    }

    /**
     * @notice Get full stake info for a user
     * @param user Address to check
     */
    function getStakeInfo(address user) external view returns (
        uint256 balance,
        uint256 pendingRewards,
        uint256 compoundFeeReserve,
        uint64 lastClaimAt,
        uint64 lastDepositAt,
        uint64 lastWithdrawAt,
        bool canCompound
    ) {
        StakeInfo storage stake = stakes[user];
        balance = stake.balance;
        pendingRewards = this.getPendingRewards(user);
        compoundFeeReserve = stake.compoundFeeReserve;
        lastClaimAt = stake.lastClaimAt;
        lastDepositAt = stake.lastDepositAt;
        lastWithdrawAt = stake.lastWithdrawAt;
        canCompound = block.timestamp >= lastClaimAt + compoundCooldown && pendingRewards > 0;
    }

    /**
     * @notice Check if someone can compound for a user
     * @param user Address to check
     * @return canDo Whether compound is possible
     * @return reason Reason if cannot compound
     */
    function canCompoundFor(address user) external view returns (bool canDo, string memory reason) {
        StakeInfo storage stake = stakes[user];

        if (stake.balance == 0) return (false, "No stake");
        if (this.getPendingRewards(user) == 0) return (false, "No pending rewards");
        if (block.timestamp < stake.lastClaimAt + compoundCooldown) return (false, "Cooldown not met");
        if (stake.compoundFeeReserve < compoundFee) return (false, "Insufficient fee reserve");

        return (true, "");
    }

    /**
     * @notice Get global staking statistics
     */
    function getGlobalStats() external view returns (
        uint256 _totalStaked,
        uint256 _totalYieldDistributed,
        uint256 _accYieldPerShare
    ) {
        return (totalStaked, totalYieldDistributed, accYieldPerShare);
    }

    // ============ Internal Helpers ============

    /**
     * @notice Safe ETH transfer with success check
     * @param to Recipient address
     * @param amount Amount to transfer
     */
    function _safeTransferETH(address to, uint256 amount) internal {
        (bool success, ) = to.call{value: amount}("");
        if (!success) revert TransferFailed();
    }

    // ============ Receive ============

    receive() external payable {
        // Only accept ETH through depositCompoundFee()
        revert("Use depositCompoundFee()");
    }
}
