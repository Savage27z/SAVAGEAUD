// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/**
 * @title ILending
 * @notice Collateralised lending against a live term deposit.
 *
 * Borrowing capital is disbursed from, and principal repayments returned
 * to, the borrower's own SafeVault deposit slice (the collateral). Loan
 * interest is booked to the Treasury's interest reserve on repayment. The
 * deposit stays open while the loan is outstanding; on settlement, liquidation
 * or self-paying-netting, the loan is reconciled before any user payout.
 */
interface ILending {
    struct Loan {
        address borrower;
        uint256 principal;
        uint256 accruedInterest;
        uint64 openedAt;
        uint64 lastAccruedAt;
        bool open;
    }

    event LoanOpened(uint256 indexed depositId, address indexed borrower, uint256 amount);
    event LoanRepaid(uint256 indexed depositId, address indexed borrower, uint256 amount);
    event LoanAccrued(uint256 indexed depositId, uint256 newlyAccrued);
    event LoanLiquidated(
        uint256 indexed depositId,
        address indexed liquidator,
        uint256 debtCancelled,
        uint256 collateralSeized,
        uint256 liquidatorBonus
    );
    event SelfPayingNettingApplied(uint256 indexed depositId, uint256 interestNetted);
    // §Code-Review N4 - loan closed atomically out of settlement proceeds
    // (principal absorbed by the SafeVault claim, interest withheld from the
    // Treasury payout). No external USDC was needed from the borrower.
    event LoanNetSettled(
        uint256 indexed depositId,
        address indexed borrower,
        uint256 principalRepaid,
        uint256 interestRepaid
    );
    event ParameterUpdated(bytes32 indexed key, uint256 value);

    function openLoan(uint256 depositId, uint256 amount) external;

    function openLoanForBorrower(address borrower, uint256 depositId, uint256 amount, address recipient) external;

    function openLoanForCyr(uint256 depositId, uint256 amount, address recipient) external returns (address borrower);

    // §V6.3 Turbo loop - Turbo-orchestrator-only borrow against Turbo rungs.
    function openLoanForTurboLoop(uint256 depositId, uint256 amount, address recipient) external returns (address borrower);

    function setTurboLoopContract(address turboLoop) external;

    function maxLtvBps() external view returns (uint256);

    function availableBorrowCapacity(uint256 depositId) external view returns (uint256 capacity);

    // §V6.2 - CYR-only capacity view that ignores the Turbo
    // user-borrow guard. The user-facing `availableBorrowCapacity`
    // masks Turbo deposits to zero; the CYR auto-compound paths
    // need real capacity so the Turbo leverage leg can fund.
    function internalBorrowCapacity(uint256 depositId) external view returns (uint256 capacity);

    function repayLoan(uint256 depositId, uint256 amount) external;

    function repayFull(uint256 depositId) external;

    function accrueLoan(uint256 depositId) external returns (uint256 newlyAccrued);

    function liquidate(uint256 depositId) external returns (uint256 collateralSeized);

    function loanOf(uint256 depositId) external view returns (Loan memory loan);

    // §Phase 2 Marketplace - borrower migration on secondary sale.
    function setMarketplace(address marketplace_) external;

    function marketplace() external view returns (address);

    function migrateBorrower(uint256 depositId, address newBorrower) external;

    function currentLtvBps(uint256 depositId) external view returns (uint256 ltvBps);

    function netInterestAgainstLoan(uint256 depositId, uint256 depositInterestAvailable)
        external
        returns (uint256 netted);

    // §Code-Review N4 - BondContract-only: nets remaining bond interest, then
    // closes the loan against the settlement proceeds and reports what must
    // be withheld from the payout (loan principal, loan interest).
    function closeLoanForSettlement(uint256 depositId)
        external
        returns (uint256 principalOwed, uint256 interestOwed);
}
