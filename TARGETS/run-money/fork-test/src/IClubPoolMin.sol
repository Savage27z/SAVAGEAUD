// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IERC20Min {
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
}

// Minimal interface for interacting with the ALREADY-DEPLOYED ClubPool on a Base fork.
// We do not redeploy ClubPool - we call the real contract at its real address, so this
// only needs to match the ABI, not pull in ClubPool's own OZ/Aave dependency tree.
interface IClubPoolMin {
    function mint() external payable;
    function stake(uint256 amount) external;
    function unstake(uint256 amount) external;
    function recordActivity(address athlete, bool compliant, uint256 epoch) external;
    function claimBonus(uint256 epoch) external;
    function endEpoch() external;

    function owner() external view returns (address);
    function membershipFee() external view returns (uint256);
    function currentEpoch() external view returns (uint256);
    function currentEpochStartTime() external view returns (uint256);
    function epochDuration() external view returns (uint256);
    function athletes(address) external view returns (uint256 joinedAt, uint256 stakedAmount, uint256 tokenId);
    function epochAthleteStake(uint256 epoch, address athlete) external view returns (uint256);
    function epochAthleteCompliance(uint256 epoch, address athlete) external view returns (bool);
    function balanceOf(address) external view returns (uint256); // ERC721 membership count
}
