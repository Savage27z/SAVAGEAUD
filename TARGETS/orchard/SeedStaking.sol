// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

//
//                         ,(
//                        ((
//                         \\
//                     .---\\---.
//                    /    ``    \
//                   |            |
//                   |            |
//                    \          /
//                     '.______.'
//
//              O R C H A R D  ·  $SEED
//             Plant ETH. Harvest $AAPL.
//
//                https://orchard.gold
//            https://x.com/orcharddotgold
//

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IStaking} from "./interfaces/IStaking.sol";

contract SeedStaking is IStaking, ReentrancyGuard {
    using SafeERC20 for IERC20;

    error ZeroAmount();
    error InsufficientStake();
    error NothingToClaim();
    error ZeroAddress();

    event Staked(address indexed account, uint256 amount);
    event Unstaked(address indexed account, uint256 amount);
    event RewardClaimed(address indexed account, uint256 amount);
    event RewardNotified(address indexed from, uint256 amount);

    uint256 private constant INDEX_SCALE = 1e18;
    uint256 public constant MIN_RELEASE_STAKE = 10_000e18;

    IERC20 public immutable seed;
    IERC20 public immutable aapl;

    uint256 public totalStaked;
    mapping(address => uint256) public stakedOf;
    uint256 public rewardIndex;
    mapping(address => uint256) public indexOf;
    mapping(address => uint256) public accruedOf;
    uint256 public pendingReward;

    constructor(IERC20 seed_, IERC20 aapl_) {
        if (address(seed_) == address(0) || address(aapl_) == address(0)) revert ZeroAddress();
        seed = seed_;
        aapl = aapl_;
    }

    function stake(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        _checkpoint(msg.sender);
        uint256 balanceBefore = seed.balanceOf(address(this));
        seed.safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = seed.balanceOf(address(this)) - balanceBefore;
        totalStaked += received;
        stakedOf[msg.sender] += received;
        emit Staked(msg.sender, received);
    }

    function unstake(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (stakedOf[msg.sender] < amount) revert InsufficientStake();
        _checkpoint(msg.sender);
        totalStaked -= amount;
        stakedOf[msg.sender] -= amount;
        seed.safeTransfer(msg.sender, amount);
        emit Unstaked(msg.sender, amount);
    }

    function claimReward() external nonReentrant {
        _checkpoint(msg.sender);
        uint256 amount = accruedOf[msg.sender];
        if (amount == 0) revert NothingToClaim();
        accruedOf[msg.sender] = 0;
        aapl.safeTransfer(msg.sender, amount);
        emit RewardClaimed(msg.sender, amount);
    }

    function notifyReward(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        aapl.safeTransferFrom(msg.sender, address(this), amount);
        if (totalStaked < MIN_RELEASE_STAKE) {
            pendingReward += amount;
        } else {
            uint256 total = amount + pendingReward;
            uint256 delta = (total * INDEX_SCALE) / totalStaked;
            if (delta == 0) {
                pendingReward = total;
            } else {
                rewardIndex += delta;
                pendingReward = 0;
            }
        }
        emit RewardNotified(msg.sender, amount);
    }

    function earned(address account) external view returns (uint256) {
        return accruedOf[account] + (stakedOf[account] * (rewardIndex - indexOf[account])) / INDEX_SCALE;
    }

    function _checkpoint(address account) private {
        accruedOf[account] += (stakedOf[account] * (rewardIndex - indexOf[account])) / INDEX_SCALE;
        indexOf[account] = rewardIndex;
    }
}
