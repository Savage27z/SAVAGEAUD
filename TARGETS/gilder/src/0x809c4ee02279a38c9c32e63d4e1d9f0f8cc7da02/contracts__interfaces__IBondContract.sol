// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IGilderTypes} from "./IGilderTypes.sol";

interface IBondContract is IGilderTypes {
    event DepositOpened(uint256 indexed depositId, address indexed owner, uint256 principal);
    event DepositStateChanged(uint256 indexed depositId, DepositState state);
    event DepositSettled(uint256 indexed depositId, address indexed owner, uint256 principalPaid, uint256 interestPaid);
    event EarlyExit(uint256 indexed depositId, address indexed owner, uint256 userPayout, uint256 penalty);
    event AbandonedFeeAssessed(uint256 indexed depositId, uint256 feeAmount, uint256 elapsedMonths);
    event CapitalRouted(
        uint256 indexed depositId,
        uint256 safeVaultAmount,
        uint256 tokenBuyAmount,
        uint256 treasuryAmount,
        uint256 liquidityAmount
    );
    event DepositValidationFlagsSet(bool depositsEnabled, bool pegOk);
    event LoanStateUpdated(uint256 indexed depositId, uint256 loanBalance, uint256 loanAccruedInterest);
    event LoanCollateralSeized(uint256 indexed depositId, address indexed liquidator, uint256 collateralAmount);
    event GovernanceParameterSet(bytes32 indexed key, uint256 value);
    // §V6.2 - fired whenever `setCompoundMode` mutates a deposit's
    // auto-compound flag. Indexed by depositId so backend listeners can
    // filter cheaply. Emitted by BondContract (owner-driven and CYR-
    // driven flips alike); the legacy AutoCompound contract emits its
    // own CompoundModeSet from its dormant code path.
    event CompoundModeSet(uint256 indexed depositId, uint8 mode);

    function openDeposit(uint256 amount, uint8 productMode) external returns (uint256 depositId);

    function openDepositFor(address owner, uint256 amount, uint8 productMode) external returns (uint256 depositId);

    function accrueInterest(uint256 depositId) external returns (uint256 newlyAccrued);

    function previewAccruedInterest(uint256 depositId) external view returns (uint256 accruedInterest);

    function markMatured(uint256 depositId) external;

    function settleMatured(uint256 depositId) external;

    // §Code-Review N4 - settles a matured/dormant deposit WITH an outstanding
    // loan by repaying the debt out of the settlement proceeds atomically.
    function settleMaturedNet(uint256 depositId) external;

    function earlyExit(uint256 depositId) external;

    function markDormant(uint256 depositId) external;

    function markAbandoned(uint256 depositId) external;

    function abandonedFeePreview(uint256 depositId) external view returns (uint256 feeAmount);

    function getDeposit(uint256 depositId) external view returns (Deposit memory deposit);

    // §Phase 2 Marketplace - true while the deposit's NFT is listed for sale.
    function isDepositListed(uint256 depositId) external view returns (bool);

    function setLoanState(uint256 depositId, uint256 loanBalance, uint256 loanAccruedInterest) external;

    function markLiquidated(uint256 depositId) external;

    function sweepInterestForCyr(uint256 depositId, uint256 amount, address recipient) external;

    function setCompoundMode(uint256 depositId, uint8 mode) external;

    function applyInterestToLoan(uint256 depositId, uint256 interestApplied) external;

    function setPegOk(bool pegOk) external;
}
