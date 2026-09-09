// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IClubPool} from "./interfaces/IClubPool.sol";
import {IPool} from "@aave/core-v3/contracts/interfaces/IPool.sol";
import {IAToken} from "@aave/core-v3/contracts/interfaces/IAToken.sol";
import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {IWETH} from "./interfaces/IWETH.sol";
import {console2} from "forge-std/console2.sol";

/// @title ClubPool Contract
/// @notice Implements the ClubPool functionality

contract ClubPool is IClubPool, ERC721 {
    using SafeERC20 for IERC20;

    struct EpochData {
        uint256 usdcBonus; // The amount of USDC bonus deposited for the epoch
        uint256 ethBonus; // The amount of ETH bonus deposited for the epoch
        uint256 compliantAthleteCount; // The number of compliant athletes in the epoch
        uint256 totalDepositByCompliant; // The total deposit amount by compliant athletes in the epoch
        uint256 totalDeposited; // Total USDC deposited by all athletes at epoch start
        uint256 startTime; // Timestamp when the epoch started
        uint256 endTime; // Timestamp when the epoch ended
    }

    struct Athlete {
        uint256 joinedAt; // The timestamp when the athlete joined the club
        uint256 stakedAmount; // The amount of USDC staked by the athlete
        uint256 tokenId; // The token ID of the athlete 
    }

    uint256 public epochDuration;
    address public owner;

    uint256 public currentEpoch;
    uint256 public currentEpochStartTime;

    uint256 public totalUsdcDeposited;
    uint256 public unclaimedUsdcYield;
    uint256 public totalEthDeposited;
    uint256 public unclaimedEthYield;

    uint256 public totalUsdcBonus;
    uint256 public totalWethBonus;

    uint256 private _currentTokenId;
    uint256 public membershipFee;
    IWETH public weth;
    IERC20 public usdc;
    IAToken public aWETH;
    IAToken public aUSDC;
    IPool public aavePool;

    mapping(address walletAddress => Athlete athlete) public athletes;
    mapping(uint256 epoch => EpochData epochData) public epochs;
    mapping(uint256 epoch => mapping(address athlete => bool compliant)) public epochAthleteCompliance;
    mapping(uint256 epoch => mapping(address athlete => uint256 stake)) public epochAthleteStake;
    mapping(address athlete => mapping(uint256 epoch => bool claimed)) public claimedBonuses;
    mapping(address reporter => bool isReporter) public reporters;

    modifier onlyOwner() {
        require(msg.sender == owner, "Not the Owner");
        _;
    }

    modifier onlyOwnerOrReporter() {
        require(msg.sender == owner || reporters[msg.sender], "Not authorized");
        _;
    }

    constructor(
        address _usdc,
        uint256 _epochDuration,
        address _owner,
        address _aavePool,
        address _aUSDC,
        address _weth,
        address _aWETH,
        uint256 _membershipFee
    ) ERC721("ClubPool Membership", "CPM") {
        usdc = IERC20(_usdc);
        epochDuration = _epochDuration;
        owner = _owner;
        currentEpoch = 1;
        currentEpochStartTime = block.timestamp;
        aavePool = IPool(_aavePool);
        aUSDC = IAToken(_aUSDC);
        weth = IWETH(_weth);
        aWETH = IAToken(_aWETH);
        membershipFee = _membershipFee;
    }

    function setMembershipFee(uint256 _newFee) external onlyOwner {
        uint256 oldFee = membershipFee;
        membershipFee = _newFee;
        emit MembershipFeeChanged(oldFee, _newFee);
    }

    function mint() external payable {
        require(msg.value == membershipFee, "Incorrect membership fee");
        require(balanceOf(msg.sender) == 0, "Already a member");

        // Increment the token ID
        _currentTokenId++;
        uint256 newTokenId = _currentTokenId;
        _safeMint(msg.sender, newTokenId);

        athletes[msg.sender] = Athlete({joinedAt: block.timestamp, stakedAmount: 0, tokenId: newTokenId});

        // Update total deposited amount
        totalEthDeposited += msg.value;

        // Wrap ETH to WETH
        weth.deposit{value: msg.value}();

        // Approve and supply WETH to Aave
        weth.approve(address(aavePool), msg.value);
        aavePool.supply(address(weth), msg.value, address(this), 0);

        emit Joined(msg.sender);
    }

    function stake(uint256 amount) external {
        require(balanceOf(msg.sender) > 0, "Not a member");
        require(amount > 0, "Stake amount must be greater than zero");

        _stake(amount);
    }

    function _stake(uint256 amount) internal {
        usdc.safeTransferFrom(msg.sender, address(this), amount);

        // Approve Aave to spend USDC
        usdc.approve(address(aavePool), amount);

        // Deposit USDC into Aave
        aavePool.supply(address(usdc), amount, address(this), 0);

        // Update user's stake
        athletes[msg.sender].stakedAmount += amount;

        // Update total deposited amount
        totalUsdcDeposited += amount;

        emit Staked(msg.sender, amount);
    }

    function unstake(uint256 amount) external {
        require(balanceOf(msg.sender) > 0, "Not a member");
        uint256 amountStaked = athletes[msg.sender].stakedAmount;
        require(amountStaked >= amount, "Insufficient staked amount");

        // Update the staked amount before transferring
        athletes[msg.sender].stakedAmount -= amount;

        // Update total deposited amount
        totalUsdcDeposited -= amount;

        // Withdraw USDC from Aave
        aavePool.withdraw(address(usdc), amount, address(this));

        usdc.safeTransfer(msg.sender, amount);

        emit Unstaked(msg.sender, amount);
    }

    function ownerUnstake(address athlete, uint256 amount) external onlyOwner {
        require(balanceOf(athlete) > 0, "Not a member");
        uint256 amountStaked = athletes[athlete].stakedAmount;
        require(amountStaked >= amount, "Insufficient staked amount");

        // Update the staked amount before transferring
        athletes[athlete].stakedAmount -= amount;

        // Update total deposited amount
        totalUsdcDeposited -= amount;

        // Withdraw USDC from Aave
        aavePool.withdraw(address(usdc), amount, address(this));

        usdc.safeTransfer(athlete, amount);

        emit OwnerUnstaked(athlete, amount);
    }

    function setReporter(address reporter, bool isReporter) external onlyOwner {
        reporters[reporter] = isReporter;
        emit ReporterStatusChanged(reporter, isReporter);
    }

    function recordActivity(address athlete, bool compliant, uint256 epoch) external onlyOwnerOrReporter {
        require(epoch == currentEpoch, "Invalid epoch");

        uint256 stakeAmount = athletes[athlete].stakedAmount;

        // Ignore athletes with zero stake
        if (stakeAmount == 0) {
            return;
        }

        bool previousCompliance = epochAthleteCompliance[epoch][athlete];
        epochAthleteCompliance[epoch][athlete] = compliant;

        if (compliant && !previousCompliance) {
            // Athlete is being marked compliant
            epochs[epoch].compliantAthleteCount++;

            // Record the athlete's stake amount at this moment
            epochAthleteStake[epoch][athlete] = stakeAmount;

            // Update total deposits by compliant athletes
            epochs[epoch].totalDepositByCompliant += stakeAmount;
        } else if (!compliant && previousCompliance) {
            // Athlete is being marked non-compliant
            epochs[epoch].compliantAthleteCount--;

            // Remove their stake amount from total deposits by compliant athletes
            epochs[epoch].totalDepositByCompliant -= stakeAmount;

            // Reset the recorded stake amount
            epochAthleteStake[epoch][athlete] = 0;
        }

        emit ActivityRecorded(athlete, compliant, epoch);
    }

    function claimBonus(uint256 epoch) external {
        require(epoch < currentEpoch, "Cannot claim bonus for current or future epochs");
        require(!claimedBonuses[msg.sender][epoch], "Bonus already claimed for this epoch");
        require(epochAthleteCompliance[epoch][msg.sender], "Not compliant in the specified epoch");

        EpochData storage epochData = epochs[epoch];
        uint256 athleteStake = epochAthleteStake[epoch][msg.sender];
        uint256 totalDeposits = epochData.totalDepositByCompliant;
        require(totalDeposits > 0, "Total deposits by compliant athletes is zero");

        uint256 usdcBonusAmount = (epochData.usdcBonus * athleteStake) / totalDeposits;
        uint256 ethBonusAmount = (epochData.ethBonus * athleteStake) / totalDeposits;


        require(aUSDC.balanceOf(address(this)) >= usdcBonusAmount, "Insufficient USDC balance to pay bonus");
        require(aWETH.balanceOf(address(this)) >= ethBonusAmount, "Insufficient WETH balance to pay bonus");

        // Mark bonus as claimed
        claimedBonuses[msg.sender][epoch] = true;

        // Deduct the claimed amounts from the unclaimed yield checkpoints
        unclaimedUsdcYield -= usdcBonusAmount;
        unclaimedEthYield -= ethBonusAmount;

        aavePool.withdraw(address(usdc), usdcBonusAmount, msg.sender);
        aavePool.withdraw(address(weth), ethBonusAmount, msg.sender);

        emit BonusClaimed(msg.sender, usdcBonusAmount, ethBonusAmount, epoch);
    }

    function endEpoch() external {
        require(block.timestamp >= currentEpochStartTime + epochDuration, "Epoch duration not reached");

        uint256 endingEpoch = currentEpoch;
        EpochData storage epochData = epochs[endingEpoch];

        // Calculate USDC yield
        uint256 currentUsdcBalance = aUSDC.balanceOf(address(this));
        uint256 usdcYieldAmount = currentUsdcBalance - totalUsdcDeposited - unclaimedUsdcYield;

        // Calculate ETH yield
        uint256 currentEthBalance = aWETH.balanceOf(address(this));
        uint256 ethYieldAmount = currentEthBalance - totalEthDeposited - unclaimedEthYield;

        // Update state variables
        totalUsdcBonus += usdcYieldAmount;
        totalWethBonus += ethYieldAmount;
        epochData.usdcBonus = usdcYieldAmount;
        epochData.ethBonus = ethYieldAmount;
        epochData.totalDeposited = totalUsdcDeposited;  // Record total deposits at epoch end
        epochData.endTime = block.timestamp;  // Record end time
        
        // Start new epoch
        currentEpoch++;
        currentEpochStartTime = block.timestamp;
        epochs[currentEpoch].startTime = block.timestamp;  // Record start time for new epoch
        unclaimedUsdcYield = currentUsdcBalance - totalUsdcDeposited;
        unclaimedEthYield = currentEthBalance - totalEthDeposited;

        // Emit events
        emit BonusDeposited(endingEpoch, usdcYieldAmount, ethYieldAmount);
        emit EpochEnded(endingEpoch, epochData.compliantAthleteCount);
    }

    function getBalance(address athlete) external view returns (uint256) {
        return athletes[athlete].stakedAmount;
    }

    function getDepositYieldSinceLastCheckpoint() public view returns (uint256) {
        uint256 currentBalance = IERC20(address(aUSDC)).balanceOf(address(this));
        return currentBalance > (totalUsdcDeposited + unclaimedUsdcYield)
            ? currentBalance - totalUsdcDeposited - unclaimedUsdcYield
            : 0;
    }

    function getEthYieldSinceLastCheckpoint() public view returns (uint256) {
        uint256 currentBalance = IERC20(address(aWETH)).balanceOf(address(this));
        return currentBalance > (totalEthDeposited + unclaimedEthYield)
            ? currentBalance - totalEthDeposited - unclaimedEthYield
            : 0;
    }

    function transferFrom(address, address, uint256) public virtual override {
        revert("Memberships are not transferrable");
    }

    function burn(uint256 tokenId) external onlyOwner {
        _burn(tokenId);
    }

    function withdrawMembershipFees(uint256 amount) external onlyOwner {
        // All ETH deposited is club revenue, so subtract totalWethBonus to get the amount available to withdraw
        uint256 withdrawableAmount = aWETH.balanceOf(address(this)) - totalWethBonus;
        require(withdrawableAmount > 0, "No fees available to withdraw");
        require(amount <= withdrawableAmount, "Amount exceeds available fees");

        totalEthDeposited -= amount;

        aavePool.withdraw(address(weth), amount, address(this));

        // Transfer WETH to the owner
        require(weth.transfer(owner, amount), "WETH transfer failed");

        emit MembershipFeesWithdrawn(owner, amount);
    }

    function getCurrentEpochComplianceStatus(address athlete) external view returns (bool) {
        return epochAthleteCompliance[currentEpoch][athlete];
    }

    function getCurrentEpochCompliantAthleteCount() external view returns (uint256) {
        return epochs[currentEpoch].compliantAthleteCount;
    }

    receive() external payable {}

}