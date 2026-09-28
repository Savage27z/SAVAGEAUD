// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

interface ITreasury {
    event TreasuryAllocationReceived(uint256 indexed depositId, uint256 amount);
    event SettlementPaid(uint256 indexed depositId, address indexed recipient, uint256 amount);
    event EarlyExitPenaltyRecorded(uint256 indexed depositId, uint256 amount);
    event ReserveBucketsUpdated(uint256 interestReserve, uint256 buybackReserve, uint256 operationalReserve);
    event LoanCapitalDisbursed(uint256 indexed depositId, address indexed borrower, uint256 amount);
    event LoanCapitalReturned(uint256 indexed depositId, uint256 principalReturned, uint256 interestReturned);
    event SolvencyFloorUpdated(uint256 newFloor);
    event ReserveBpsUpdated(uint256 interestBps, uint256 buybackBps, uint256 operationalBps);
    event MarketingEngineUpdated(address engine);
    event CoverageTargetsUpdated(uint256 interestRequired, uint256 buybackRequired);
    event PremiumProfitProcessed(
        uint256 amount,
        uint256 toInterestReserve,
        uint256 toBuybackReserve,
        uint256 toTreasury,
        uint256 toMarketing
    );
    event MarketingClaimPaid(address indexed to, uint256 amount);
    // §Code-Review H4 - an abandoned-deposit decay fee was booked into the
    // marketing budget (spendable only via the capped `claimMarketing` path).
    event MarketingDecayCredited(uint256 indexed depositId, uint256 amount, uint256 marketingClaimable);
    event DeficitPulled(uint256 pulled, uint256 interestReserve, uint256 buybackReserve, uint256 operationalReserve);

    function receiveAllocation(uint256 depositId, uint256 amount) external;

    function paySettlement(uint256 depositId, address recipient, uint256 amount) external;

    function recordEarlyExitPenalty(uint256 depositId, uint256 amount) external;

    function creditEarlyExitPenalty(uint256 depositId, uint256 amount) external;

    function processPremiumProfit(uint256 amount) external;

    function pullDeficit() external returns (uint256 pulled);

    function registerActivePrincipal(uint256 amount) external;

    function unregisterActivePrincipal(uint256 amount) external;

    function totalActivePrincipal() external view returns (uint256);

    function interestCoverageTarget() external view returns (uint256);

    function effectiveCoverageRequired() external view returns (uint256);

    function claimMarketing(address to, uint256 amount) external;

    // §Code-Review H4 - BondContract books a decay fee into the marketing
    // budget so it is spendable only through the capped claim path.
    function creditMarketingFromDecay(uint256 depositId, uint256 amount) external;

    function treasuryValuePerToken(uint256 circulatingSupply) external view returns (uint256 tvt);

    function disburseLoanCapital(uint256 depositId, address borrower, uint256 amount) external;

    function returnLoanCapital(uint256 depositId, uint256 principalPortion, uint256 interestPortion) external;

    function totalAllocated() external view returns (uint256);

    function interestReserve() external view returns (uint256);

    function buybackReserve() external view returns (uint256);

    function operationalReserve() external view returns (uint256);

    function marketingClaimable() external view returns (uint256);

    function interestCoverageRequired() external view returns (uint256);
}
