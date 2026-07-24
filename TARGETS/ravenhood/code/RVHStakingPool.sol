// SPDX-License-Identifier: MIT
pragma solidity 0.8.12;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/**
 * @title RVHStakingPool
 * @notice Stake $RVH tokens to earn $RVH rewards over 12 months.
 *         Withdrawals made within 30 days of the last deposit incur a 5% tax
 *         sent to a designated multisig address.
 */
contract RVHStakingPool is Ownable, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20Metadata;

    uint256 public constant LOCK_PERIOD        = 30 days;
    uint256 public constant EARLY_WITHDRAW_TAX = 500;
    uint256 public constant BASIS_POINTS       = 10_000;
    uint256 public constant MAX_REWARD_PER_SECOND = 1_000_000 * 1e18;

    IERC20Metadata public immutable rvhToken;
    uint256 public immutable PRECISION_FACTOR;

    uint256 public accTokenPerShare;
    uint256 public startTimestamp;
    uint256 public endTimestamp;
    uint256 public lastRewardTimestamp;
    uint256 public rewardPerSecond;
    uint256 public totalStaked;

    address public taxReceiver;

    struct UserInfo {
        uint256 amount;
        uint256 rewardDebt;
        uint256 lastDepositTimestamp;
    }

    mapping(address => UserInfo) public userInfo;

    event Deposit(address indexed user, uint256 amount);
    event Harvest(address indexed user, uint256 amount);
    event Withdraw(address indexed user, uint256 amount, uint256 taxAmount);
    event EmergencyWithdraw(address indexed user, uint256 amount, uint256 taxAmount);
    event RewardsStop(uint256 timestamp);
    event NewStartAndEndTimestamp(uint256 startTimestamp, uint256 endTimestamp);
    event RewardPerSecondUpdated(uint256 rewardPerSecond);
    event TaxReceiverUpdated(address indexed taxReceiver);
    event TokenRecovery(address indexed token, uint256 amount);
    event EmergencyRewardWithdraw(address indexed to, uint256 amount);

    constructor(
        IERC20Metadata _rvhToken,
        uint256 _rewardPerSecond,
        uint256 _startTimestamp,
        uint256 _endTimestamp,
        address _taxReceiver,
        address _admin
    ) {
        require(address(_rvhToken) != address(0), "Invalid token");
        require(_startTimestamp < _endTimestamp, "Start must be before end");
        require(block.timestamp < _startTimestamp, "Start must be in the future");
        require(_taxReceiver != address(0), "Invalid tax receiver");
        require(_admin != address(0), "Invalid admin");
        require(_rewardPerSecond <= MAX_REWARD_PER_SECOND, "Exceeds max reward rate");

        uint256 decimals = uint256(_rvhToken.decimals());
        require(decimals < 30, "Token decimals must be < 30");

        rvhToken       = _rvhToken;
        rewardPerSecond = _rewardPerSecond;
        startTimestamp  = _startTimestamp;
        endTimestamp    = _endTimestamp;
        taxReceiver     = _taxReceiver;
        lastRewardTimestamp = _startTimestamp;
        PRECISION_FACTOR    = 10 ** (30 - decimals);

        transferOwnership(_admin);
    }

    function deposit(uint256 _amount) external nonReentrant whenNotPaused {
        require(_amount > 0, "Amount must be > 0");
        UserInfo storage user = userInfo[msg.sender];
        _updatePool();
        uint256 pending = user.amount > 0 ? _pendingOf(user) : 0;
        rvhToken.safeTransferFrom(msg.sender, address(this), _amount);
        user.amount              += _amount;
        totalStaked              += _amount;
        user.lastDepositTimestamp = block.timestamp;
        user.rewardDebt           = _rewardDebtOf(user);
        if (pending > 0) {
            uint256 transferred = _safeRewardTransfer(msg.sender, pending);
            emit Harvest(msg.sender, transferred);
        }
        emit Deposit(msg.sender, _amount);
    }

    function harvest() external nonReentrant whenNotPaused {
        UserInfo storage user = userInfo[msg.sender];
        require(user.amount > 0, "Nothing staked");
        _updatePool();
        uint256 pending = _pendingOf(user);
        require(pending > 0, "No rewards to claim");
        user.rewardDebt = _rewardDebtOf(user);
        uint256 transferred = _safeRewardTransfer(msg.sender, pending);
        emit Harvest(msg.sender, transferred);
    }

    function withdraw(uint256 _amount) external nonReentrant whenNotPaused {
        UserInfo storage user = userInfo[msg.sender];
        require(_amount > 0, "Amount must be > 0");
        require(user.amount >= _amount, "Withdraw exceeds staked balance");
        _updatePool();
        uint256 pending = _pendingOf(user);
        user.amount  -= _amount;
        totalStaked  -= _amount;
        user.rewardDebt = _rewardDebtOf(user);
        (uint256 amountAfterTax, uint256 taxAmount) = _applyTax(user, _amount);
        if (taxAmount > 0) {
            rvhToken.safeTransfer(taxReceiver, taxAmount);
        }
        rvhToken.safeTransfer(msg.sender, amountAfterTax);
        if (pending > 0) {
            uint256 transferred = _safeRewardTransfer(msg.sender, pending);
            emit Harvest(msg.sender, transferred);
        }
        emit Withdraw(msg.sender, _amount, taxAmount);
    }

    function emergencyWithdraw() external nonReentrant {
        UserInfo storage user = userInfo[msg.sender];
        uint256 amount = user.amount;
        require(amount > 0, "Nothing to withdraw");
        (uint256 amountAfterTax, uint256 taxAmount) = _applyTax(user, amount);
        totalStaked              -= amount;
        user.amount               = 0;
        user.rewardDebt           = 0;
        user.lastDepositTimestamp = 0;
        if (taxAmount > 0) {
            rvhToken.safeTransfer(taxReceiver, taxAmount);
        }
        rvhToken.safeTransfer(msg.sender, amountAfterTax);
        emit EmergencyWithdraw(msg.sender, amount, taxAmount);
    }

    function pendingReward(address _user) external view returns (uint256) {
        UserInfo storage user = userInfo[_user];
        uint256 adjustedAcc = accTokenPerShare;
        if (block.timestamp > lastRewardTimestamp && totalStaked != 0) {
            uint256 elapsed = _getMultiplier(lastRewardTimestamp, block.timestamp);
            adjustedAcc += (elapsed * rewardPerSecond * PRECISION_FACTOR) / totalStaked;
        }
        return (user.amount * adjustedAcc) / PRECISION_FACTOR - user.rewardDebt;
    }

    function isLocked(address _user) external view returns (bool) {
        UserInfo storage user = userInfo[_user];
        return user.lastDepositTimestamp != 0
            && block.timestamp < user.lastDepositTimestamp + LOCK_PERIOD;
    }

    function rewardBalance() external view returns (uint256) {
        return rvhToken.balanceOf(address(this)) - totalStaked;
    }

    function lockTimeRemaining(address _user) external view returns (uint256) {
        UserInfo storage user = userInfo[_user];
        if (user.lastDepositTimestamp == 0) return 0;
        uint256 unlockTime = user.lastDepositTimestamp + LOCK_PERIOD;
        if (block.timestamp >= unlockTime) return 0;
        return unlockTime - block.timestamp;
    }

    // Owner functions
    function stopReward() external onlyOwner {
        endTimestamp = block.timestamp;
        emit RewardsStop(endTimestamp);
    }

    function updateStartAndEndTimestamp(uint256 _startTimestamp, uint256 _endTimestamp) external onlyOwner {
        require(block.timestamp < startTimestamp, "Pool already started");
        require(_startTimestamp < _endTimestamp, "Start must be before end");
        require(block.timestamp < _startTimestamp, "Start must be in the future");
        startTimestamp      = _startTimestamp;
        endTimestamp        = _endTimestamp;
        lastRewardTimestamp = _startTimestamp;
        emit NewStartAndEndTimestamp(_startTimestamp, _endTimestamp);
    }

    function updateRewardPerSecond(uint256 _rewardPerSecond) external onlyOwner {
        require(_rewardPerSecond <= MAX_REWARD_PER_SECOND, "Exceeds max reward rate");
        _updatePool();
        rewardPerSecond = _rewardPerSecond;
        emit RewardPerSecondUpdated(_rewardPerSecond);
    }

    function updateTaxReceiver(address _taxReceiver) external onlyOwner {
        require(_taxReceiver != address(0), "Invalid address");
        taxReceiver = _taxReceiver;
        emit TaxReceiverUpdated(_taxReceiver);
    }

    function emergencyRewardWithdraw(uint256 _amount) external onlyOwner {
        uint256 rewardBalance = rvhToken.balanceOf(address(this)) - totalStaked;
        require(_amount <= rewardBalance, "Amount exceeds reward balance");
        rvhToken.safeTransfer(msg.sender, _amount);
        emit EmergencyRewardWithdraw(msg.sender, _amount);
    }

    function recoverToken(address _token) external onlyOwner {
        require(_token != address(rvhToken), "Cannot recover RVH");
        uint256 balance = IERC20Metadata(_token).balanceOf(address(this));
        require(balance > 0, "Nothing to recover");
        IERC20Metadata(_token).safeTransfer(msg.sender, balance);
        emit TokenRecovery(_token, balance);
    }

    function pause()   external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    // Internal helpers
    function _updatePool() internal {
        if (block.timestamp <= lastRewardTimestamp) return;
        if (totalStaked == 0) {
            lastRewardTimestamp = block.timestamp;
            return;
        }
        uint256 elapsed = _getMultiplier(lastRewardTimestamp, block.timestamp);
        accTokenPerShare    += (elapsed * rewardPerSecond * PRECISION_FACTOR) / totalStaked;
        lastRewardTimestamp  = block.timestamp;
    }

    function _getMultiplier(uint256 _from, uint256 _to) internal view returns (uint256) {
        if (_to <= endTimestamp)   return _to - _from;
        if (_from >= endTimestamp) return 0;
        return endTimestamp - _from;
    }

    function _pendingOf(UserInfo storage user) internal view returns (uint256) {
        return (user.amount * accTokenPerShare) / PRECISION_FACTOR - user.rewardDebt;
    }

    function _rewardDebtOf(UserInfo storage user) internal view returns (uint256) {
        return (user.amount * accTokenPerShare) / PRECISION_FACTOR;
    }

    function _applyTax(UserInfo storage user, uint256 _amount)
        internal view returns (uint256 amountAfterTax, uint256 taxAmount)
    {
        if (user.lastDepositTimestamp != 0 && block.timestamp < user.lastDepositTimestamp + LOCK_PERIOD) {
            taxAmount    = (_amount * EARLY_WITHDRAW_TAX) / BASIS_POINTS;
            amountAfterTax = _amount - taxAmount;
        } else {
            taxAmount    = 0;
            amountAfterTax = _amount;
        }
    }

    function _safeRewardTransfer(address _to, uint256 _amount) internal returns (uint256 transferred) {
        uint256 rewardBalance = rvhToken.balanceOf(address(this)) - totalStaked;
        transferred = _amount > rewardBalance ? rewardBalance : _amount;
        if (transferred > 0) {
            rvhToken.safeTransfer(_to, transferred);
        }
    }
}
