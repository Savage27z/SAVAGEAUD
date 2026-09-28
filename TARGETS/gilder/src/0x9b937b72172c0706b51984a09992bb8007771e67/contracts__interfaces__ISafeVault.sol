// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

interface ISafeVault {
    event PrincipalAccounted(uint256 indexed depositId, uint256 amount);
    event PrincipalReleased(uint256 indexed depositId, address indexed recipient, uint256 amount);
    event LoanDisbursed(uint256 indexed depositId, address indexed borrower, uint256 amount);
    event LoanRepaymentAccepted(uint256 indexed depositId, address indexed from, uint256 amount);
    event CollateralForfeited(uint256 indexed depositId, address indexed liquidator, uint256 forfeited, uint256 outstandingCleared, uint256 liquidatorBonus);
    event EarlyExitReleased(uint256 indexed depositId, address indexed recipient, uint256 userPayout, uint256 retainedBuffer);
    // §Code-Review N4 - net settlement cleared the outstanding loan against
    // the deposit's own claim (accounting-only, no USDC moved).
    event LoanNetSettledAtVault(uint256 indexed depositId, uint256 outstandingCleared);

    function accountedPrincipal() external view returns (uint256 amount);

    function accountPrincipal(uint256 depositId, uint256 amount) external;

    function releasePrincipal(uint256 depositId, address recipient, uint256 amount) external;

    function principalOf(uint256 depositId) external view returns (uint256 amount);

    function loanedAgainst(uint256 depositId) external view returns (uint256 amount);

    function availableForLoan(uint256 depositId) external view returns (uint256 amount);

    function disburseLoan(uint256 depositId, address borrower, uint256 amount) external;

    function acceptRepayment(uint256 depositId, address from, uint256 amount) external;

    function noteRepayment(uint256 depositId, address from, uint256 amount) external;

    function forfeitCollateral(uint256 depositId, address depositor, address liquidator, uint256 liquidatorBonus) external returns (uint256 forfeited, uint256 outstandingCleared);

    // §Code-Review N4 - atomic net-settlement: clears the outstanding loan
    // against the deposit's own SafeVault claim without moving USDC.
    function netSettleLoan(uint256 depositId) external returns (uint256 outstandingCleared);

    function earlyExitRelease(uint256 depositId, address recipient, uint256 userPayout) external returns (uint256 retainedBuffer);

    function protocolBuffer() external view returns (uint256);
}
