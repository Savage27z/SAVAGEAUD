// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IRevenueBond
/// @notice Tokenized claims on agent revenue streams
/// @dev Agents with verified cash flows issue bonds. Human investors buy yield.
interface IRevenueBond {
    enum BondStatus {
        Active,
        Matured,
        Defaulted,
        Cancelled
    }

    struct Bond {
        uint256 id;
        address agent;               // Issuing agent
        address revenueSource;        // Contract generating revenue
        uint256 principal;            // Total capital raised
        uint256 filled;               // Amount purchased so far
        uint256 couponBps;            // Annual yield in bps
        uint256 maturityBlock;        // Block when bond matures
        uint256 issuedBlock;          // Block when bond was issued
        uint256 totalCouponPaid;      // Cumulative coupon distributed
        BondStatus status;
    }

    /// @notice Issue a new revenue bond
    function issueBond(
        address revenueSource,
        uint256 principal,
        uint256 couponBps,
        uint256 durationBlocks
    ) external returns (uint256 bondId);

    /// @notice Purchase bond tokens with USDC
    function purchase(uint256 bondId, uint256 amount) external returns (uint256 tokens);

    /// @notice Claim accrued coupon payments
    function claimCoupon(uint256 bondId) external returns (uint256 payout);

    /// @notice Redeem principal at maturity
    function redeem(uint256 bondId) external returns (uint256 principal);

    /// @notice Service debt from escrowed revenue
    function serviceDebt(uint256 bondId) external;

    event BondIssued(uint256 indexed bondId, address indexed agent, uint256 principal, uint256 couponBps);
    event BondPurchased(uint256 indexed bondId, address indexed buyer, uint256 amount);
    event CouponPaid(uint256 indexed bondId, uint256 totalPaid);
    event BondMatured(uint256 indexed bondId);
    event BondDefaulted(uint256 indexed bondId);
    event Paused(address indexed account);
    event Unpaused(address indexed account);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
}
