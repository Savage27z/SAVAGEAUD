--- Treasury.sol ===
// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {AccessControl} from "openzeppelin-contracts/contracts/access/AccessControl.sol";
import {Pausable} from "openzeppelin-contracts/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

import {IV3SwapRouter} from "swap-router-contracts/contracts/interfaces/IV3SwapRouter.sol";
import {RewardsDistributor} from "../staking/RewardsDistributor.sol";
import {Staking} from "../staking/Staking.sol";

/// @title Treasury
/// @notice Manages K613 token flows: stakes K613 to get xK613 for rewards, executes buybacks. Rewards are distributed in xK613.
contract Treasury is AccessControl, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice Thrown when a zero address is passed as a parameter.
    error ZeroAddress();
    /// @notice Thrown when amount is zero where a positive value is required.
    error ZeroAmount();
    /// @notice Thrown when the DEX swap call fails.
    error BuybackFailed();
    /// @notice Thrown when the swap output is less than minK613Out.
    error InsufficientOutput();
    /// @notice Thrown when buyback is called with a router not in the whitelist.
    error RouterNotWhitelisted();

    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    IERC20 public immutable k613;
    IERC20 public immutable xk613;
    Staking public immutable staking;
    RewardsDistributor public immutable rewardsDistributor;

    /// @notice Whitelist of DEX routers allowed for buyback. Only DEFAULT_ADMIN_ROLE can update.
    mapping(address => bool) public routerWhitelist;
    /// @notice List of whitelisted router addresses for enumeration (see getWhitelistedRouters).
    address[] private _whitelistedRouters;

    /// @notice Emitted when admin withdraws tokens.
    /// @param token Token withdrawn.
    /// @param to Recipient.
    /// @param amount Amount withdrawn.
    event Withdrawn(address indexed token, address indexed to, uint256 amount);

    /// @notice Emitted when a buyback is executed.
    /// @param tokenIn Token swapped in for K613.
    /// @param router DEX router used for the swap.
    /// @param amountIn Amount of tokenIn swapped.
    /// @param k613Out Amount of K613 received.
    /// @param distributed Whether rewards were distributed to stakers.
    event BuybackExecuted(
        address indexed tokenIn, address indexed router, uint256 amountIn, uint256 k613Out, bool distributed
    );
    /// @notice Emitted when a router is added to or removed from the whitelist.
    event RouterWhitelistUpdated(address indexed router, bool allowed);

    event Xk613PullAllowanceSet(address indexed spender, uint256 amount);

    /// @notice Emitted when Treasury stakes K613 it already holds, to obtain xK613 used as the reward
    ///         pool for an external pull-based incentives strategy (e.g. Aave's `PullRewardsTransferStrategy`).
    event StakedForExternalIncentives(uint256 amount);

    /// @notice Deploys the Treasury with K613, xK613, Staking, and RewardsDistributor.
    constructor(address k613Token, address xk613Token, address staking_, address rewardsDistributor_) {
        if (
            k613Token == address(0) || xk613Token == address(0) || staking_ == address(0)
                || rewardsDistributor_ == address(0)
        ) {
            revert ZeroAddress();
        }
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(PAUSER_ROLE, msg.sender);
        k613 = IERC20(k613Token);
        xk613 = IERC20(xk613Token);
        staking = Staking(staking_);
        rewardsDistributor = RewardsDistributor(rewardsDistributor_);
    }

    /// @notice Stakes K613 already held by this contract into Staking, leaving the resulting xK613 on Treasury's
    ///         balance. Used to fund an external pull-based incentives strategy (e.g. Aave's
    ///         `PullRewardsTransferStrategy`) without touching `RewardsDistributor.totalDeposits`, so the
    ///         per-share reward math for buyback rewards is NOT diluted by this xK613 supply.
    /// @dev    Treasury is whitelisted to hold xK613 and is a `systemStaker` in `Staking`, so the resulting
    ///         xK613 sits on Treasury's balance and is later pulled by the strategy via `transferFrom`
    ///         (see `approveXk613PullRewards`). This contrasts with `depositRewards`, which forwards xK613
    ///         to `RewardsDistributor` and adds to its reward stream.
    /// @param amount Amount of K613 (already held by Treasury) to stake. Must be non-zero.
    function stakeForExternalIncentives(uint256 amount)
        external
        nonReentrant
        onlyRole(DEFAULT_ADMIN_ROLE)
        whenNotPaused
    {
        if (amount == 0) revert ZeroAmount();
        k613.forceApprove(address(staking), amount);
        staking.stake(amount);
        k613.forceApprove(address(staking), 0);
        emit StakedForExternalIncentives(amount);
    }

    /// @notice Deposits rewards: stakes K613 to get xK613, sends xK613 to RewardsDistributor and notifies. Caller must have approved Treasury for K613.
    /// @param amount Amount of K613 to stake and deposit as xK613 rewards. If zero, no-op.
    function depositRewards(uint256 amount) external nonReentrant onlyRole(DEFAULT_ADMIN_ROLE) whenNotPaused {
        if (amount == 0) return;
        k613.safeTransferFrom(msg.sender, address(this), amount);
        k613.forceApprove(address(staking), amount);
        staking.stake(amount);
        k613.forceApprove(address(staking), 0);
        xk613.safeTransfer(address(rewardsDistributor), amount);
        rewardsDistributor.notifyReward(amount);
    }

    /// @notice Adds or removes a router from the buyback whitelist. Only DEFAULT_ADMIN_ROLE.
    /// @param router Router address to whitelist or remove.
    /// @param allowed True to allow buyback via this router, false to disallow.
    function setRouterWhitelist(address router, bool allowed) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (router == address(0)) revert ZeroAddress();
        bool wasAllowed = routerWhitelist[router];
        routerWhitelist[router] = allowed;
        if (allowed && !wasAllowed) {
            _whitelistedRouters.push(router);
        } else if (!allowed && wasAllowed) {
            _removeRouterFromList(router);
        }
        emit RouterWhitelistUpdated(router, allowed);
    }

    /// @notice Returns the list of all whitelisted router addresses.
    function getWhitelistedRouters() external view returns (address[] memory) {
        return _whitelistedRouters;
    }

    /// @dev Removes a router from _whitelistedRouters by swapping with the last element and popping.
    function _removeRouterFromList(address router) private {
        uint256 len = _whitelistedRouters.length;
        for (uint256 i = 0; i < len; ++i) {
            if (_whitelistedRouters[i] == router) {
                address lastRouter = _whitelistedRouters[len - 1];
                _whitelistedRouters[i] = lastRouter;
                _whitelistedRouters.pop();
                return;
            }
        }
    }

    /// @notice Buys K613 with `tokenIn` through a whitelisted router implementing `IV3SwapRouter.exactInputSingle` (Uniswap SwapRouter02-style).
    /// @param poolFee Uniswap V3 fee tier (e.g. 3000 = 0.3%).
    function buybackV3ExactInputSingle(
        address tokenIn,
        address router,
        uint256 amountIn,
        uint256 minK613Out,
        uint24 poolFee,
        bool distributeRewards
    ) external nonReentrant onlyRole(DEFAULT_ADMIN_ROLE) whenNotPaused returns (uint256 k613Out) {
        if (tokenIn == address(0) || router == address(0)) {
            revert ZeroAddress();
        }
        if (amountIn == 0) {
            revert ZeroAmount();
        }
        if (!routerWhitelist[router]) revert RouterNotWhitelisted();
        if (tokenIn == address(k613)) {
            revert InsufficientOutput();
        }

        uint256 k613Before = k613.balanceOf(address(this));
        uint256 routerReportedOut = 0;
        IERC20(tokenIn).forceApprove(router, amountIn);
        try IV3SwapRouter(router)
            .exactInputSingle(
                IV3SwapRouter.ExactInputSingleParams({
                    tokenIn: tokenIn,
                    tokenOut: address(k613),
                    fee: poolFee,
                    recipient: address(this),
                    amountIn: amountIn,
                    amountOutMinimum: minK613Out,
                    sqrtPriceLimitX96: 0
                })
            ) returns (
            uint256 amountOut
        ) {
            routerReportedOut = amountOut;
        } catch {
            revert BuybackFailed();
        }
        IERC20(tokenIn).forceApprove(router, 0);
        if (routerReportedOut < minK613Out) {
            revert InsufficientOutput();
        }
        k613Out = k613.balanceOf(address(this)) - k613Before;
        if (k613Out < minK613Out) {
            revert InsufficientOutput();
        }
        if (distributeRewards && k613Out > 0) {
            k613.forceApprove(address(staking), k613Out);
            staking.stake(k613Out);
            k613.forceApprove(address(staking), 0);
            xk613.safeTransfer(address(rewardsDistributor), k613Out);
            rewardsDistributor.notifyReward(k613Out);
        }
        emit BuybackExecuted(tokenIn, router, amountIn, k613Out, distributeRewards);
    }

    /// @notice Withdraws any ERC20 token from the Treasury. Only callable by DEFAULT_ADMIN_ROLE.
    /// @param token Token to withdraw.
    /// @param to Recipient address.
    /// @param amount Amount to withdraw.
    function withdraw(address token, address to, uint256 amount) external nonReentrant onlyRole(DEFAULT_ADMIN_ROLE) {
        if (token == address(0) || to == address(0)) {
            revert ZeroAddress();
        }
        if (amount == 0) {
            revert ZeroAmount();
        }
        IERC20(token).safeTransfer(to, amount);
        emit Withdrawn(token, to, amount);
    }

    function approveXk613PullRewards(address spender, uint256 amount)
        external
        nonReentrant
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (spender == address(0)) revert ZeroAddress();
        xk613.forceApprove(spender, amount);
        emit Xk613PullAllowanceSet(spender, amount);
    }

    /// @notice Pauses deposit and buybackV3 operations. Only callable by PAUSER_ROLE.
    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    /// @notice Resumes operations. Only callable by PAUSER_ROLE.
    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }
}


--- RewardsDistributor.sol ===
// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {AccessControl} from "openzeppelin-contracts/contracts/access/AccessControl.sol";
import {Pausable} from "openzeppelin-contracts/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

interface IStaking {
    function stake(uint256 amount) external;
    function exitQueueLength(address user) external view returns (uint256);
}

/// @title RewardsDistributor
/// @notice Users deposit xK613 (stakingToken) to earn rewards in xK613 (rewardToken). Claim anytime. Penalties from instant exit are staked to get xK613, then distributed. Rewards can be converted to K613 via Staking instant exit (50% penalty)
contract RewardsDistributor is AccessControl, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    /// @notice Thrown when a zero address is provided
    error ZeroAddress();
    /// @notice Thrown when a zero amount is provided
    error ZeroAmount();
    /// @notice Thrown when a user has no rewards to claim
    error NoRewards();
    /// @notice Thrown when a user has insufficient balance
    error InsufficientBalance();
    /// @notice Thrown when an invalid epoch duration is provided
    error InvalidEpochDuration();
    /// @notice Thrown when a minimum initial deposit is not met
    error MinimumInitialDeposit();
    /// @notice Thrown when a minimum notify amount is not met
    error MinimumNotify();
    /// @notice Thrown when advanceEpoch() is called before the current epoch has ended
    error EpochNotReady();
    /// @notice Thrown when claim() is called while the user has an active exit vesting in Staking
    error ExitVestingActive();

    /// @notice Staking token (xK613): users deposit this to earn rewards
    IERC20 public immutable stakingToken;
    /// @notice Reward token (xK613): rewards are paid out in xK613. Same token as stakingToken
    IERC20 public immutable rewardToken;
    /// @notice K613 token; used to stake penalty K613 in Staking to get xK613 for distribution
    IERC20 public immutable k613;

    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant REWARDS_NOTIFIER_ROLE = keccak256("REWARDS_NOTIFIER_ROLE");

    /// @notice Scale for accRewardPerShare and reward math
    uint256 private constant PRECISION = 1e18;
    /// @notice Minimum penalty flush amount to avoid dust rounding
    uint256 public constant MIN_PENALTY_FLUSH = 1e18;
    /// @notice Minimum first deposit to prevent first-depositor griefing
    uint256 public constant MIN_INITIAL_DEPOSIT = 1e12;
    /// @notice Minimum amount per notifyReward to avoid precision loss and notify spam
    uint256 public constant MIN_NOTIFY = 1e12;

    /// @notice Epoch duration in seconds. Penalties flush at epoch boundary even if below threshold
    uint256 public immutable epochDuration;
    /// @notice Timestamp when penalties were last flushed at epoch boundary
    uint256 public lastEpochFlushAt;

    /// @notice Global accumulated rewards per share, scaled by 1e18
    uint256 public accRewardPerShare;
    /// @notice Rewards notified but not yet distributed (when totalDeposits was 0)
    uint256 public pendingRewards;
    /// @notice Penalties from instant exit; flushed when >= MIN_PENALTY_FLUSH to avoid dust rounding
    uint256 public pendingPenalties;
    /// @notice Total stakingToken (xK613) deposited by all users
    uint256 public totalDeposits;

    /// @notice The amount of stakingToken (xK613) held by a user
    mapping(address => uint256) public balanceOf;
    /// @notice The amount of rewards owed to a user
    mapping(address => uint256) public userRewardDebt;
    /// @notice The amount of rewards pending for a user
    mapping(address => uint256) public userPendingRewards;

    /// @notice Staking contract; receives REWARDS_NOTIFIER_ROLE for penalty rewards
    address public staking;

    /// @notice Emitted when a user claims rewards
    event Claimed(address indexed account, uint256 amount);
    /// @notice Emitted when rewards are notified
    event RewardNotified(uint256 amount);
    /// @notice Emitted when rewards are queued because totalDeposits is zero
    event RewardQueued(uint256 amount);
    /// @notice Emitted when the staking contract is updated
    event StakingUpdated(address indexed staking);
    /// @notice Emitted when a user deposits stakingToken (xK613)
    event Deposited(address indexed account, uint256 amount);
    /// @notice Emitted when a user withdraws stakingToken (xK613)
    event Withdrawn(address indexed account, uint256 amount);
    /// @notice Emitted when penalties are added
    event PenaltyAdded(uint256 amount);
    /// @notice Emitted when the epoch is advanced
    event EpochAdvanced(uint256 timestamp);

    constructor(address stakingToken_, address rewardToken_, address k613_, uint256 epochDuration_) {
        if (stakingToken_ == address(0) || rewardToken_ == address(0) || k613_ == address(0)) revert ZeroAddress();
        if (epochDuration_ == 0) revert InvalidEpochDuration();
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(PAUSER_ROLE, msg.sender);
        stakingToken = IERC20(stakingToken_);
        rewardToken = IERC20(rewardToken_);
        k613 = IERC20(k613_);
        epochDuration = epochDuration_;
        lastEpochFlushAt = block.timestamp;
    }

    /// @notice Sets the staking contract. Grants REWARDS_NOTIFIER_ROLE for penalty rewards. Pass address(0) to disable.
    function setStaking(address staking_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (address(staking) != address(0)) {
            _revokeRole(REWARDS_NOTIFIER_ROLE, address(staking));
        }
        staking = staking_;
        if (staking_ != address(0)) {
            _grantRole(REWARDS_NOTIFIER_ROLE, staking_);
        }
        emit StakingUpdated(staking_);
    }

    /// @notice Deposits xK613 to earn rewards. Caller must approve this contract first
    function deposit(uint256 amount) external nonReentrant whenNotPaused {
        if (amount == 0) revert ZeroAmount();
        if (totalDeposits == 0 && amount < MIN_INITIAL_DEPOSIT) revert MinimumInitialDeposit();
        _updateUser(msg.sender);
        balanceOf[msg.sender] += amount;
        totalDeposits += amount;
        userRewardDebt[msg.sender] = (balanceOf[msg.sender] * accRewardPerShare) / PRECISION;
        stakingToken.safeTransferFrom(msg.sender, address(this), amount);
        emit Deposited(msg.sender, amount);
    }

    /// @notice Withdraws xK613. Must withdraw from RD before initiating exit in Staking.
    function withdraw(uint256 amount) external nonReentrant whenNotPaused {
        if (amount == 0) revert ZeroAmount();
        if (balanceOf[msg.sender] < amount) revert InsufficientBalance();
        _updateUser(msg.sender);
        balanceOf[msg.sender] -= amount;
        totalDeposits -= amount;
        userRewardDebt[msg.sender] = (balanceOf[msg.sender] * accRewardPerShare) / PRECISION;
        stakingToken.safeTransfer(msg.sender, amount);
        emit Withdrawn(msg.sender, amount);
    }

    /// @notice Claims accumulated rewards. Reverts while caller has an active exit vesting in Staking (withdraw from RD first, then exit; no claim during vesting).
    function claim() external nonReentrant whenNotPaused {
        // aderyn-ignore-next-line(reentrancy-state-change)
        if (address(staking) != address(0) && IStaking(staking).exitQueueLength(msg.sender) > 0) {
            revert ExitVestingActive();
        }
        _updateUser(msg.sender);
        uint256 reward = userPendingRewards[msg.sender];
        if (reward == 0) revert NoRewards();

        userPendingRewards[msg.sender] = 0;
        _stakeHeldK613();
        rewardToken.safeTransfer(msg.sender, reward);
        emit Claimed(msg.sender, reward);
    }

    /// @notice Notifies new rewards in xK613. Caller must have transferred rewardToken (xK613) to this contract first.
    function notifyReward(uint256 amount) external nonReentrant onlyRole(REWARDS_NOTIFIER_ROLE) whenNotPaused {
        if (amount == 0) revert ZeroAmount();
        if (amount < MIN_NOTIFY) revert MinimumNotify();
        if (totalDeposits == 0) {
            pendingRewards += amount;
            emit RewardQueued(amount);
            return;
        }
        accRewardPerShare += (amount * PRECISION) / totalDeposits;
        emit RewardNotified(amount);
    }

    /// @notice Receives K613 penalty from Staking; adds to pending penalties. K613 is staked to xK613 on next claim/advanceEpoch to avoid reentrancy (Staking calls this).
    function addPendingPenalty(uint256 amount) external nonReentrant onlyRole(REWARDS_NOTIFIER_ROLE) whenNotPaused {
        if (amount == 0) return;
        pendingPenalties += amount;
        emit PenaltyAdded(amount);
    }

    /// @notice Stakes any K613 held by this contract to get xK613. Non-fatal if Staking is paused.
    function _stakeHeldK613() internal {
        if (address(staking) == address(0)) return;
        uint256 balance = k613.balanceOf(address(this));
        if (balance < 1) return;
        k613.forceApprove(address(staking), balance);
        try IStaking(staking).stake(balance) {}
        catch {
            k613.forceApprove(address(staking), 0);
            return;
        }
        k613.forceApprove(address(staking), 0);
    }

    /// @notice Pauses reward-related state-changing operations.
    /// @dev Functions guarded by `whenNotPaused` will revert while the contract is paused.
    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    /// @notice Unpauses the contract, re-enabling state-changing operations.
    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    /// @notice Advances the epoch: flushes pending rewards/penalties. Always advances the epoch marker.
    function advanceEpoch() external nonReentrant whenNotPaused {
        _stakeHeldK613();
        if (block.timestamp < lastEpochFlushAt + epochDuration) revert EpochNotReady();
        if (totalDeposits > 0) _distributePending();
        lastEpochFlushAt = block.timestamp;
        emit EpochAdvanced(block.timestamp);
    }

    /// @notice Returns the timestamp when the current epoch ends (or 0 if no epochs).
    function nextEpochAt() external view returns (uint256) {
        return lastEpochFlushAt + epochDuration;
    }

    function _updateUser(address user) internal {
        _distributePending();
        uint256 bal = balanceOf[user];
        uint256 accumulated = (bal * accRewardPerShare) / PRECISION;
        if (accumulated > userRewardDebt[user]) {
            userPendingRewards[user] += (accumulated - userRewardDebt[user]);
        }
        userRewardDebt[user] = accumulated;
    }

    function _distributePending() internal {
        if (totalDeposits == 0) return;
        if (pendingRewards > 0) {
            uint256 amount = pendingRewards;
            pendingRewards = 0;
            accRewardPerShare += (amount * PRECISION) / totalDeposits;
            emit RewardNotified(amount);
        }
        bool epochPassed = block.timestamp >= lastEpochFlushAt + epochDuration;
        bool shouldFlushPenalties = pendingPenalties >= MIN_PENALTY_FLUSH || (pendingPenalties > 0 && epochPassed);
        if (shouldFlushPenalties) {
            uint256 amount = pendingPenalties;
            pendingPenalties = 0;
            accRewardPerShare += (amount * PRECISION) / totalDeposits;
            emit RewardNotified(amount);
        }
    }

    /// @notice Returns pending rewards for an account.
    function pendingRewardsOf(address account) external view returns (uint256) {
        if (totalDeposits == 0) return userPendingRewards[account];
        uint256 accReward = accRewardPerShare;
        if (pendingRewards > 0) {
            accReward += (pendingRewards * PRECISION) / totalDeposits;
        }
        bool epochPassed = block.timestamp >= lastEpochFlushAt + epochDuration;
        bool wouldFlushPenalties = pendingPenalties >= MIN_PENALTY_FLUSH || (pendingPenalties > 0 && epochPassed);
        if (wouldFlushPenalties) {
            accReward += (pendingPenalties * PRECISION) / totalDeposits;
        }
        uint256 bal = balanceOf[account];
        uint256 accumulated = (bal * accReward) / PRECISION;
        uint256 pending = accumulated > userRewardDebt[account] ? accumulated - userRewardDebt[account] : 0;
        return userPendingRewards[account] + pending;
    }
}


--- Staking.sol ===
// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {AccessControl} from "openzeppelin-contracts/contracts/access/AccessControl.sol";
import {Pausable} from "openzeppelin-contracts/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

import {xK613} from "../token/xK613.sol";
import {RewardsDistributor} from "./RewardsDistributor.sol";

/**
 * @title K613 Staking
 * @author K613
 *
 * @notice
 * Shadow (xSHADOW)-inspired staking contract implementing a 1:1 conversion
 * between K613 and xK613 with an explicit exit queue and optional instant exit
 * penalty mechanism.
 *
 * @dev
 * DESIGN OVERVIEW
 * ---------------
 * This contract intentionally borrows the economic pattern of Shadow's xToken
 * staking model (receipt token + exit mechanics), while significantly reducing
 * system complexity and attack surface.
 *
 * Core principles:
 * - xK613 is a passive receipt token minted 1:1 on stake and burned on exit.
 * - No rebasing, governance, voting, or vesting logic is included.
 * - Rewards distribution is fully decoupled and handled externally via
 *   RewardsDistributor.
 *
 * SHADOW-INSPIRED ELEMENTS
 * -----------------------
 * - Receipt-token based staking (K613 → xK613).
 * - Exit delay enforced via an exit queue.
 * - Optional early exit with penalty (basis-points based).
 *
 * INTENTIONAL DIFFERENCES FROM SHADOW
 * ----------------------------------
 * - No automatic reward accrual or rebasing.
 * - No epoch-based accounting.
 * - No governance or voting power coupling.
 * - Exit requests escrow xK613 inside this contract, ensuring strict
 *   accounting and preventing double exits.
 *
 * SECURITY RATIONALE
 * ------------------
 * - Explicit state tracking via UserState prevents balance desynchronization.
 * - xK613 is transferred to this contract during exit requests and burned on exit,
 *   eliminating reliance on user balances at execution time.
 * - All external token transfers use SafeERC20.
 * - ReentrancyGuard is applied to all state-mutating user flows.
 *
 * ECONOMIC NOTES
 * --------------
 * - Instant exit penalties (if enabled) are transferred as K613 to the
 *   RewardsDistributor, increasing future reward weight for remaining stakers.
 * - Underlying K613 principal is never implicitly redistributed. xK613 is strictly 1:1 backed.
 *
 * This design preserves proven economic incentives from Shadow while favoring
 * auditability, explicit user intent, and minimal cross-contract coupling.
 */
///@author a.r.c.i.t.e.c.t
contract Staking is AccessControl, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public maxExitRequests;
    uint256 public constant MAX_BASIS_POINTS = 10_000;

    /// @notice Thrown when a zero address is passed where a non-zero address is required.
    error ZeroAddress();
    /// @notice Thrown when a zero amount is passed where a positive amount is required.
    error ZeroAmount();
    /// @notice Thrown when attempting to exit before the lock duration has passed.
    error Locked();
    /// @notice Thrown when attempting an instant exit after the lock duration has already passed.
    error Unlocked();
    /// @notice Thrown when the instant exit penalty basis points exceed MAX_BASIS_POINTS.
    error InvalidBps();
    /// @notice Thrown when an instant exit with a non-zero penalty is attempted without a rewards distributor set.
    error RewardsDistributorNotSet();
    /// @notice Thrown when the caller does not hold enough xK613 to cover the requested exit amount.
    error InsufficientxK613();
    /// @notice Thrown when there is no remaining staked amount available to initiate a new exit request.
    error NothingToInitiate();
    /// @notice Thrown when an invalid exit queue index is provided.
    error InvalidExitIndex();
    /// @notice Thrown when the user's exit queue has reached MAX_EXIT_REQUESTS.
    error ExitQueueFull();
    /// @notice Thrown when the requested exit amount exceeds the user’s staked balance.
    error AmountExceedsStake();
    /// @notice Thrown when lockDuration is zero.
    error InvalidLockDuration();
    /// @notice Thrown when maxExitRequests is zero.
    error InvalidMaxExitRequests();
    /// @notice Thrown when there is not enough system backing to redeem rewards.
    error InsufficientSystemBacking();
    /// @notice Thrown when attempting to redeem more xK613 than the caller's reward portion.
    error ExceedsRewardPortion();
    /// @notice Thrown when attempting to add a system staker that is already registered.
    error AlreadySystemStaker();
    /// @notice Thrown when attempting to remove a system staker that is not registered.
    error NotSystemStaker();

    /// @notice Exit request struct
    struct ExitRequest {
        uint256 amount;
        uint256 exitInitiatedAt;
    }

    /// @notice User state struct
    struct UserState {
        uint256 amount;
        ExitRequest[] exitQueue;
    }

    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    /// @notice Underlying token being staked
    IERC20 public immutable k613;
    /// @notice xK613 token minted on stake and burned on exit
    xK613 public immutable xk613;

    /// @notice Lock duration for standard exits
    uint256 public immutable lockDuration;
    /// @notice Penalty, in basis points, applied on instant exits before `lockDuration`
    uint256 public instantExitPenaltyBps;

    /// @notice Rewards distributor responsible for external reward accounting
    RewardsDistributor public rewardsDistributor;
    mapping(address => UserState) private _userState;
    /// @notice Total K613 backing active positions (staked minus exited)
    uint256 private _totalBacking;
    /// @notice System staker addresses (RD, Treasury) whose positions back reward xK613
    address[] private _systemStakers;
    /// @notice Whether an address is a registered system staker
    mapping(address => bool) public isSystemStaker;

    /// @notice Emitted when a user stakes K613
    event Staked(address indexed account, uint256 amount);
    /// @notice Emitted when a user initiates an exit request
    event ExitInitiated(address indexed account, uint256 index, uint256 amount, uint256 exitInitiatedAt);
    /// @notice Emitted when a user cancels an exit request
    event ExitCancelled(address indexed account, uint256 index);
    /// @notice Emitted when a user exits after the lock period
    event Exited(address indexed account, uint256 index, uint256 amount);
    /// @notice Emitted when a user performs an instant exit
    event InstantExit(address indexed account, uint256 index, uint256 amount, uint256 penalty);
    /// @notice Emitted when rewards distributor is updated
    event RewardsDistributorUpdated(address indexed distributor);
    /// @notice Emitted when instantExitPenaltyBps is updated
    event InstantExitPenaltyBpsUpdated(uint256 oldBps, uint256 newBps);
    event MaxExitRequestsUpdated(uint256 oldValue, uint256 newValue);
    /// @notice Emitted when a user redeems reward xK613 for K613
    event RewardsRedeemed(address indexed account, uint256 amount);
    /// @notice Emitted when a system staker is added or removed
    event SystemStakerUpdated(address indexed account, bool added);

    /// @notice Initializes the staking contract.
    /// @param k613Token Address of the K613 token to be staked.
    /// @param xk613Token Address of the xK613 token to be minted/burned on stake/exit.
    /// @param lockDuration_ Lock duration, in seconds, for standard exits.
    /// @param instantExitPenaltyBps_ Penalty in basis points for instant exits.
    constructor(address k613Token, address xk613Token, uint256 lockDuration_, uint256 instantExitPenaltyBps_) {
        if (k613Token == address(0) || xk613Token == address(0)) revert ZeroAddress();
        if (lockDuration_ == 0) revert InvalidLockDuration();
        if (instantExitPenaltyBps_ == 0 || instantExitPenaltyBps_ > MAX_BASIS_POINTS) revert InvalidBps();
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(PAUSER_ROLE, msg.sender);
        k613 = IERC20(k613Token);
        xk613 = xK613(xk613Token);
        lockDuration = lockDuration_;
        instantExitPenaltyBps = instantExitPenaltyBps_;
        maxExitRequests = 100;
    }

    /// @notice Sets the rewards distributor contract. Pass address(0) to disable; instant exit with penalty will revert until set.
    /// @param distributor Address of the rewards distributor.
    function setRewardsDistributor(address distributor) external onlyRole(DEFAULT_ADMIN_ROLE) {
        rewardsDistributor = RewardsDistributor(distributor);
        emit RewardsDistributorUpdated(distributor);
    }

    function MAX_EXIT_REQUESTS() external view returns (uint256) {
        return maxExitRequests;
    }

    /// @notice Returns the total deposited amount and exit queue for a user.
    /// @param user Address of the user.
    /// @return amount Total staked K613 amount for the user.
    /// @return exitQueue Array of exit requests for the user.
    function deposits(address user) external view returns (uint256 amount, ExitRequest[] memory exitQueue) {
        UserState storage s = _userState[user];
        amount = s.amount;
        exitQueue = s.exitQueue;
    }

    /// @notice Returns the length of the exit queue for a user.
    /// @param user Address of the user.
    /// @return Length of the exit queue.
    function exitQueueLength(address user) external view returns (uint256) {
        return _userState[user].exitQueue.length;
    }

    /// @notice Returns data for a specific exit request in a user's queue.
    /// @param user Address of the user.
    /// @param index Index of the exit request.
    /// @return amount Amount requested to exit.
    /// @return exitInitiatedAt Timestamp when the exit was initiated.
    function exitRequestAt(address user, uint256 index)
        external
        view
        returns (uint256 amount, uint256 exitInitiatedAt)
    {
        ExitRequest storage r = _userState[user].exitQueue[index];
        return (r.amount, r.exitInitiatedAt);
    }

    /// @notice Returns total K613 backing active positions (staked minus exited). For invariant: xK613.totalSupply() == totalBacking().
    function totalBacking() external view returns (uint256) {
        return _totalBacking;
    }

    /// @notice Computes the sum of all amounts pending exit for a user.
    /// @param user Address of the user.
    /// @return sum Total amount pending exit across the user's queue.
    function _exitPendingSum(address user) internal view returns (uint256 sum) {
        ExitRequest[] storage q = _userState[user].exitQueue;
        uint256 len = q.length;
        for (uint256 i = 0; i < len; ++i) {
            sum += q[i].amount;
        }
    }

    /// @notice Converts K613 to xK613 1:1 and mints to caller
    /// @param amount Amount of K613 to convert.
    function stake(uint256 amount) external nonReentrant whenNotPaused {
        if (amount == 0) revert ZeroAmount();

        UserState storage s = _userState[msg.sender];
        s.amount += amount;
        _totalBacking += amount;

        k613.safeTransferFrom(msg.sender, address(this), amount);
        xk613.mint(msg.sender, amount);

        emit Staked(msg.sender, amount);
    }

    /// @notice Initiates exit: pulls xK613 from caller and adds request to queue.
    /// @dev Caller must approve Staking for xK613. At most `maxExitRequests` per user.
    /// @param amount Amount of xK613 to schedule for exit.
    function initiateExit(uint256 amount) external nonReentrant whenNotPaused {
        if (amount == 0) revert ZeroAmount();

        UserState storage s = _userState[msg.sender];
        uint256 inQueue = _exitPendingSum(msg.sender);
        if (s.amount <= inQueue) revert NothingToInitiate();
        if (amount > s.amount - inQueue) revert AmountExceedsStake();
        // aderyn-ignore-next-line(reentrancy-state-change)
        if (xk613.balanceOf(msg.sender) < amount) revert InsufficientxK613();
        if (s.exitQueue.length >= maxExitRequests) revert ExitQueueFull();
        s.exitQueue.push(ExitRequest({amount: amount, exitInitiatedAt: block.timestamp}));
        IERC20(address(xk613)).safeTransferFrom(msg.sender, address(this), amount);

        emit ExitInitiated(msg.sender, s.exitQueue.length - 1, amount, block.timestamp);
    }

    /// @notice Cancels an exit request and returns xK613 to caller.
    /// @param index Index of the exit request in the caller's queue.
    function cancelExit(uint256 index) external nonReentrant whenNotPaused {
        UserState storage s = _userState[msg.sender];
        if (index >= s.exitQueue.length) revert InvalidExitIndex();

        uint256 amount = s.exitQueue[index].amount;
        _removeExitRequest(msg.sender, index);
        IERC20(address(xk613)).safeTransfer(msg.sender, amount);

        emit ExitCancelled(msg.sender, index);
    }

    /// @notice Executes an exit after the lock period: burns held xK613 and transfers K613 to caller.
    /// @param index Index of the exit request in the caller's queue.
    function exit(uint256 index) external nonReentrant whenNotPaused {
        UserState storage s = _userState[msg.sender];
        if (index >= s.exitQueue.length) revert InvalidExitIndex();

        ExitRequest storage req = s.exitQueue[index];
        if (block.timestamp < req.exitInitiatedAt + lockDuration) revert Locked();

        uint256 amount = req.amount;
        _removeExitRequest(msg.sender, index);
        s.amount -= amount;
        _totalBacking -= amount;

        xk613.burnFrom(address(this), amount);
        k613.safeTransfer(msg.sender, amount);

        emit Exited(msg.sender, index, amount);
    }

    /// @notice Instant exit before lock period; penalty goes to RewardsDistributor if set.
    /// @dev Requires rewardsDistributor when penalty > 0.
    /// @param index Index of the exit request in the caller's queue.
    function instantExit(uint256 index) external nonReentrant whenNotPaused {
        UserState storage s = _userState[msg.sender];
        if (index >= s.exitQueue.length) revert InvalidExitIndex();

        ExitRequest storage req = s.exitQueue[index];
        if (block.timestamp >= req.exitInitiatedAt + lockDuration) revert Unlocked();

        uint256 amount = req.amount;
        uint256 penalty = (amount * instantExitPenaltyBps + MAX_BASIS_POINTS - 1) / MAX_BASIS_POINTS;
        uint256 payout = amount - penalty;

        if (penalty > 0 && address(rewardsDistributor) == address(0)) revert RewardsDistributorNotSet();

        _removeExitRequest(msg.sender, index);
        s.amount -= amount;
        _totalBacking -= amount;

        xk613.burnFrom(address(this), amount);
        if (penalty > 0) {
            k613.safeTransfer(address(rewardsDistributor), penalty);
            rewardsDistributor.addPendingPenalty(penalty);
        }
        k613.safeTransfer(msg.sender, payout);

        emit InstantExit(msg.sender, index, amount, penalty);
    }

    /// @notice Removes an exit request from a user's queue by index.
    /// @dev Swaps with the last element and pops to keep the array compact.
    /// @param user Address of the user.
    /// @param index Index of the exit request to remove.
    function _removeExitRequest(address user, uint256 index) internal {
        UserState storage s = _userState[user];
        uint256 last = s.exitQueue.length - 1;
        if (index != last) {
            s.exitQueue[index] = s.exitQueue[last];
        }
        s.exitQueue.pop();
    }

    /// @notice Updates the instant exit penalty. Only callable by DEFAULT_ADMIN_ROLE.
    /// @param newBps New penalty in basis points. Must be > 0 and <= MAX_BASIS_POINTS.
    function setInstantExitPenaltyBps(uint256 newBps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newBps == 0 || newBps > MAX_BASIS_POINTS) revert InvalidBps();
        emit InstantExitPenaltyBpsUpdated(instantExitPenaltyBps, newBps);
        instantExitPenaltyBps = newBps;
    }

    function setMaxExitRequests(uint256 newValue) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newValue == 0) revert InvalidMaxExitRequests();
        emit MaxExitRequestsUpdated(maxExitRequests, newValue);
        maxExitRequests = newValue;
    }

    /// @notice Registers a system staker whose position backs reward xK613 (e.g. RewardsDistributor, Treasury).
    /// @param account Address to register.
    function addSystemStaker(address account) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (account == address(0)) revert ZeroAddress();
        if (isSystemStaker[account]) revert AlreadySystemStaker();
        isSystemStaker[account] = true;
        _systemStakers.push(account);
        emit SystemStakerUpdated(account, true);
    }

    /// @notice Removes a system staker.
    /// @param account Address to remove.
    function removeSystemStaker(address account) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (!isSystemStaker[account]) revert NotSystemStaker();
        isSystemStaker[account] = false;
        uint256 len = _systemStakers.length;
        for (uint256 i = 0; i < len; ++i) {
            if (_systemStakers[i] == account) {
                _systemStakers[i] = _systemStakers[len - 1];
                _systemStakers.pop();
                break;
            }
        }
        emit SystemStakerUpdated(account, false);
    }

    /// @notice Returns all registered system staker addresses.
    function getSystemStakers() external view returns (address[] memory) {
        return _systemStakers;
    }

    /// @notice Redeems reward xK613 for underlying K613, deducting from system staker positions.
    /// @dev Caller transfers xK613 to this contract, it is burned, and K613 is released from system backing.
    /// @param amount Amount of xK613 to redeem for K613.
    function redeemRewards(uint256 amount) external nonReentrant whenNotPaused {
        if (amount == 0) revert ZeroAmount();

        // H-02 FIX: only allow redeeming xK613 that exceeds the caller's own staking position.
        // Prevents stakers from bypassing exit penalties via redeemRewards.
        uint256 inQueueCaller = _exitPendingSum(msg.sender);
        uint256 ownPosition =
            _userState[msg.sender].amount > inQueueCaller ? _userState[msg.sender].amount - inQueueCaller : 0;
        // aderyn-fp-next-line(reentrancy-state-change)
        uint256 walletBalance = IERC20(address(xk613)).balanceOf(msg.sender);
        uint256 rewardPortion = walletBalance > ownPosition ? walletBalance - ownPosition : 0;
        if (amount > rewardPortion) revert ExceedsRewardPortion();

        uint256 remaining = amount;
        uint256 len = _systemStakers.length;
        for (uint256 i = 0; i < len && remaining > 0; ++i) {
            address sys = _systemStakers[i];
            uint256 inQueue = _exitPendingSum(sys);
            uint256 available = _userState[sys].amount > inQueue ? _userState[sys].amount - inQueue : 0;
            if (available == 0) continue;
            uint256 deduct = remaining > available ? available : remaining;
            // aderyn-fp-next-line(costly-loop)
            _userState[sys].amount -= deduct;
            remaining -= deduct;
        }
        if (remaining > 0) revert InsufficientSystemBacking();

        _totalBacking -= amount;
        IERC20(address(xk613)).safeTransferFrom(msg.sender, address(this), amount);
        xk613.burnFrom(address(this), amount);
        k613.safeTransfer(msg.sender, amount);

        emit RewardsRedeemed(msg.sender, amount);
    }

    /// @notice Pauses staking and exit operations.
    /// @dev Functions guarded by `whenNotPaused` will revert while the contract is paused.
    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    /// @notice Unpauses staking and exit operations.
    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }
}


--- xK613.sol ===
// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {AccessControl} from "openzeppelin-contracts/contracts/access/AccessControl.sol";
import {Pausable} from "openzeppelin-contracts/contracts/utils/Pausable.sol";

/// @title xK613
/// @notice Staking receipt token minted 1:1 on stake, burned on exit. Rewards via manual deposit in RewardsDistributor.
/// @dev Transfers restricted to whitelist. Minting/burning by MINTER_ROLE.
contract xK613 is ERC20, AccessControl, Pausable {
    /// @notice Thrown when a zero address is passed as a parameter.
    error ZeroAddress();
    /// @notice Thrown when a non-minter attempts to mint or burn tokens.
    error OnlyMinter();
    /// @notice Thrown when a transfer involves addresses not in the whitelist.
    error TransfersDisabled();

    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    /// @notice Current address authorized to mint and burn tokens.
    address public minter;
    /// @notice Mapping of addresses allowed to send and receive xK613.
    mapping(address => bool) public transferWhitelist;

    /// @notice Emitted when the minter address is updated.
    /// @param previousMinter The previous minter address.
    /// @param newMinter The new minter address.
    event MinterUpdated(address indexed previousMinter, address indexed newMinter);
    /// @notice Emitted when an address is added to or removed from the transfer whitelist.
    /// @param account The address whose whitelist status changed.
    /// @param allowed Whether the address is now whitelisted.
    event TransferWhitelistUpdated(address indexed account, bool allowed);

    /// @notice Deploys the xK613 token with the initial minter.
    /// @param initialMinter Address that will be granted MINTER_ROLE for minting and burning.
    constructor(address initialMinter) ERC20("xK613", "xK613") {
        if (initialMinter == address(0)) {
            revert ZeroAddress();
        }
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(PAUSER_ROLE, msg.sender);
        minter = initialMinter;
        _grantRole(MINTER_ROLE, initialMinter);
        emit MinterUpdated(address(0), initialMinter);
    }

    /// @notice Updates the minter address. Only callable by DEFAULT_ADMIN_ROLE.
    /// @param newMinter The new address to grant MINTER_ROLE.
    function setMinter(address newMinter) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newMinter == address(0)) {
            revert ZeroAddress();
        }
        _revokeRole(MINTER_ROLE, minter);
        emit MinterUpdated(minter, newMinter);
        minter = newMinter;
        _grantRole(MINTER_ROLE, newMinter);
    }

    /// @notice Adds or removes an address from the transfer whitelist.
    /// @param account Address to update.
    /// @param allowed True to allow transfers, false to disallow.
    function setTransferWhitelist(address account, bool allowed) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (account == address(0)) {
            revert ZeroAddress();
        }
        transferWhitelist[account] = allowed;
        emit TransferWhitelistUpdated(account, allowed);
    }

    /// @notice Mints new tokens to the specified address.
    /// @param to Recipient of the minted tokens.
    /// @param amount Amount of tokens to mint.
    function mint(address to, uint256 amount) external {
        if (!hasRole(MINTER_ROLE, msg.sender)) {
            revert OnlyMinter();
        }
        _mint(to, amount);
    }

    /// @notice Burns tokens from the specified address. Caller must have MINTER_ROLE.
    /// @param from Address to burn tokens from.
    /// @param amount Amount of tokens to burn.
    function burnFrom(address from, uint256 amount) external {
        if (!hasRole(MINTER_ROLE, msg.sender)) {
            revert OnlyMinter();
        }
        _burn(from, amount);
    }

    /// @notice Pauses all token transfers. Only callable by PAUSER_ROLE.
    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    /// @notice Resumes token transfers. Only callable by PAUSER_ROLE.
    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    /// @dev Overrides _update: enforce whitelist and pause.
    function _update(address from, address to, uint256 value) internal override {
        _requireNotPaused();
        if (from != address(0) && to != address(0)) {
            if (!transferWhitelist[from] && !transferWhitelist[to]) {
                revert TransfersDisabled();
            }
        }
        super._update(from, to, value);
    }
}


