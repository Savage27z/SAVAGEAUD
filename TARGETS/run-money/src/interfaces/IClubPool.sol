// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAToken} from "@aave/core-v3/contracts/interfaces/IAToken.sol";
import {IPool} from "@aave/core-v3/contracts/interfaces/IPool.sol";
import {IWETH} from "./IWETH.sol";

interface IClubPool {
    event Joined(address indexed member);
    event Staked(address indexed member, uint256 amount);
    event Unstaked(address indexed member, uint256 amount);
    event OwnerUnstaked(address indexed athlete, uint256 amount);
    event ActivityRecorded(address indexed athlete, bool compliant, uint256 epoch);
    event BonusDeposited(uint256 indexed epoch, uint256 usdcAmount, uint256 ethAmount);
    event EpochEnded(uint256 indexed epoch, uint256 compliantAthleteCount);
    event BonusClaimed(address indexed athlete, uint256 usdcAmount, uint256 ethAmount, uint256 epoch);
    event ReporterStatusChanged(address indexed reporter, bool isReporter);
    event MembershipFeesWithdrawn(address indexed owner, uint256 amount);
    event MembershipFeeChanged(uint256 oldFee, uint256 newFee);

    function epochDuration() external view returns (uint256);
    function owner() external view returns (address);
    function currentEpoch() external view returns (uint256);
    function currentEpochStartTime() external view returns (uint256);
    function totalUsdcDeposited() external view returns (uint256);
    function unclaimedUsdcYield() external view returns (uint256);
    function totalEthDeposited() external view returns (uint256);
    function unclaimedEthYield() external view returns (uint256);
    function totalUsdcBonus() external view returns (uint256);
    function totalWethBonus() external view returns (uint256);
    function membershipFee() external view returns (uint256);
    function weth() external view returns (IWETH);
    function usdc() external view returns (IERC20);
    function aWETH() external view returns (IAToken);
    function aUSDC() external view returns (IAToken);
    function aavePool() external view returns (IPool);

    // function athletes(address walletAddress) external view returns (uint256 joinedAt, uint256 stakedAmount, uint256 tokenId);
    // function epochs(uint256 epoch) external view returns (uint256 startTime, uint256 endTime, uint256 totalStaked, uint256 bonusPoolUsdc, uint256 bonusPoolEth);
    function epochAthleteCompliance(uint256 epoch, address athlete) external view returns (bool);
    function epochAthleteStake(uint256 epoch, address athlete) external view returns (uint256);
    // function claimedBonuses(address athlete, uint256 epoch) external view returns (bool);
    // function reporters(address reporter) external view returns (bool);

    function setMembershipFee(uint256 _newFee) external;
    function mint() external payable;
    function stake(uint256 amount) external;
    function unstake(uint256 amount) external;
    function setReporter(address reporter, bool isReporter) external;
    function recordActivity(address athlete, bool compliant, uint256 epoch) external;
    function claimBonus(uint256 epoch) external;
    function endEpoch() external;
    function getBalance(address athlete) external view returns (uint256);
    function getDepositYieldSinceLastCheckpoint() external view returns (uint256);
    function getEthYieldSinceLastCheckpoint() external view returns (uint256);
    function burn(uint256 tokenId) external;
    function withdrawMembershipFees(uint256 amount) external;
    function getCurrentEpochComplianceStatus(address athlete) external view returns (bool);
    function getCurrentEpochCompliantAthleteCount() external view returns (uint256);
}