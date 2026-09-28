// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IAutoCompound} from "./interfaces/IAutoCompound.sol";
import {IBondContract} from "./interfaces/IBondContract.sol";
import {ICapitalRouter} from "./interfaces/ICapitalRouter.sol";
import {IDepositMetadataRenderer} from "./interfaces/IDepositMetadataRenderer.sol";
import {IDepositNFT} from "./interfaces/IDepositNFT.sol";
import {IERC20} from "./interfaces/IERC20.sol";
import {IGovernance} from "./interfaces/IGovernance.sol";
import {ILending} from "./interfaces/ILending.sol";
import {ISafeVault} from "./interfaces/ISafeVault.sol";
import {ITreasury} from "./interfaces/ITreasury.sol";
import {ITurbo} from "./interfaces/ITurbo.sol";
import {ITVT} from "./interfaces/ITVT.sol";
import {IGilderTypes} from "./interfaces/IGilderTypes.sol";
import {GilderAccessControl} from "./GilderAccessControl.sol";

/**
 * Minimal views/hooks the M1-M3 modules use to talk to the M4
 * Consolidated Yield Reinvestment (CYR) module. Declared standalone so
 * the CYR module can ship as its own file/contract without the monolith
 * importing it: BondContract / DepositNFT / Lending only ever need to
 * (a) ask whether a deposit is currently pooled and (b) notify the pool
 * when an underlying deposit is being liquidated.
 */
/**
 * §Code-Review C2 follow-up - the slice of Lending the BondContract needs to
 * service an open loan out of bond yield before releasing that yield.
 */
interface ILendingNetting {
    function netInterestAgainstLoan(uint256 depositId, uint256 depositInterestAvailable)
        external
        returns (uint256 netted);
}

interface ICyrAttachView {
    function isAttached(uint256 depositId) external view returns (bool);
}

interface ICyrSettlementHook {
    function onSettlement(uint256 depositId, uint8 reason) external;
}

/**
 * Spec §18.1: an ERC-721C transfer of a deposit's NFT IS a transfer of
 * the deposit position. DepositNFT calls `syncDepositOwner` from its
 * `_transfer` so BondContract's canonical `deposit.owner` always tracks
 * the current token holder.
 */
interface IBondOwnerSync {
    function syncDepositOwner(uint256 depositId, address newOwner) external;
}

library GilderStrings {
    function toString(uint256 value) internal pure returns (string memory) {
        if (value == 0) {
            return "0";
        }

        uint256 temp = value;
        uint256 digits;
        while (temp != 0) {
            digits++;
            temp /= 10;
        }

        bytes memory buffer = new bytes(digits);
        while (value != 0) {
            digits -= 1;
            buffer[digits] = bytes1(uint8(48 + uint256(value % 10)));
            value /= 10;
        }
        return string(buffer);
    }
}

/**
 * Centralised rounding helpers used by every settlement path.
 *
 * Spec §6 invariant:
 *   - Interest, fees, penalties -> round in favour of the protocol (floor).
 *   - Principal returns        -> round in favour of the user (ceil).
 *
 * Using a shared library keeps the rounding behaviour identical across
 * deposits, loans, liquidations, treasury allocations and auto-compound
 * settlement, which avoids accumulated dust drift.
 */
library RoundingLib {
    function roundDownToProtocol(uint256 numerator, uint256 denominator) internal pure returns (uint256) {
        return numerator / denominator;
    }

    function roundUpToUser(uint256 numerator, uint256 denominator) internal pure returns (uint256) {
        if (denominator == 0) return 0;
        return (numerator + denominator - 1) / denominator;
    }
}

abstract contract GilderModule is GilderAccessControl {
    // §Emergency Brake (Jul 2026) - `paused`, the Paused/Unpaused events and
    // the freeze rules now live in GilderAccessControl so every module in
    // the system shares one brake. The slot `paused` used to occupy is
    // returned to __gap (48 -> 49) so no derived contract's storage moved.
    uint256 private _reentrancyStatus;

    error TransferFailed();
    error ReentrantCall();

    modifier nonReentrant() {
        if (_reentrancyStatus == 1) {
            revert ReentrantCall();
        }
        _reentrancyStatus = 1;
        _;
        _reentrancyStatus = 0;
    }

    /// Legacy name kept for existing scripts/ABIs - any single freeze
    /// authority, instant, no timelock.
    function pause() external {
        emergencyFreeze();
    }

    /// Legacy name kept for existing scripts/ABIs - guardian council only,
    /// and only under a unanimously-confirmed execution.
    function unpause() external {
        emergencyUnfreeze();
    }

    uint256[49] private __gap;
}

/**
 * @title CapitalRouter
 * @notice Atomic 80/10/9/1 deposit routing.
 *
 * Spec §3.3: every deposit must route 80% to the Safe Vault, 10% to a
 * protocol-token buy, 9% to the Treasury and 1% to liquidity in a
 * single transaction. If any leg fails, the whole transaction must
 * revert. Slippage on the token-buy leg is the responsibility of the
 * `tokenBuyRouter` contract - this library wires it in but does not
 * embed slippage logic itself so the buy strategy can evolve without
 * touching deposit logic.
 *
 * Implemented as a Solidity library so it stays a single inlined
 * routine (no extra cross-contract call overhead) while still being a
 * separately reasoned-about, testable unit.
 */
library CapitalRouter {
    struct Allocation {
        uint256 safeVaultAmount;
        uint256 tokenBuyAmount;
        uint256 treasuryAmount;
        uint256 liquidityAmount;
    }

    error CapitalRouterTransferFailed();

    // §Code-Review H7 - the LP top-up leg faulted and was skipped; the
    // deposit itself completed. The slice sits with the LiquidityManager.
    event LiquidityTopUpFailed(uint256 indexed depositId, uint256 usdcAmount);

    /**
     * Pure helper: split `amount` into the 80/10/9/1 buckets using
     * RoundingLib in the protocol's favour. The SafeVault gets the
     * residual (always >= sum of the rounded slices) so user
     * principal is never short-changed.
     */
    function computeSplit(uint256 amount, uint256 tokenBuyBps, uint256 treasuryBps, uint256 liquidityBps, uint256 bpsDenominator)
        internal
        pure
        returns (Allocation memory split)
    {
        split.tokenBuyAmount = RoundingLib.roundDownToProtocol(amount * tokenBuyBps, bpsDenominator);
        split.treasuryAmount = RoundingLib.roundDownToProtocol(amount * treasuryBps, bpsDenominator);
        split.liquidityAmount = RoundingLib.roundDownToProtocol(amount * liquidityBps, bpsDenominator);
        split.safeVaultAmount = amount - split.tokenBuyAmount - split.treasuryAmount - split.liquidityAmount;
    }

    /**
     * Performs the four atomic transfers + bookkeeping calls. The
     * BondContract pulls user USDC into itself first, then this
     * library moves it through the four destinations. Any leg that
     * reverts unwinds the whole transaction.
     */
    function execute(
        IERC20 asset,
        address safeVault,
        address treasury,
        address tokenBuyRouter,
        address liquidityRecipient,
        address liquidityManager,
        uint256 depositId,
        Allocation memory split
    ) internal {
        if (!asset.transfer(safeVault, split.safeVaultAmount)) {
            revert CapitalRouterTransferFailed();
        }
        ISafeVault(safeVault).accountPrincipal(depositId, split.safeVaultAmount);

        if (!asset.transfer(treasury, split.treasuryAmount)) {
            revert CapitalRouterTransferFailed();
        }
        ITreasury(treasury).receiveAllocation(depositId, split.treasuryAmount);

        if (liquidityManager != address(0)) {
            // §V6.3 Issue 2A - symmetric LP top-up BEFORE the market buy: the
            // 1% slice is paired with Treasury GIL and added to the pool
            // (growing Live K / deepening depth), THEN the token-buy leg
            // executes on the now-deeper pool.
            if (!asset.transfer(liquidityManager, split.liquidityAmount)) {
                revert CapitalRouterTransferFailed();
            }
            // §Code-Review H7 (Jul 2026) - defence in depth. The manager is
            // itself hardened to degrade rather than revert (finite GIL
            // inventory, fee-harvest faults, mint slippage all become skip
            // paths), but this call sits on the critical deposit path: an
            // unguarded external call here means ANY fault in the LP leg
            // denies the user's deposit. Wrapped so the deposit always
            // completes; the 1% slice stays with the manager, recoverable by
            // governance via `sweepToTreasury`.
            try ICapitalRouterLiquidity(liquidityManager).addSymmetricLiquidity(depositId, split.liquidityAmount) {}
            catch {
                emit LiquidityTopUpFailed(depositId, split.liquidityAmount);
            }

            if (!asset.transfer(tokenBuyRouter, split.tokenBuyAmount)) {
                revert CapitalRouterTransferFailed();
            }
            ICapitalRouterTarget(tokenBuyRouter).executeTokenBuy(depositId, split.tokenBuyAmount);
        } else {
            // Legacy ordering (no LP manager wired): market buy, then a bare
            // transfer of the 1% slice to the liquidity recipient.
            if (!asset.transfer(tokenBuyRouter, split.tokenBuyAmount)) {
                revert CapitalRouterTransferFailed();
            }
            ICapitalRouterTarget(tokenBuyRouter).executeTokenBuy(depositId, split.tokenBuyAmount);

            if (!asset.transfer(liquidityRecipient, split.liquidityAmount)) {
                revert CapitalRouterTransferFailed();
            }
        }
    }
}

interface ICapitalRouterTarget {
    function executeTokenBuy(uint256 depositId, uint256 amount) external;
}

interface ICapitalRouterLiquidity {
    function addSymmetricLiquidity(uint256 depositId, uint256 usdcAmount) external;
}

/**
 * @title LifecycleManager
 * @notice Pure state-transition validator for the deposit lifecycle.
 *
 * Spec §4.4 / §5: deposits flow Active -> Matured -> Dormant ->
 * Abandoned -> Exited / Closed. No admin override; transitions are
 * driven solely by elapsed time and user-initiated actions. This
 * library centralises the validation rules so BondContract becomes a
 * thin orchestration layer.
 */
library LifecycleManager {
    error InvalidTransition(IGilderTypes.DepositState from, IGilderTypes.DepositState to);
    error MaturityNotReached();

    /**
     * Returns true if the deposit can transition Active -> Matured at
     * `currentTime`. Caller still has to perform the actual mutation
     * + accrual snapshot.
     */
    function canMature(IGilderTypes.DepositState state, uint64 maturityTime, uint256 currentTime) internal pure returns (bool) {
        return state == IGilderTypes.DepositState.Active && currentTime >= maturityTime;
    }

    function requireMaturityReached(uint64 maturityTime, uint256 currentTime) internal pure {
        if (currentTime < maturityTime) revert MaturityNotReached();
    }

    /**
     * Validates a Matured -> Dormant transition. The transition is
     * allowed any time after maturity has been recorded; it does not
     * require a separate elapsed-time gate.
     */
    function requireDormantTransition(IGilderTypes.DepositState state) internal pure {
        if (state != IGilderTypes.DepositState.Matured) {
            revert InvalidTransition(state, IGilderTypes.DepositState.Dormant);
        }
    }

    /**
     * Computes accrued interest for a deposit using simple-yield
     * math, capped at maturity. Rounds in the protocol's favour
     * (floor) so accrual cents stay in the Treasury rather than
     * leaking out as user dust.
     */
    function calculateAccruedInterest(
        IGilderTypes.Deposit storage deposit,
        uint256 currentTime,
        uint256 bpsDenominator,
        uint256 daysPerYear
    ) internal view returns (uint256) {
        uint256 end = currentTime < deposit.maturityTime ? currentTime : deposit.maturityTime;
        if (end <= deposit.startTime) return 0;
        uint256 elapsedDays = (end - deposit.startTime) / 1 days;
        uint256 totalAccrued = RoundingLib.roundDownToProtocol(
            deposit.principal * deposit.annualRateBps * elapsedDays,
            bpsDenominator * daysPerYear
        );
        // Net out interest already paid out via auto-compound or any
        // prior partial settlement. Without this subtraction the
        // cumulative time-based formula keeps re-crediting the same
        // interest on every fresh `accrueInterest` call, allowing
        // unbounded re-compounding of a single accrual cycle.
        uint256 realized = deposit.realizedInterest;
        return totalAccrued > realized ? totalAccrued - realized : 0;
    }
}

contract BondContract is IBondContract, GilderModule {
    uint256 public constant BPS_DENOMINATOR = 10_000;
    uint256 public constant MIN_DEPOSIT_AMOUNT = 100e6;
    // §V6.2-Standard product - 20% APR, 80/10/9/1 split, 20% early-exit
    // penalty. These are the historical V6.0/V6.1 defaults retained as
    // the "Standard" product after V6.2 introduced the Turbo variant.
    uint256 public constant SAFE_VAULT_BPS = 8_000;
    uint256 public constant TOKEN_BUY_BPS = 1_000;
    uint256 public constant TREASURY_BPS = 900;
    uint256 public constant LIQUIDITY_BPS = 100;
    uint256 public constant SIMPLE_ANNUAL_RATE_BPS = 2_000;
    uint256 public constant EARLY_EXIT_PENALTY_BPS = 2_000;
    // §V6.3 Turbo product - leverage via a REAL recursive borrow loop, NOT a
    // re-routed split. Each Turbo deposit (rung) routes 80/10/9/1 @ 20% APR
    // exactly like Standard; the 2.5x leverage comes from
    // `Turbo.executeTurboLoop`, which borrows 75% of each rung's Safe-Vault
    // collateral and re-deposits it, round after round. The geometric series
    // (each round = 0.75x0.8 = 0.6 of the prior deposit) sums to ~2.5x total
    // gross and ~1.5xU total REAL loan, so the net 20%x2.5 - 15%x1.5 = 27.5%
    // EMERGES from the loop - it is not a stored per-deposit rate. Routing/rate
    // are identical to Standard; only the 50% early-exit penalty differs.
    //   safe vault 80% / token-buy 10% / treasury 9% / liquidity 1%, 20% APR.
    uint256 public constant SAFE_VAULT_TURBO_BPS = 8_000;
    uint256 public constant TOKEN_BUY_TURBO_BPS = 1_000;
    uint256 public constant TREASURY_TURBO_BPS = 900;
    uint256 public constant LIQUIDITY_TURBO_BPS = 100;
    uint256 public constant SIMPLE_ANNUAL_RATE_TURBO_BPS = 2_000;
    uint256 public constant EARLY_EXIT_PENALTY_TURBO_BPS = 5_000;
    // Product flag values stored on Deposit.productMode.
    uint8 public constant PRODUCT_MODE_STANDARD = 0;
    uint8 public constant PRODUCT_MODE_TURBO = 1;
    uint256 public constant DAYS_PER_YEAR = 365;
    uint256 public constant FIXED_TERM = 1_095 days;
    uint256 public constant DORMANT_GRACE_PERIOD = 365 days;
    uint256 public constant ABANDONED_MONTHLY_FEE_BPS = 500;
    uint256 public constant AUTO_COMPOUND_TRIGGER = 100e6;
    // §4.2 - minimum accrued interest a mid-term withdrawal (or the combined
    // total of a batch withdrawal) must clear. Set to $10 for now; keeps dust
    // withdrawals from wasting gas.
    uint256 public constant MIN_INTEREST_WITHDRAWAL = 10e6;

    IERC20 public asset;
    address public safeVault;
    address public treasury;
    address public depositNft;
    address public tokenBuyRouter;
    address public liquidityRecipient;
    // §V6.3 Issue 2A - when set, the 1% liquidity slice routes through this
    // manager as a symmetric LP top-up BEFORE the token-buy leg (deepens the
    // pool / grows Live K). Zero = legacy bare transfer to liquidityRecipient.
    address public liquidityManager;
    address public marketingWallet;
    address public lendingContract;
    address public dePegGuard;
    address public turboContract;
    address public autoCompoundContract;
    address public tvtContract;
    address public cyrContract;
    bool public depositsEnabled;
    bool public pegOk;
    uint256 public nextDepositId;
    mapping(uint256 depositId => Deposit deposit) private _deposits;
    mapping(uint256 depositId => uint64 lastFeeAssessment) private _lastFeeAssessment;

    event MarketingWalletSet(address indexed wallet);
    event TokenBuyRouterSet(address indexed router);
    event LiquidityManagerSet(address indexed manager);
    event AbandonedFeeCharged(uint256 indexed depositId, uint256 feeAmount, uint256 elapsedMonths);
    event LendingContractSet(address indexed lending);
    event DePegGuardSet(address indexed dePegGuard);
    event TurboContractSet(address indexed turbo);
    event AutoCompoundContractSet(address indexed autoCompound);
    event TvtContractSet(address indexed tvt);
    event CyrContractSet(address indexed cyr);
    event AccruedInterestConsumed(uint256 indexed depositId, uint256 amount);
    event InterestWithdrawn(uint256 indexed depositId, address indexed owner, uint256 amount);
    event DepositOwnershipTransferred(uint256 indexed depositId, address indexed from, address indexed to);
    event DepositRolledOver(
        uint256 indexed oldDepositId,
        uint256 indexed newDepositId,
        uint256 rolloverAmount,
        bool compoundedInterest
    );

    error DepositsDisabled();
    error PegNotOk();
    error DepositBelowMinimum(uint256 minimum, uint256 actual);
    error InvalidMaturity();
    error UnknownDeposit(uint256 depositId);
    error NotDepositOwner(uint256 depositId, address caller);
    error InvalidDepositState(uint256 depositId, DepositState state);
    error GracePeriodActive(uint256 depositId);
    error NoFeeDue();
    error MarketingWalletNotSet();
    error NotDepositNftOperator();
    error NotLendingOperator();
    error NotDePegGuard();
    error OutstandingLoan(uint256 depositId);
    error SeizeAmountExceedsCollateral(uint256 requested, uint256 available);
    error NotTurboOperator();
    error NotAutoCompoundOperator();
    // §Phase 2 Marketplace - value extraction is frozen while a bond is listed
    // for secondary sale, so accrued yield transfers intact to the buyer.
    error DepositListed(uint256 depositId);
    error InsufficientAccruedInterest(uint256 requested, uint256 available);
    error BelowMinInterestWithdrawal(uint256 amount, uint256 minimum);
    error DepositPoolAttached(uint256 depositId);
    error InvalidProductMode(uint8 productMode);

    function initialize(
        address admin,
        address asset_,
        address safeVault_,
        address treasury_,
        address depositNft_,
        address tokenBuyRouter_,
        address liquidityRecipient_,
        address marketingWallet_
    ) external {
        _initializeAccessControl(admin);
        if (
            asset_ == address(0) || safeVault_ == address(0) || treasury_ == address(0) || depositNft_ == address(0)
                || tokenBuyRouter_ == address(0) || liquidityRecipient_ == address(0)
                || marketingWallet_ == address(0)
        ) {
            revert ZeroAddress();
        }
        asset = IERC20(asset_);
        safeVault = safeVault_;
        treasury = treasury_;
        depositNft = depositNft_;
        tokenBuyRouter = tokenBuyRouter_;
        liquidityRecipient = liquidityRecipient_;
        marketingWallet = marketingWallet_;
        depositsEnabled = true;
        pegOk = true;
        nextDepositId = 1;
    }

    /**
     * §V6.3 Issue 2A - registers the deposit-time LP top-up manager. Once
     * set, the 1% liquidity slice is added to the pool as symmetric
     * liquidity BEFORE the token-buy leg. Setting it to the zero address
     * restores the legacy bare-transfer behaviour.
     */
    function setLiquidityManager(address manager) external onlyRole(PARAMETER_ROLE) {
        liquidityManager = manager;
        emit LiquidityManagerSet(manager);
    }

    /** Governance-only update for the wallet that receives abandoned-decay fees. */
    function setMarketingWallet(address wallet) external onlyRole(PARAMETER_ROLE) {
        if (wallet == address(0)) {
            revert ZeroAddress();
        }
        marketingWallet = wallet;
        emit MarketingWalletSet(wallet);
    }

    /**
     * Governance-only update of the token-buy router - the contract that
     * receives every deposit's 10% slice and swaps it for GIL. Lets the
     * protocol move from the M2 mock placeholder to the live
     * GilderTokenBuyRouter (real Uniswap V2 buy) without redeploying.
     */
    function setTokenBuyRouter(address router) external onlyRole(PARAMETER_ROLE) {
        if (router == address(0)) {
            revert ZeroAddress();
        }
        tokenBuyRouter = router;
        emit TokenBuyRouterSet(router);
    }

    /** Governance-only registration of the Lending module address. */
    function setLendingContract(address lending) external onlyRole(PARAMETER_ROLE) {
        if (lending == address(0)) {
            revert ZeroAddress();
        }
        lendingContract = lending;
        emit LendingContractSet(lending);
    }

    /** Governance-only registration of the DePegGuard address. */
    function setDePegGuard(address guard) external onlyRole(PARAMETER_ROLE) {
        if (guard == address(0)) {
            revert ZeroAddress();
        }
        dePegGuard = guard;
        emit DePegGuardSet(guard);
    }

    /** Called by DePegGuard when USDC price drifts outside the configured band. */
    function setPegOk(bool pegOk_) external {
        if (msg.sender != dePegGuard && !hasRole(PARAMETER_ROLE, msg.sender)) {
            revert NotDePegGuard();
        }
        pegOk = pegOk_;
        emit DepositValidationFlagsSet(depositsEnabled, pegOk_);
    }

    /**
     * Loan accounting hook: only the registered Lending contract may
     * mutate the loan fields on a deposit. Keeping the data inside the
     * Deposit struct lets indexers and the metadata renderer read it
     * cheaply without a cross-contract call.
     */
    function setLoanState(uint256 depositId, uint256 loanBalance, uint256 loanAccruedInterest_) external whenNotPaused {
        if (msg.sender != lendingContract) {
            revert NotLendingOperator();
        }
        Deposit storage deposit = _existingDeposit(depositId);
        deposit.loanBalance = loanBalance;
        deposit.loanAccruedInterest = loanAccruedInterest_;
        emit LoanStateUpdated(depositId, loanBalance, loanAccruedInterest_);
    }

    /**
     * Self-paying-netting hook: only the registered Lending contract may
     * call. Decrements the deposit's accrued interest by the amount the
     * Lending module has already netted against the loan. The loan-side
     * fields are mirrored through `setLoanState` in the same Lending
     * transaction, so this method does not touch them.
     */
    function applyInterestToLoan(uint256 depositId, uint256 interestApplied) external whenNotPaused {
        if (msg.sender != lendingContract) {
            revert NotLendingOperator();
        }
        Deposit storage deposit = _existingDeposit(depositId);
        if (interestApplied > deposit.accruedInterest) {
            interestApplied = deposit.accruedInterest;
        }
        deposit.accruedInterest -= interestApplied;
        deposit.realizedInterest += interestApplied; // permanently realize netted interest so the cumulative accrual formula cannot re-credit it
    }

    /**
     * Liquidation hook: SafeVault has already forfeited the collateral
     * slice and paid the liquidator bonus by the time Lending calls
     * here. We just zero out the deposit's local accounting + flip its
     * state to Closed so the indexer and the UI reflect the closure.
     */
    function markLiquidated(uint256 depositId) external whenNotPaused {
        if (msg.sender != lendingContract) {
            revert NotLendingOperator();
        }
        Deposit storage deposit = _existingDeposit(depositId);
        uint256 principalClosed = deposit.principal;
        uint256 collateralAmount = deposit.safeVaultAmount;
        deposit.safeVaultAmount = 0;
        deposit.accruedInterest = 0;
        deposit.loanBalance = 0;
        deposit.loanAccruedInterest = 0;
        deposit.state = DepositState.Closed;
        try ITreasury(treasury).unregisterActivePrincipal(principalClosed) {} catch {}
        // Burn the NFT so the token cannot outlive the liquidated deposit.
        // Best-effort (matches the unregisterActivePrincipal pattern) so an
        // NFT-module hiccup can never brick a liquidation.
        try IDepositNFT(depositNft).burn(depositId) {} catch {}
        emit LoanCollateralSeized(depositId, msg.sender, collateralAmount);
        emit DepositStateChanged(depositId, DepositState.Closed);
    }

    /**
     * Spec §18.1: "Ownership transfer of the NFT = deposit ownership
     * transfer", enforced at the contract level. DepositNFT calls this
     * from its `_transfer` so the canonical `deposit.owner` - which
     * every lifecycle action (settle, early exit, dormant/abandoned
     * withdraw, loan) authorises against - always tracks the current
     * ERC-721C holder. Without it the NFT and the spendable control of
     * the position would desync, letting a prior owner still settle a
     * deposit they no longer hold.
     */
    function syncDepositOwner(uint256 depositId, address newOwner) external whenNotPaused {
        if (msg.sender != depositNft) {
            revert NotDepositNftOperator();
        }
        if (newOwner == address(0)) {
            revert ZeroAddress();
        }
        Deposit storage deposit = _existingDeposit(depositId);
        address previous = deposit.owner;
        if (previous == newOwner) {
            return;
        }
        deposit.owner = newOwner;
        emit DepositOwnershipTransferred(depositId, previous, newOwner);
    }

    /**
     * §V6.2 - `productMode` selects the product economics applied to the
     * new deposit:
     *   - 0 (Standard) -> 20% APR, 80/10/9/1 split, 20% early-exit penalty
     *   - 1 (Turbo)    -> 20% APR (UI label shows 27.5%), 80/10/9/1 split,
     *                    50% early-exit
     * Any other value reverts. The flag is locked on the Deposit struct
     * for the life of the position so the routed capital, APR accrual,
     * and exit penalty all stay consistent with the product the user
     * picked at creation - even if a future governance tweak changes
     * the protocol-wide defaults.
     */
    function openDeposit(uint256 amount, uint8 productMode) external nonReentrant returns (uint256 depositId) {
        return _openDepositCore(msg.sender, msg.sender, amount, productMode);
    }

    /**
     * Operator-only deposit opener used by Turbo (leveraged redeposit)
     * and AutoCompound (interest reinvestment). The orchestrator is the
     * USDC payer (already holds the capital from a prior loan or
     * Treasury draw); the deposit is registered under `owner`.
     *
     * `productMode` flows through unchanged so the orchestrator can
     * spin up either Standard or Turbo positions on the user's behalf
     * - Turbo's leveraged inner deposit needs Turbo economics, CYR's
     * Standard pool sweep needs Standard, and so on.
     */
    function openDepositFor(address owner_, uint256 amount, uint8 productMode)
        external
        nonReentrant
        returns (uint256 depositId)
    {
        if (
            msg.sender != turboContract && msg.sender != autoCompoundContract
                && msg.sender != cyrContract
        ) {
            revert NotTurboOperator();
        }
        if (owner_ == address(0)) {
            revert ZeroAddress();
        }
        return _openDepositCore(owner_, msg.sender, amount, productMode);
    }

    function _openDepositCore(address owner_, address payer, uint256 amount, uint8 productMode)
        private
        returns (uint256 depositId)
    {
        // §Emergency Brake - these are two DIFFERENT conditions and must not
        // share an error. `DepositsDisabled` means only new deposits are shut
        // (withdrawals and exits still work); a freeze halts those too. The UI
        // reads the error to decide what to tell the user, so collapsing them
        // made a frozen protocol claim "withdrawals are unaffected".
        if (paused) {
            revert ProtocolFrozen();
        }
        if (!depositsEnabled) {
            revert DepositsDisabled();
        }
        if (!pegOk) {
            revert PegNotOk();
        }
        // §3.2 / §17.2 invariant: every deposit minted by the protocol
        // - user-initiated entry, Turbo redeposit, AutoCompound seed,
        // AutoCompound's leveraged inner - must clear the $100 floor.
        // Docs explicitly tie the compound trigger to "minimum deposit
        // size" for "system consistency", so the same floor applies to
        // every internal path too.
        if (amount < MIN_DEPOSIT_AMOUNT) {
            revert DepositBelowMinimum(MIN_DEPOSIT_AMOUNT, amount);
        }
        // `rollover` settles a matured deposit's value INTO this contract
        // before re-depositing, so the BondContract is already the holder
        // - there is no external payer to pull from. Every other path
        // (openDeposit / Turbo / AutoCompound / CYR) has a distinct payer
        // that must transfer the capital in.
        if (payer != address(this)) {
            _safeTransferFrom(asset, payer, address(this), amount);
        }

        // §V6.2 - resolve product economics from `productMode`. Any
        // value other than Standard/Turbo reverts here so a typo in a
        // calling contract surfaces instead of silently routing to the
        // wrong split.
        uint256 tokenBuyBps;
        uint256 treasuryBps;
        uint256 liquidityBps;
        uint256 annualRateBps;
        uint256 earlyExitPenaltyBps;
        if (productMode == PRODUCT_MODE_STANDARD) {
            tokenBuyBps = TOKEN_BUY_BPS;
            treasuryBps = TREASURY_BPS;
            liquidityBps = LIQUIDITY_BPS;
            annualRateBps = SIMPLE_ANNUAL_RATE_BPS;
            earlyExitPenaltyBps = EARLY_EXIT_PENALTY_BPS;
        } else if (productMode == PRODUCT_MODE_TURBO) {
            tokenBuyBps = TOKEN_BUY_TURBO_BPS;
            treasuryBps = TREASURY_TURBO_BPS;
            liquidityBps = LIQUIDITY_TURBO_BPS;
            annualRateBps = SIMPLE_ANNUAL_RATE_TURBO_BPS;
            earlyExitPenaltyBps = EARLY_EXIT_PENALTY_TURBO_BPS;
        } else {
            revert InvalidProductMode(productMode);
        }

        // CapitalRouter computes the four-way split + performs every
        // transfer + accounting call. Any leg that reverts unwinds the
        // whole transaction (atomicity invariant from spec §3.3).
        CapitalRouter.Allocation memory split = CapitalRouter.computeSplit(
            amount,
            tokenBuyBps,
            treasuryBps,
            liquidityBps,
            BPS_DENOMINATOR
        );

        depositId = nextDepositId++;
        _deposits[depositId] = Deposit({
            owner: owner_,
            principal: amount,
            safeVaultAmount: split.safeVaultAmount,
            tokenBuyAmount: split.tokenBuyAmount,
            treasuryAmount: split.treasuryAmount,
            liquidityAmount: split.liquidityAmount,
            annualRateBps: annualRateBps,
            accruedInterest: 0,
            loanBalance: 0,
            loanAccruedInterest: 0,
            startTime: uint64(block.timestamp),
            maturityTime: uint64(block.timestamp + FIXED_TERM),
            dormantTime: 0,
            state: DepositState.Active,
            compoundMode: 0,
            realizedInterest: 0,
            productMode: productMode,
            earlyExitPenaltyBps: earlyExitPenaltyBps
        });

        CapitalRouter.execute(
            asset,
            safeVault,
            treasury,
            tokenBuyRouter,
            liquidityRecipient,
            liquidityManager,
            depositId,
            split
        );

        // §G.2 - feed the dynamic coverage formula. Best-effort: a
        // missing role on a fresh upgrade should not block deposits.
        try ITreasury(treasury).registerActivePrincipal(amount) {} catch {}

        IDepositNFT(depositNft).mintForDeposit(owner_, depositId);

        // Mirror the token-buy slice into TVT.circulatingSupply so the
        // dashboard's TVT reading reflects real per-deposit growth
        // (1 USDC of token-buy ~ 1 GIL minted, at parity placeholder).
        // Wrapped in a conditional + try/catch so deposits never fail
        // if the TVT module is paused, mis-roled, or not yet wired.
        if (tvtContract != address(0)) {
            try ITVT(tvtContract).recordSupplyChange(int256(uint256(split.tokenBuyAmount))) {
                // best-effort - supply is observability, not a balance.
            } catch {
                /* swallow: deposit semantics must not depend on TVT */
            }
        }

        emit DepositOpened(depositId, owner_, amount);
        emit DepositStateChanged(depositId, DepositState.Active);
        emit CapitalRouted(depositId, split.safeVaultAmount, split.tokenBuyAmount, split.treasuryAmount, split.liquidityAmount);
    }

    /**
     * AutoCompound hook: reduces the deposit's accrued interest counter
     * after the operator has pulled the corresponding USDC from Treasury
     * and redeposited it. Without this the user could "double-claim"
     * the same interest at settle.
     */
    function consumeAccruedInterest(uint256 depositId, uint256 amount) external whenNotPaused {
        if (msg.sender != autoCompoundContract && msg.sender != cyrContract) {
            revert NotAutoCompoundOperator();
        }
        // §Phase 2 Marketplace - auto-compound / CYR must not siphon a LISTED
        // deposit's accrued interest into a fresh deposit owned by the seller;
        // that yield belongs to the buyer. (Permissionless compound triggers
        // make this reachable by anyone.) Blocked while listed; resumes on sale
        // or delist. Pool-attached deposits can't be listed, so CYR sweeps of
        // genuine pool members are unaffected.
        _requireNotListed(depositId);
        // §Code-Review C2 follow-up - netting is NOT applied here: the caller
        // has already read `accruedInterest` to size `amount`, and reducing
        // it underneath them would make this revert. The compound entry
        // points net BEFORE they read instead (AutoCompound.executeCompound,
        // CYR.sweepPool / compoundIndependent).
        Deposit storage deposit = _existingDeposit(depositId);
        if (amount > deposit.accruedInterest) {
            revert InsufficientAccruedInterest(amount, deposit.accruedInterest);
        }
        deposit.accruedInterest -= amount;
        // Track the consumed amount so the next `accrueInterest` call -
        // and every settlement path that reads `_calculateAccruedInterest`
        // - nets it out of the cumulative time-based total. This is the
        // mirror of the §17.7 invariant: auto-compound is "internal
        // accounting only" and must not double-pay interest.
        deposit.realizedInterest += amount;
        emit AccruedInterestConsumed(depositId, amount);
    }

    /**
     * §I.6 Pool-level Auto-Compound sweep helper. CYR calls this for
     * every deposit it consumes yield from during a `sweepPool` action:
     * the routine accrues the deposit, marks `amount` of accrued
     * interest as realised, and pulls that USDC from Treasury into the
     * caller (CYR) so it can be re-routed as the principal of the new
     * compounded deposit (Standard) or combined with leverage (Turbo).
     *
     * Authorisation: msg.sender must be the registered CYR module -
     * the only contract authorised to drive pool-level compound flows.
     */
    function sweepInterestForCyr(uint256 depositId, uint256 amount, address recipient) external whenNotPaused {
        if (msg.sender != cyrContract) {
            revert NotAutoCompoundOperator();
        }
        if (recipient == address(0)) {
            revert ZeroAddress();
        }
        // §Phase 2 Marketplace - mirror of the consumeAccruedInterest guard.
        // This is the CYR sibling of that path (reached via CYR.sweepPool and
        // the PERMISSIONLESS CYR.compoundIndependent), and compoundIndependent
        // runs on NON-pooled deposits, so a listed-but-unattached deposit's
        // accrued interest could otherwise be swept into a fresh deposit owned
        // by the seller mid-listing - stealing the yield the buyer paid for.
        // Legitimate pool members are never listed (pool-attached can't be
        // listed), so genuine sweepPool flows are unaffected.
        _requireNotListed(depositId);
        // §Code-Review C2 follow-up - netting is applied by the CYR entry
        // points before they size `amount` (see consumeAccruedInterest).
        Deposit storage deposit = _existingDeposit(depositId);
        // Refresh storage `accruedInterest` to the live time-based total
        // BEFORE checking the request size - otherwise a deposit that
        // never had `accrueInterest()` called would read 0 and reject
        // a legitimately accrued sweep.
        uint256 live = _calculateAccruedInterest(deposit, block.timestamp);
        if (live > deposit.accruedInterest) {
            deposit.accruedInterest = live;
        }
        if (amount > deposit.accruedInterest) {
            revert InsufficientAccruedInterest(amount, deposit.accruedInterest);
        }
        deposit.accruedInterest -= amount;
        deposit.realizedInterest += amount;
        emit AccruedInterestConsumed(depositId, amount);
        ITreasury(treasury).paySettlement(depositId, recipient, amount);
    }

    function setTurboContract(address turbo) external onlyRole(PARAMETER_ROLE) {
        if (turbo == address(0)) {
            revert ZeroAddress();
        }
        turboContract = turbo;
        emit TurboContractSet(turbo);
    }

    function setAutoCompoundContract(address auto_) external onlyRole(PARAMETER_ROLE) {
        if (auto_ == address(0)) {
            revert ZeroAddress();
        }
        autoCompoundContract = auto_;
        emit AutoCompoundContractSet(auto_);
    }

    /**
     * Registers the M4 Consolidated Yield Reinvestment module. Once set,
     * the CYR contract may open materialized-reinvestment deposits via
     * `openDepositFor`, and the exit paths (settle / early exit /
     * abandoned withdraw) refuse to run while a deposit is still pooled -
     * the owner must detach (which settles the pool bonus) first.
     */
    function setCyrContract(address cyr) external onlyRole(PARAMETER_ROLE) {
        if (cyr == address(0)) {
            revert ZeroAddress();
        }
        cyrContract = cyr;
        emit CyrContractSet(cyr);
    }

    /**
     * Guards an exit path against a deposit that is still attached to a
     * Consolidated Reinvestment Pool. Kept as a read-only guard for
     * non-lifecycle callers that must NOT trigger settlement (e.g. an
     * NFT transfer attempt). Lifecycle paths use
     * `_autoDetachIfPoolAttached` instead, which materializes the pool's
     * deferred bonus before the underlying deposit transitions.
     */
    function _requireNotPoolAttached(uint256 depositId) private view {
        address cyr = cyrContract;
        if (cyr != address(0) && ICyrAttachView(cyr).isAttached(depositId)) {
            revert DepositPoolAttached(depositId);
        }
    }

    /**
     * §I.6 spec: settlement events (Withdraw / EarlyExit / Rollover /
     * Closure / Abandoned) MUST auto-detach the deposit from any
     * Consolidated Reinvestment Pool and materialize the pool owner's
     * accrued bonus before the deposit transitions. Wrapped in try/catch
     * so a malformed pool can never block a legitimate lifecycle action
     * - worst case the deposit closes with the bonus left unrealised,
     * which is the correct safety bias.
     *
     * `reason` is a SettlementReason enum value (0 = Withdraw,
     * 1 = EarlyExit, 2 = Rollover, 3 = Detach, 4 = Liquidation,
     * 5 = ManualReinvest).
     */
    function _autoDetachIfPoolAttached(uint256 depositId, uint8 reason) private {
        address cyr = cyrContract;
        if (cyr == address(0)) return;
        if (!ICyrAttachView(cyr).isAttached(depositId)) return;
        try ICyrSettlementHook(cyr).onSettlement(depositId, reason) {} catch {}
    }

    /**
     * Registers the TVT module. Once set, every successful `openDeposit`
     * calls `TVT.recordSupplyChange(tokenBuyAmount)` so the protocol-token
     * supply stays in sync with the 10% token-buy slice without any
     * separate keeper or governance tx - that's what previously made
     * `currentTvt()` read as 0 (no caller was ever bumping supply).
     *
     * BondContract must hold PARAMETER_ROLE on the TVT contract for the
     * mirror call to land; the deploy script grants that.
     */
    function setTvtContract(address tvt_) external onlyRole(PARAMETER_ROLE) {
        if (tvt_ == address(0)) {
            revert ZeroAddress();
        }
        tvtContract = tvt_;
        emit TvtContractSet(tvt_);
    }

    function setCompoundMode(uint256 depositId, uint8 mode) external whenNotPaused {
        Deposit storage deposit = _existingDeposit(depositId);
        // §I.6 - owner and CYR can set the mode. AutoCompound is retained
        // for backward-compat in the dormant contract code but isn't
        // wired in V6.2 strict deployments. §V6.3 - the Turbo orchestrator
        // also sets it, so loop rungs inherit the source deposit's
        // auto-reinvest setting (every rung in the leveraged stack
        // reinvests, per the Turbo Automated Reinvestment spec).
        if (
            msg.sender != deposit.owner
                && msg.sender != cyrContract
                && msg.sender != autoCompoundContract
                && msg.sender != turboContract
        ) {
            revert NotDepositOwner(depositId, msg.sender);
        }
        if (mode > 2) {
            revert InvalidDepositState(depositId, deposit.state);
        }
        // §Phase 2 Marketplace - a listed deposit's auto-reinvest setting must
        // not change while it sits on the market: arming compound (Off -> Standard
        // /Turbo) would re-open the sweepInterestForCyr yield-siphon closed above.
        // Fresh Turbo/CYR rungs are never listed, so those internal callers are
        // unaffected; only an owner trying to arm a live listing is blocked.
        _requireNotListed(depositId);
        deposit.compoundMode = mode;
        // §V6.2 - surface the change as an event so the indexer can
        // mirror it into Mongo. Without this the off-chain state
        // diverged from chain: tx succeeded, contract storage changed,
        // but every backend read returned the stale value persisted by
        // the original DepositOpened handler. Re-listing the deposit
        // would then snap the UI back to the old mode.
        emit CompoundModeSet(depositId, mode);
    }

    function setDepositValidationFlags(bool depositsEnabled_, bool pegOk_) external onlyRole(PARAMETER_ROLE) {
        depositsEnabled = depositsEnabled_;
        pegOk = pegOk_;
        emit DepositValidationFlagsSet(depositsEnabled_, pegOk_);
    }

    function toggleDeposits() external onlyRole(PARAMETER_ROLE) {
        bool next = !depositsEnabled;
        depositsEnabled = next;
        emit DepositValidationFlagsSet(next, pegOk);
    }

    function accrueInterest(uint256 depositId) external returns (uint256 newlyAccrued) {
        Deposit storage deposit = _deposits[depositId];
        if (deposit.owner == address(0)) {
            revert UnknownDeposit(depositId);
        }

        uint256 accrued = _calculateAccruedInterest(deposit, block.timestamp);
        newlyAccrued = accrued - deposit.accruedInterest;
        deposit.accruedInterest = accrued;
    }

    function previewAccruedInterest(uint256 depositId) external view returns (uint256 accruedInterest) {
        Deposit storage deposit = _deposits[depositId];
        if (deposit.owner == address(0)) {
            revert UnknownDeposit(depositId);
        }
        return _calculateAccruedInterest(deposit, block.timestamp);
    }

    function markMatured(uint256 depositId) external whenNotPaused {
        Deposit storage deposit = _existingDeposit(depositId);
        if (deposit.state != DepositState.Active) {
            revert InvalidDepositState(depositId, deposit.state);
        }
        LifecycleManager.requireMaturityReached(deposit.maturityTime, block.timestamp);

        deposit.accruedInterest = _calculateAccruedInterest(deposit, block.timestamp);
        deposit.state = DepositState.Matured;
        emit DepositStateChanged(depositId, DepositState.Matured);
    }

    function settleMatured(uint256 depositId) external nonReentrant whenNotPaused {
        Deposit storage deposit = _existingDeposit(depositId);
        if (deposit.owner != msg.sender) {
            revert NotDepositOwner(depositId, msg.sender);
        }
        _requireNotListed(depositId);
        // §I.6 - auto-detach (Withdraw = 0) so the pool bonus
        // materializes before this deposit closes.
        _autoDetachIfPoolAttached(depositId, 0);
        if (deposit.loanBalance != 0 || deposit.loanAccruedInterest != 0) {
            revert OutstandingLoan(depositId);
        }
        if (deposit.state == DepositState.Active && block.timestamp >= deposit.maturityTime) {
            deposit.accruedInterest = _calculateAccruedInterest(deposit, block.timestamp);
            deposit.state = DepositState.Matured;
            emit DepositStateChanged(depositId, DepositState.Matured);
        }
        if (deposit.state != DepositState.Matured && deposit.state != DepositState.Dormant) {
            revert InvalidDepositState(depositId, deposit.state);
        }

        uint256 interest = deposit.accruedInterest;
        uint256 principalClosed = deposit.principal;
        uint256 treasurySettlement = deposit.principal - deposit.safeVaultAmount + interest;
        // Mark the disbursed interest as realized so any later
        // _calculateAccruedInterest read on this (now Closed) deposit nets to 0.
        deposit.realizedInterest += interest;
        deposit.state = DepositState.Closed;
        ISafeVault(safeVault).releasePrincipal(depositId, msg.sender, deposit.safeVaultAmount);
        ITreasury(treasury).paySettlement(depositId, msg.sender, treasurySettlement);
        try ITreasury(treasury).unregisterActivePrincipal(principalClosed) {} catch {}

        emit DepositSettled(depositId, msg.sender, deposit.principal, interest);
        emit DepositStateChanged(depositId, DepositState.Closed);
        // Burn the NFT so the token cannot outlive the closed deposit.
        IDepositNFT(depositNft).burn(depositId);
    }

    /**
     * §Code-Review N4 (Jul 2026) - ATOMIC NET-SETTLEMENT for leveraged
     * positions. `settleMatured` reverts with OutstandingLoan while any loan
     * exists, which forced a Turbo user to source ~0.6x of every rung's
     * principal in external USDC, repay rung by rung, then settle rung by
     * rung. This function repays the debt OUT OF the settlement proceeds in
     * one transaction instead:
     *
     *   1. remaining bond interest is netted against loan interest (the
     *      standard self-paying defence, applied one last time);
     *   2. the loan principal is absorbed by the deposit's own SafeVault
     *      claim (accounting-only - that USDC left the vault at disburse
     *      time);
     *   3. any remaining loan interest is withheld from the Treasury payout
     *      (and, in the extreme edge where it exceeds the whole Treasury
     *      leg, from the vault payout - physically routed to Treasury and
     *      booked as loan-interest income);
     *   4. the user receives the NET proceeds: principal + interest
     *      - loanPrincipal - loanInterest.
     *
     * Settlement proceeds per rung (~1.60x principal) always exceed the
     * maximum possible debt (~0.68x), so the user payout is strictly
     * positive. With this in place the post-maturity grace period is a
     * safety margin rather than the primary defence.
     */
    function settleMaturedNet(uint256 depositId) external nonReentrant whenNotPaused {
        Deposit storage deposit = _existingDeposit(depositId);
        if (deposit.owner != msg.sender) {
            revert NotDepositOwner(depositId, msg.sender);
        }
        _requireNotListed(depositId);
        // §I.6 - auto-detach (Withdraw = 0) so the pool bonus
        // materializes before this deposit closes.
        _autoDetachIfPoolAttached(depositId, 0);
        if (deposit.state == DepositState.Active && block.timestamp >= deposit.maturityTime) {
            deposit.accruedInterest = _calculateAccruedInterest(deposit, block.timestamp);
            deposit.state = DepositState.Matured;
            emit DepositStateChanged(depositId, DepositState.Matured);
        }
        if (deposit.state != DepositState.Matured && deposit.state != DepositState.Dormant) {
            revert InvalidDepositState(depositId, deposit.state);
        }

        // Close the loan out of the proceeds. This nets bond interest first
        // (mutating deposit.accruedInterest via applyInterestToLoan), clears
        // the vault-side debt via netSettleLoan and zeroes the mirrored loan
        // fields via setLoanState - so every figure read below is post-net.
        uint256 loanPrincipal;
        uint256 loanInterest;
        if (deposit.loanBalance != 0 || deposit.loanAccruedInterest != 0) {
            (loanPrincipal, loanInterest) = ILending(lendingContract).closeLoanForSettlement(depositId);
        }

        uint256 interest = deposit.accruedInterest;
        uint256 principalClosed = deposit.principal;
        // Vault leg: the claim that remains after netSettleLoan absorbed the
        // loan principal.
        uint256 vaultPayout =
            deposit.safeVaultAmount > loanPrincipal ? deposit.safeVaultAmount - loanPrincipal : 0;
        // Treasury leg: the standard settlement top-up minus the remaining
        // loan interest (withheld - Treasury simply keeps USDC it would
        // otherwise have paid out).
        uint256 treasuryPortion = deposit.principal - deposit.safeVaultAmount + interest;
        uint256 interestWithheld = loanInterest < treasuryPortion ? loanInterest : treasuryPortion;
        uint256 treasuryPayout = treasuryPortion - interestWithheld;
        // Extreme edge: loan interest exceeding the whole Treasury leg is
        // collected from the vault leg as physical USDC (vault -> Treasury,
        // booked as loan-interest income). Anything beyond BOTH legs is
        // written off, mirroring the liquidation path.
        uint256 interestFromVault = loanInterest - interestWithheld;
        if (interestFromVault > vaultPayout) {
            interestFromVault = vaultPayout;
        }

        // Mark the disbursed interest as realized so any later
        // _calculateAccruedInterest read on this (now Closed) deposit nets to 0.
        deposit.realizedInterest += interest;
        deposit.state = DepositState.Closed;

        if (interestFromVault > 0) {
            vaultPayout -= interestFromVault;
            ISafeVault(safeVault).releasePrincipal(depositId, treasury, interestFromVault);
            ITreasury(treasury).returnLoanCapital(depositId, 0, interestFromVault);
        }
        if (vaultPayout > 0) {
            ISafeVault(safeVault).releasePrincipal(depositId, msg.sender, vaultPayout);
        }
        if (treasuryPayout > 0) {
            ITreasury(treasury).paySettlement(depositId, msg.sender, treasuryPayout);
        }
        try ITreasury(treasury).unregisterActivePrincipal(principalClosed) {} catch {}

        emit DepositSettled(depositId, msg.sender, deposit.principal, interest);
        emit DepositStateChanged(depositId, DepositState.Closed);
        // Burn the NFT so the token cannot outlive the closed deposit.
        IDepositNFT(depositNft).burn(depositId);
    }

    /**
     * §4.2 - withdraw the FULL accrued USDC interest on one ACTIVE deposit to
     * the owner's wallet WITHOUT closing the term. The principal keeps earning
     * and the deposit stays Active. Must clear `MIN_INTEREST_WITHDRAWAL`.
     */
    function withdrawInterest(uint256 depositId) external nonReentrant whenNotPaused returns (uint256 paid) {
        paid = _withdrawInterestFor(depositId, msg.sender, type(uint256).max);
        if (paid < MIN_INTEREST_WITHDRAWAL) {
            revert BelowMinInterestWithdrawal(paid, MIN_INTEREST_WITHDRAWAL);
        }
    }

    /**
     * Withdraws the FULL accrued interest across every listed deposit (each
     * owned by the caller and Active) in one transaction. Deposits with zero
     * pending are skipped; the COMBINED total must clear the minimum.
     */
    function withdrawInterestBatch(uint256[] calldata depositIds)
        external
        nonReentrant
        whenNotPaused returns (uint256 totalPaid)
    {
        for (uint256 i = 0; i < depositIds.length; i++) {
            totalPaid += _withdrawInterestFor(depositIds[i], msg.sender, type(uint256).max);
        }
        if (totalPaid < MIN_INTEREST_WITHDRAWAL) {
            revert BelowMinInterestWithdrawal(totalPaid, MIN_INTEREST_WITHDRAWAL);
        }
    }

    /**
     * §4.2 - withdraws a USER-SPECIFIED `amount` of accrued interest across
     * the listed deposits (all owned by the caller and Active). The engine
     * pulls from each deposit's accrued interest in turn until `amount` is
     * satisfied (the last deposit may be drawn only partially). Powers the
     * dashboard's "enter an amount to withdraw" flow. `amount` must be at
     * least `MIN_INTEREST_WITHDRAWAL` and no more than the total accrued
     * across the listed deposits, else the whole call reverts.
     */
    function withdrawInterestAmount(uint256[] calldata depositIds, uint256 amount)
        external
        nonReentrant
        whenNotPaused returns (uint256 paid)
    {
        if (amount < MIN_INTEREST_WITHDRAWAL) {
            revert BelowMinInterestWithdrawal(amount, MIN_INTEREST_WITHDRAWAL);
        }
        uint256 remaining = amount;
        for (uint256 i = 0; i < depositIds.length && remaining > 0; i++) {
            remaining -= _withdrawInterestFor(depositIds[i], msg.sender, remaining);
        }
        paid = amount - remaining;
        // Requested more than the wallet has actually accrued -> revert so the
        // user never thinks a larger amount was paid than really was.
        if (remaining > 0) {
            revert InsufficientAccruedInterest(amount, paid);
        }
    }

    /**
     * Shared withdraw core: accrues the deposit and disburses up to
     * `maxAmount` of its pending interest (day-stepped, net of anything
     * already realised - the §17.7 no-double-pay invariant), pays it from
     * Treasury, and leaves the deposit Active. Returns the amount taken (0
     * when nothing is pending, so a batch skips it). No `nonReentrant` here -
     * the external entrypoints own the guard.
     */
    function _withdrawInterestFor(uint256 depositId, address owner_, uint256 maxAmount)
        private
        returns (uint256 taken)
    {
        Deposit storage deposit = _existingDeposit(depositId);
        if (deposit.owner != owner_) {
            revert NotDepositOwner(depositId, owner_);
        }
        if (deposit.state != DepositState.Active) {
            revert InvalidDepositState(depositId, deposit.state);
        }
        _requireNotListed(depositId);
        // §Code-Review C2 follow-up (Jul 2026) - SERVICE THE LOAN FIRST.
        //
        // The C2 remediation makes bond yield cancel loan interest, which is
        // what stops a Turbo position drifting into liquidation. But that
        // defence runs on the deposit's accrued interest - and this function
        // paid that same interest out with no reference to the loan. A
        // borrower could withdraw the netting fuel and re-create the exact
        // C2 drift, and (because the auto-compound triggers are
        // permissionless) a THIRD PARTY could drain someone else's fuel and
        // then collect the liquidation bounty months later.
        //
        // Netting here closes that: the loan's accrued interest is always
        // serviced out of bond yield before any of it can leave, so only the
        // genuine surplus is withdrawable.
        _netAgainstOpenLoan(depositId);
        uint256 pending = _calculateAccruedInterest(deposit, block.timestamp);
        if (pending == 0 || maxAmount == 0) {
            return 0;
        }
        taken = pending <= maxAmount ? pending : maxAmount;
        // Snapshot keeps the still-unrealised remainder; the realised counter
        // absorbs the taken slice so future accrual nets correctly.
        deposit.accruedInterest = pending - taken;
        deposit.realizedInterest += taken;
        emit InterestWithdrawn(depositId, owner_, taken);
        ITreasury(treasury).paySettlement(depositId, owner_, taken);
    }

    /**
     * §Code-Review C2 follow-up - applies the self-paying-netting defence
     * before this deposit's accrued interest is released to anyone (a
     * withdrawal, an auto-compound, or a pool sweep). Best-effort: a fault in
     * the Lending module must not block a depositor from reaching their own
     * yield, and if netting cannot run the position is simply no worse off
     * than it was.
     *
     * Callers MUST invoke this before reading `accruedInterest` for payout,
     * since netting reduces it.
     */
    /**
     * §Code-Review C2 follow-up - PERMISSIONLESS: services this deposit's
     * open loan out of its own accrued bond interest. Safe to expose (it is
     * capped at the loan's accrued interest and can only ever improve a
     * position) and callable by anyone - keepers, the frontend, or the
     * compound entry points, which invoke it BEFORE they size a payout so
     * the loan is always serviced ahead of the depositor's surplus.
     */
    function netLoanInterest(uint256 depositId) external whenNotPaused {
        _netAgainstOpenLoan(depositId);
    }

    function _netAgainstOpenLoan(uint256 depositId) private {
        address lending = lendingContract;
        if (lending == address(0)) {
            return;
        }
        try ILendingNetting(lending).netInterestAgainstLoan(depositId, type(uint256).max) returns (uint256) {}
        catch {}
    }

    /**
     * Spec §4.6 / §5: a matured (or in-grace Dormant) deposit may be
     * ROLLED OVER - closed and immediately re-opened as a fresh 3-year
     * term deposit in a single transaction, with no manual
     * withdraw-then-redeposit round trip.
     *
     * `compoundInterest` lets the owner choose what is rolled:
     *   - true  -> principal + accrued interest fund the new deposit, so
     *             the yield compounds into the next term.
     *   - false -> only the principal rolls; the accrued interest is paid
     *             out to the owner as USDC.
     *
     * The matured value is settled INTO this contract (SafeVault slice +
     * Treasury top-up) and then `_openDepositCore` re-routes the
     * rollover amount through the standard 80/10/9/1 split - a rollover
     * is a brand-new deposit issuance, not an extension, so every
     * downstream invariant (Safe Vault growth, Treasury allocation,
     * NFT mint) holds identically.
     */
    function rollover(uint256 depositId, bool compoundInterest, uint8 newProductMode)
        external
        nonReentrant
        whenNotPaused returns (uint256 newDepositId)
    {
        Deposit storage deposit = _existingDeposit(depositId);
        if (deposit.owner != msg.sender) {
            revert NotDepositOwner(depositId, msg.sender);
        }
        _requireNotListed(depositId);
        // §I.6 - auto-detach (Rollover = 2) so the pool's deferred
        // bonus is materialized into the OLD deposit before the new
        // term is opened.
        _autoDetachIfPoolAttached(depositId, 2);
        if (deposit.loanBalance != 0 || deposit.loanAccruedInterest != 0) {
            revert OutstandingLoan(depositId);
        }
        if (deposit.state == DepositState.Active && block.timestamp >= deposit.maturityTime) {
            deposit.accruedInterest = _calculateAccruedInterest(deposit, block.timestamp);
            deposit.state = DepositState.Matured;
            emit DepositStateChanged(depositId, DepositState.Matured);
        }
        if (deposit.state != DepositState.Matured && deposit.state != DepositState.Dormant) {
            revert InvalidDepositState(depositId, deposit.state);
        }

        uint256 interest = deposit.accruedInterest;
        uint256 vaultSlice = deposit.safeVaultAmount;
        uint256 treasuryPortion = deposit.principal - vaultSlice + interest;
        uint256 rolloverAmount = compoundInterest ? deposit.principal + interest : deposit.principal;
        uint256 principalClosed = deposit.principal;
        // Mark the settled interest as realized so the old (now Closed)
        // deposit cannot have this interest re-credited by a later accrual read.
        deposit.realizedInterest += interest;
        deposit.state = DepositState.Closed;
        try ITreasury(treasury).unregisterActivePrincipal(principalClosed) {} catch {}

        // Settle the matured value INTO the BondContract rather than to
        // the user: SafeVault slice + Treasury top-up land here.
        ISafeVault(safeVault).releasePrincipal(depositId, address(this), vaultSlice);
        if (treasuryPortion != 0) {
            ITreasury(treasury).paySettlement(depositId, address(this), treasuryPortion);
        }
        // Principal-only rollover: hand the accrued interest back as USDC.
        if (!compoundInterest && interest != 0) {
            _safeTransfer(asset, msg.sender, interest);
        }

        emit DepositSettled(depositId, msg.sender, deposit.principal, interest);
        emit DepositStateChanged(depositId, DepositState.Closed);
        // Burn the OLD token; _openDepositCore mints a fresh token for the
        // new depositId below. Burning here cannot collide with the new id.
        IDepositNFT(depositNft).burn(depositId);

        // Re-deposit the rollover amount. payer == address(this) tells
        // `_openDepositCore` the capital is already on hand. §V6.2 - the
        // caller chooses the new product (Standard=0 / Turbo=1), exactly
        // like a fresh deposit; `_openDepositCore` validates the value and
        // applies the matching APR/routing/penalty. Pass the source
        // deposit's productMode to keep the position unchanged.
        newDepositId = _openDepositCore(msg.sender, address(this), rolloverAmount, newProductMode);
        emit DepositRolledOver(depositId, newDepositId, rolloverAmount, compoundInterest);
    }

    /**
     * Spec §5 Phase 3: a deposit that has decayed into the Abandoned
     * state can still have its REMAINING balance withdrawn at any time.
     * The decay fees already siphoned part of the SafeVault slice to the
     * Marketing/Ops wallet; this hands the depositor whatever is left of
     * their protected slice and closes the position. No Treasury
     * settlement - an abandoned deposit forfeits the term-yield top-up.
     */
    function withdrawAbandoned(uint256 depositId) external nonReentrant whenNotPaused {
        Deposit storage deposit = _existingDeposit(depositId);
        if (deposit.owner != msg.sender) {
            revert NotDepositOwner(depositId, msg.sender);
        }
        _requireNotListed(depositId);
        if (deposit.state != DepositState.Abandoned) {
            revert InvalidDepositState(depositId, deposit.state);
        }
        // §I.6 - auto-detach (Withdraw = 0) so any pool bonus is
        // materialised before the abandoned remainder is paid out.
        _autoDetachIfPoolAttached(depositId, 0);
        if (deposit.loanBalance != 0 || deposit.loanAccruedInterest != 0) {
            revert OutstandingLoan(depositId);
        }
        uint256 remaining = deposit.safeVaultAmount;
        uint256 principalClosed = deposit.principal;
        deposit.state = DepositState.Closed;
        if (remaining > 0) {
            ISafeVault(safeVault).releasePrincipal(depositId, msg.sender, remaining);
        }
        try ITreasury(treasury).unregisterActivePrincipal(principalClosed) {} catch {}
        emit DepositSettled(depositId, msg.sender, remaining, 0);
        emit DepositStateChanged(depositId, DepositState.Closed);
        // Burn the NFT so the token cannot outlive the closed deposit.
        IDepositNFT(depositNft).burn(depositId);
    }

    function earlyExit(uint256 depositId) external nonReentrant whenNotPaused {
        Deposit storage deposit = _existingDeposit(depositId);
        if (deposit.owner != msg.sender) {
            revert NotDepositOwner(depositId, msg.sender);
        }
        _requireNotListed(depositId);
        if (deposit.state != DepositState.Active) {
            revert InvalidDepositState(depositId, deposit.state);
        }
        // Early exit is strictly pre-maturity: a matured-but-unmarked Active
        // bond must be settled via settleMatured/rollover (no 20% penalty),
        // never needlessly forfeited through earlyExit.
        if (block.timestamp >= deposit.maturityTime) {
            revert InvalidDepositState(depositId, deposit.state);
        }
        // §I.6 - auto-detach (EarlyExit = 1) so the pool's accrued
        // bonus is materialized before the deposit is exited.
        _autoDetachIfPoolAttached(depositId, 1);

        // §M6 (Jul 2026 client review) - "If someone early exits they get
        // their Safe balance - Minus what they have borrowed + any interest
        // earned and unclaimed. They do NOT have to pay anything back first."
        //
        // This used to `revert OutstandingLoan(depositId)`, which is what
        // produced the "Early Exit Failed - repay or close the outstanding
        // loan on this deposit before settling" dialog. That was
        // particularly punishing on Turbo, where EVERY rung carries a loan by
        // construction, so early exit was effectively unreachable without
        // manually unwinding the whole stack from the inside out.
        //
        // The loan is now closed ATOMICALLY out of the exit proceeds using
        // the same §Code-Review-N4 net-settlement leg that `settleMaturedNet`
        // uses: bond interest cancels loan interest first, the vault-side
        // debt is cleared against the depositor's own claim (no USDC moves -
        // the borrowed capital is already in their wallet), and only the
        // residual is paid out.
        uint256 loanPrincipal;
        uint256 loanInterest;
        if (deposit.loanBalance != 0 || deposit.loanAccruedInterest != 0) {
            (loanPrincipal, loanInterest) = ILending(lendingContract).closeLoanForSettlement(depositId);
        }

        // Read AFTER the net-settlement leg: closeLoanForSettlement mutates
        // `deposit.accruedInterest` (via applyInterestToLoan) when bond yield
        // is used to cancel loan interest.
        deposit.accruedInterest = _calculateAccruedInterest(deposit, block.timestamp);
        // Per spec §6: the user gets back (principal - penalty + interest).
        //
        // The penalty is NOT taken a second time from SafeVault - it was
        // already paid at deposit time via the 80/10/9/1 split (the 20%
        // that didn't land in SafeVault went to token-buy + treasury +
        // liquidity and never came back). So the user's full SafeVault
        // slice ($800 on a $1000 deposit) returns to them, and Treasury
        // tops up any interest portion.
        //
        // Previously this routine subtracted the penalty AGAIN from the
        // SafeVault slice, so a $1000 deposit returned $600 instead of
        // $800 - exactly the bug the user reported. Fixed by computing
        // userPayout as (principal - penalty + interest) and only
        // capping it at the available SafeVault slice for the vault
        // portion, with Treasury covering the rest.
        // §V6.2 - penalty BPS is snapshotted on the Deposit struct at
        // creation (Standard = 20%, Turbo = 50%). Reading from the
        // deposit instead of the protocol-wide constant lets the
        // economics differ per product without exposing existing
        // positions to retroactive parameter changes. The fallback
        // covers pre-V6.2 deposits whose struct never got the new
        // field - they retain the historical 20% behaviour.
        uint256 penaltyBps = deposit.earlyExitPenaltyBps == 0
            ? EARLY_EXIT_PENALTY_BPS
            : deposit.earlyExitPenaltyBps;
        uint256 penalty = RoundingLib.roundDownToProtocol(deposit.principal * penaltyBps, BPS_DENOMINATOR);
        uint256 grossPayout = deposit.principal - penalty + deposit.accruedInterest;
        // §M6 - the borrowed principal is ALREADY in the exiter's wallet, so
        // it comes off the claim rather than being demanded back first. Any
        // loan interest still outstanding after netting is withheld below.
        uint256 userPayout = grossPayout > loanPrincipal ? grossPayout - loanPrincipal : 0;
        // `netSettleLoan` (inside closeLoanForSettlement) already shrank the
        // vault-side claim by `loanPrincipal`, so the releasable slice is
        // what remains of the original safeVaultAmount.
        uint256 vaultRemaining = deposit.safeVaultAmount > loanPrincipal
            ? deposit.safeVaultAmount - loanPrincipal
            : 0;
        uint256 vaultPayout = userPayout > vaultRemaining ? vaultRemaining : userPayout;
        uint256 treasuryPortion = userPayout - vaultPayout;
        // Loan interest is collected by simply NOT paying it out: Treasury
        // keeps USDC it would otherwise have settled. Anything the Treasury
        // leg can't absorb is taken from the vault leg as physical USDC, and
        // anything beyond BOTH legs is written off — identical handling to
        // `settleMaturedNet` and the liquidation path.
        uint256 interestWithheld = loanInterest < treasuryPortion ? loanInterest : treasuryPortion;
        uint256 treasurySettlement = treasuryPortion - interestWithheld;
        uint256 interestFromVault = loanInterest - interestWithheld;
        if (interestFromVault > vaultPayout) {
            interestFromVault = vaultPayout;
        }
        uint256 principalClosed = deposit.principal;
        // Mark the interest paid out as realized so the now-Exited deposit
        // cannot have this interest re-credited by a later accrual read.
        deposit.realizedInterest += deposit.accruedInterest;
        deposit.state = DepositState.Exited;
        if (interestFromVault > 0) {
            vaultPayout -= interestFromVault;
            ISafeVault(safeVault).releasePrincipal(depositId, treasury, interestFromVault);
            ITreasury(treasury).returnLoanCapital(depositId, 0, interestFromVault);
        }
        // earlyExitRelease returns the forfeited SafeVault residual it has
        // already physically moved to the Distribution Reserve (and booked
        // there via creditEarlyExitPenalty). For Standard exits this is 0.
        uint256 retainedBuffer = ISafeVault(safeVault).earlyExitRelease(depositId, msg.sender, vaultPayout);
        if (treasurySettlement != 0) {
            // Interest (plus any sub-vault-slice top-up) is funded from
            // Treasury.interestReserve. Reverts if the reserve is dry,
            // which is the intended solvency guard.
            ITreasury(treasury).paySettlement(depositId, msg.sender, treasurySettlement);
        }

        // Spec §4.5 / §8: the early-exit penalty goes to the Distribution
        // Reserve. Split the booking to avoid double-counting:
        //   - `retainedBuffer` (the forfeited SafeVault residual) arrived as
        //     FRESH USDC and was already booked by creditEarlyExitPenalty.
        //   - the remainder (`penalty - retainedBuffer`) is value that was
        //     already realized into reserves at deposit time via the
        //     80/10/9/1 split, so it is only re-bucketed (no fresh USDC).
        uint256 realizedAtDeposit = penalty > retainedBuffer ? penalty - retainedBuffer : 0;
        if (realizedAtDeposit != 0) {
            ITreasury(treasury).recordEarlyExitPenalty(depositId, realizedAtDeposit);
        }
        try ITreasury(treasury).unregisterActivePrincipal(principalClosed) {} catch {}

        emit EarlyExit(depositId, msg.sender, userPayout, penalty);
        emit DepositStateChanged(depositId, DepositState.Exited);
        // Burn the NFT so the token cannot outlive the exited deposit.
        IDepositNFT(depositNft).burn(depositId);
    }

    /**
     * Charges the abandoned-phase 5%/month maintenance fee on a single
     * deposit. Anyone can call this once at least one full month has
     * elapsed since the last assessment (or since the abandoned cliff).
     * The fee is deducted from the SafeVault portion and routed to the
     * Marketing/Ops wallet - Treasury balances are never touched.
     */
    function chargeAbandonedFee(uint256 depositId) external nonReentrant whenNotPaused returns (uint256 feeAmount) {
        Deposit storage deposit = _existingDeposit(depositId);
        if (deposit.state != DepositState.Abandoned) {
            revert InvalidDepositState(depositId, deposit.state);
        }
        if (marketingWallet == address(0)) {
            revert MarketingWalletNotSet();
        }

        uint64 cliff = deposit.maturityTime + uint64(DORMANT_GRACE_PERIOD);
        uint64 lastAssessed = _lastFeeAssessment[depositId];
        if (lastAssessed < cliff) {
            lastAssessed = cliff;
        }
        if (block.timestamp < lastAssessed + 30 days) {
            revert NoFeeDue();
        }

        uint256 elapsedMonths = (block.timestamp - lastAssessed) / 30 days;
        feeAmount = RoundingLib.roundDownToProtocol(
            deposit.principal * ABANDONED_MONTHLY_FEE_BPS * elapsedMonths,
            BPS_DENOMINATOR
        );
        if (feeAmount > deposit.safeVaultAmount) {
            feeAmount = deposit.safeVaultAmount;
        }
        if (feeAmount == 0) {
            revert NoFeeDue();
        }

        // Spec §5: the 5% fee is computed against the original principal so
        // the schedule stays linear (~20 months full depletion). We only
        // decrement safeVaultAmount - `deposit.principal` is preserved as
        // the immutable original-size record so indexers can still see it.
        deposit.safeVaultAmount -= feeAmount;
        _lastFeeAssessment[depositId] = uint64(lastAssessed + elapsedMonths * 30 days);
        // §Code-Review H4 (Jul 2026) - decay fees route to the Treasury's
        // marketing budget, NOT straight to the marketing wallet. Paying the
        // wallet directly bypassed every §11.6/§11.7 control: the per-period
        // extraction cap, the TVL activation gate and the interest-coverage
        // solvency lock. It also AMPLIFIED the cap, because MarketingEngine
        // sizes each period's allowance from `marketingWalletBalance()` - so
        // every direct fee payment raised the ceiling for the next legitimate
        // pull. Booking the fee as `marketingClaimable` puts it behind the
        // same gates as all other marketing spend.
        ISafeVault(safeVault).releasePrincipal(depositId, treasury, feeAmount);
        ITreasury(treasury).creditMarketingFromDecay(depositId, feeAmount);

        emit AbandonedFeeAssessed(depositId, feeAmount, elapsedMonths);
        emit AbandonedFeeCharged(depositId, feeAmount, elapsedMonths);
    }

    function markDormant(uint256 depositId) external whenNotPaused {
        Deposit storage deposit = _existingDeposit(depositId);
        if (LifecycleManager.canMature(deposit.state, deposit.maturityTime, block.timestamp)) {
            deposit.accruedInterest = _calculateAccruedInterest(deposit, block.timestamp);
            deposit.state = DepositState.Matured;
            emit DepositStateChanged(depositId, DepositState.Matured);
        }
        LifecycleManager.requireDormantTransition(deposit.state);

        deposit.state = DepositState.Dormant;
        deposit.dormantTime = uint64(block.timestamp);
        emit DepositStateChanged(depositId, DepositState.Dormant);
    }

    function markAbandoned(uint256 depositId) external whenNotPaused {
        Deposit storage deposit = _existingDeposit(depositId);
        // Inline state + grace-period checks (single source of truth) so the
        // depositId can be attached to the revert data for indexers.
        if (deposit.state != DepositState.Dormant) {
            revert InvalidDepositState(depositId, deposit.state);
        }
        if (block.timestamp < deposit.maturityTime + DORMANT_GRACE_PERIOD) {
            revert GracePeriodActive(depositId);
        }

        deposit.state = DepositState.Abandoned;
        emit DepositStateChanged(depositId, DepositState.Abandoned);
    }

    function abandonedFeePreview(uint256 depositId) external view returns (uint256 feeAmount) {
        // Mirror chargeAbandonedFee exactly so the preview returns what the
        // charge would deduct at the same block.timestamp: anchor on
        // max(_lastFeeAssessment, cliff), require a full elapsed month, use
        // the same protocol rounding, and cap at the SafeVault slice.
        Deposit storage deposit = _existingDeposit(depositId);
        if (deposit.state != DepositState.Abandoned) {
            return 0;
        }

        uint64 cliff = deposit.maturityTime + uint64(DORMANT_GRACE_PERIOD);
        uint64 lastAssessed = _lastFeeAssessment[depositId];
        if (lastAssessed < cliff) {
            lastAssessed = cliff;
        }
        if (block.timestamp < lastAssessed + 30 days) {
            return 0;
        }

        uint256 elapsedMonths = (block.timestamp - lastAssessed) / 30 days;
        feeAmount = RoundingLib.roundDownToProtocol(
            deposit.principal * ABANDONED_MONTHLY_FEE_BPS * elapsedMonths,
            BPS_DENOMINATOR
        );
        if (feeAmount > deposit.safeVaultAmount) {
            feeAmount = deposit.safeVaultAmount;
        }
    }

    function getDeposit(uint256 depositId) external view returns (Deposit memory deposit) {
        return _deposits[depositId];
    }

    function _existingDeposit(uint256 depositId) private view returns (Deposit storage deposit) {
        deposit = _deposits[depositId];
        if (deposit.owner == address(0)) {
            revert UnknownDeposit(depositId);
        }
    }

    /**
     * §Phase 2 Marketplace - reverts if the deposit's NFT is listed for
     * secondary sale. Gates every value-extracting path (interest withdrawal,
     * early exit, settle, rollover, abandoned withdraw) so that while a bond
     * sits on the marketplace its accrued yield can neither be drained by the
     * seller nor the position closed out from under a pending buyer. The
     * listing lock lives on the NFT (the marketplace-owned flag); interest
     * keeps accruing throughout, it simply cannot be realised until the token
     * is sold or delisted.
     */
    function _requireNotListed(uint256 depositId) private view {
        if (IDepositNFT(depositNft).isListed(depositId)) {
            revert DepositListed(depositId);
        }
    }

    /**
     * §Phase 2 Marketplace - public view of a deposit's listing lock, so the
     * Lending module can refuse to open a loan against a listed deposit. Without
     * this a seller could list, then borrow out the deposit's collateral and
     * sell the debt to a buyer who paid for un-drained collateral.
     */
    function isDepositListed(uint256 depositId) external view returns (bool) {
        return IDepositNFT(depositNft).isListed(depositId);
    }

    function _calculateAccruedInterest(Deposit storage deposit, uint256 timestamp) private view returns (uint256) {
        // Delegated to LifecycleManager so accrual math stays a single
        // testable routine across every settlement path.
        return LifecycleManager.calculateAccruedInterest(deposit, timestamp, BPS_DENOMINATOR, DAYS_PER_YEAR);
    }

    function _safeTransfer(IERC20 token, address to, uint256 amount) private {
        if (!token.transfer(to, amount)) {
            revert TransferFailed();
        }
    }

    function _safeTransferFrom(IERC20 token, address from, address to, uint256 amount) private {
        if (!token.transferFrom(from, to, amount)) {
            revert TransferFailed();
        }
    }

    // __gap shrunk from 36 -> 35: `cyrContract` consumed one storage slot.
    // Then 35 -> 34: §V6.3 2A `liquidityManager` consumed one more.
    uint256[34] private __gap;
}

/**
 * @title SafeVault
 * @notice Per-deposit principal custody PLUS the lending pool.
 *
 * Spec §6 invariant: each deposit's loan capital comes EXCLUSIVELY from
 * its own SafeVault slice - never from another deposit's slice. The
 * `_loanedAgainstDeposit` mapping tracks how much of each deposit's
 * collateral has been disbursed as a loan; `availableForLoan` returns
 * the remaining headroom (capped externally by Lending's max-LTV).
 *
 * Solvency invariants:
 *   - principalOf(id) >= loanedAgainst(id) for every id
 *   - SafeVault USDC balance >= sum(principalOf) - sum(loanedAgainst)
 *     so every depositor without a loan can always exit/settle in full.
 *
 * Capital flows:
 *   - openDeposit       -> accountPrincipal             (USDC in, claim up)
 *   - loan opens        -> disburseLoan                 (USDC out, loaned up)
 *   - loan repays       -> acceptRepayment              (USDC in, loaned down)
 *   - liquidation       -> forfeitCollateral            (claim -> 0, debt -> 0,
 *                                                       liquidator paid bonus)
 *   - early exit        -> earlyExitRelease             (user gets payout,
 *                                                       penalty stays as buffer)
 *   - settle matured    -> releasePrincipal             (entire slice -> user;
 *                                                       reverts if loan open)
 */
contract SafeVault is ISafeVault, GilderModule {
    IERC20 public asset;
    address public bondContract;
    // Distribution Reserve (Treasury) recipient for forfeited early-exit
    // penalty USDC, so the penalty physically reaches the reserve per spec
    // §4.5/§8 rather than being siloed in the dead `protocolBuffer` slot.
    address public treasury;
    uint256 public accountedPrincipal;
    uint256 public totalLoaned;
    uint256 public protocolBuffer;
    mapping(uint256 depositId => uint256 amount) private _principalByDeposit;
    mapping(uint256 depositId => uint256 amount) private _loanedAgainstDeposit;

    error LoanExceedsAvailable(uint256 requested, uint256 available);
    error OverRepayment(uint256 paid, uint256 owed);
    error NoLoanToForfeit(uint256 depositId);
    error SettleBlockedByLoan(uint256 depositId, uint256 outstanding);
    error InsufficientUserPayout(uint256 requested, uint256 slice);

    function initialize(address admin, address asset_, address bondContract_) external {
        _initializeAccessControl(admin);
        if (asset_ == address(0) || bondContract_ == address(0)) {
            revert ZeroAddress();
        }
        asset = IERC20(asset_);
        bondContract = bondContract_;
    }

    /** Sets the Distribution Reserve (Treasury) that forfeited early-exit
     *  penalty USDC is routed to. Must be wired before any Turbo early exit
     *  for the penalty to reach the reserve. */
    function setTreasury(address treasury_) external onlyRole(PARAMETER_ROLE) {
        if (treasury_ == address(0)) {
            revert ZeroAddress();
        }
        treasury = treasury_;
    }

    function accountPrincipal(uint256 depositId, uint256 amount) external onlyRole(BOND_ENGINE_ROLE) whenNotPaused {
        _principalByDeposit[depositId] += amount;
        accountedPrincipal += amount;
        emit PrincipalAccounted(depositId, amount);
    }

    /**
     * Full-slice release on settle/abandoned-fee. Refuses if any loan
     * is still outstanding against the deposit - the lifecycle layer
     * already enforces this on `settleMatured`, but we double-check at
     * the vault so dormant-fee / abandoned-fee paths can't accidentally
     * release pledged collateral.
     */
    function releasePrincipal(uint256 depositId, address recipient, uint256 amount) external onlyRole(BOND_ENGINE_ROLE) whenNotPaused {
        if (recipient == address(0)) {
            revert ZeroAddress();
        }
        uint256 outstanding = _loanedAgainstDeposit[depositId];
        if (outstanding != 0 && amount > _principalByDeposit[depositId] - outstanding) {
            revert SettleBlockedByLoan(depositId, outstanding);
        }
        _principalByDeposit[depositId] -= amount;
        accountedPrincipal -= amount;
        if (!asset.transfer(recipient, amount)) {
            revert TransferFailed();
        }
        emit PrincipalReleased(depositId, recipient, amount);
    }

    /**
     * Disburses loan capital from a SINGLE deposit's collateral slice.
     * `availableForLoan` (= principal - already-loaned) is the hard cap.
     * Lending enforces its own 75% LTV on top.
     *
     * Crucially: this withdraws USDC from the SafeVault contract balance
     * but leaves `_principalByDeposit[depositId]` untouched - the user's
     * claim is preserved. `_loanedAgainstDeposit[depositId]` records the
     * debt so settle/exit math knows to deduct.
     */
    function disburseLoan(uint256 depositId, address borrower, uint256 amount)
        external
        onlyRole(LENDING_OPERATOR_ROLE)
    whenNotPaused {
        if (borrower == address(0)) {
            revert ZeroAddress();
        }
        uint256 principal = _principalByDeposit[depositId];
        uint256 outstanding = _loanedAgainstDeposit[depositId];
        uint256 available = principal - outstanding;
        if (amount > available) {
            revert LoanExceedsAvailable(amount, available);
        }
        _loanedAgainstDeposit[depositId] = outstanding + amount;
        totalLoaned += amount;
        if (!asset.transfer(borrower, amount)) {
            revert TransferFailed();
        }
        emit LoanDisbursed(depositId, borrower, amount);
    }

    /**
     * Accepts loan principal repayment from the borrower. Interest paid
     * goes to Treasury via a separate path (handled by Lending) - this
     * method strictly returns principal capital to the SafeVault pool.
     *
     * Pulls USDC directly from `from` via transferFrom - `from` must
     * have approved SafeVault as a spender. Kept for direct integrations
     * and unit tests; the live Lending flow uses `noteRepayment` instead
     * so the borrower only needs to approve Lending.
     */
    function acceptRepayment(uint256 depositId, address from, uint256 amount)
        external
        onlyRole(LENDING_OPERATOR_ROLE)
    whenNotPaused {
        uint256 outstanding = _loanedAgainstDeposit[depositId];
        if (amount > outstanding) {
            revert OverRepayment(amount, outstanding);
        }
        if (!asset.transferFrom(from, address(this), amount)) {
            revert TransferFailed();
        }
        _loanedAgainstDeposit[depositId] = outstanding - amount;
        totalLoaned -= amount;
        emit LoanRepaymentAccepted(depositId, from, amount);
    }

    /**
     * Accounting-only counterpart to `acceptRepayment`. The caller (the
     * Lending contract) must have ALREADY transferred `amount` USDC into
     * SafeVault before invoking this - typically via a plain
     * `asset.transfer(safeVault, principalPaid)` right before the call.
     *
     * Used by the borrower-facing repay flow so the borrower only needs
     * a single approval (Lending) rather than two (Lending + SafeVault).
     */
    function noteRepayment(uint256 depositId, address from, uint256 amount)
        external
        onlyRole(LENDING_OPERATOR_ROLE)
    whenNotPaused {
        uint256 outstanding = _loanedAgainstDeposit[depositId];
        if (amount > outstanding) {
            revert OverRepayment(amount, outstanding);
        }
        _loanedAgainstDeposit[depositId] = outstanding - amount;
        totalLoaned -= amount;
        // Emit the actual payer (the borrower) so the event matches
        // acceptRepayment's semantics rather than the Lending operator.
        emit LoanRepaymentAccepted(depositId, from, amount);
    }

    /**
     * Liquidation: forfeit the full collateral slice, clear the debt,
     * pay the liquidator their bonus, and return the REMAINING principal
     * to the depositor (spec §14.5: "remaining principal returned to
     * user").
     *
     * Math: surplus = principalSlice - outstanding. Liquidator gets
     * `liquidatorBonus` (bounded by surplus); whatever is left after the
     * bonus is paid straight back to `depositor`. No other depositor's
     * slice is touched, so the capital-protection invariant holds.
     */
    function forfeitCollateral(uint256 depositId, address depositor, address liquidator, uint256 liquidatorBonus)
        external
        onlyRole(LENDING_OPERATOR_ROLE)
        whenNotPaused returns (uint256 forfeited, uint256 outstandingCleared)
    {
        if (liquidator == address(0) || depositor == address(0)) {
            revert ZeroAddress();
        }
        forfeited = _principalByDeposit[depositId];
        outstandingCleared = _loanedAgainstDeposit[depositId];
        if (outstandingCleared == 0) {
            revert NoLoanToForfeit(depositId);
        }
        uint256 surplus = forfeited > outstandingCleared ? forfeited - outstandingCleared : 0;
        if (liquidatorBonus > surplus) {
            liquidatorBonus = surplus;
        }
        uint256 depositorRefund = surplus - liquidatorBonus;
        _principalByDeposit[depositId] = 0;
        _loanedAgainstDeposit[depositId] = 0;
        accountedPrincipal -= forfeited;
        totalLoaned -= outstandingCleared;
        if (liquidatorBonus > 0) {
            if (!asset.transfer(liquidator, liquidatorBonus)) {
                revert TransferFailed();
            }
        }
        if (depositorRefund > 0) {
            if (!asset.transfer(depositor, depositorRefund)) {
                revert TransferFailed();
            }
        }
        emit CollateralForfeited(depositId, liquidator, forfeited, outstandingCleared, liquidatorBonus);
    }

    /**
     * Early-exit release: hand `userPayout` (principal - penalty) to the
     * depositor and route the remainder (the forfeited penalty surplus) to
     * the Distribution Reserve (Treasury) as FRESH USDC. The deposit's
     * slice is fully closed out - `_principalByDeposit` -> 0.
     *
     * Spec §4.5/§8: the forfeited penalty belongs to the Distribution
     * Reserve. For the Standard product retainedBuffer is 0 (the user's
     * full SafeVault slice returns), so this is a no-op transfer. For the
     * Turbo product the ~30% residual physically leaves SafeVault and is
     * booked into the reserve via `creditEarlyExitPenalty`. If no treasury
     * has been wired yet it falls back to the legacy `protocolBuffer` slot.
     */
    function earlyExitRelease(uint256 depositId, address recipient, uint256 userPayout)
        external
        onlyRole(BOND_ENGINE_ROLE)
        whenNotPaused returns (uint256 retainedBuffer)
    {
        if (recipient == address(0)) {
            revert ZeroAddress();
        }
        uint256 slice = _principalByDeposit[depositId];
        if (userPayout > slice) {
            revert InsufficientUserPayout(userPayout, slice);
        }
        retainedBuffer = slice - userPayout;
        _principalByDeposit[depositId] = 0;
        accountedPrincipal -= slice;
        if (userPayout > 0) {
            if (!asset.transfer(recipient, userPayout)) {
                revert TransferFailed();
            }
        }
        if (retainedBuffer > 0) {
            if (treasury != address(0)) {
                // Move the forfeited penalty out of SafeVault to the
                // Distribution Reserve and book it there as fresh inflow.
                if (!asset.transfer(treasury, retainedBuffer)) {
                    revert TransferFailed();
                }
                ITreasury(treasury).creditEarlyExitPenalty(depositId, retainedBuffer);
            } else {
                // Fallback for pre-wiring: keep the legacy buffer behaviour.
                protocolBuffer += retainedBuffer;
            }
        }
        emit EarlyExitReleased(depositId, recipient, userPayout, retainedBuffer);
    }

    /**
     * §Code-Review N4 (Jul 2026) - accounting-only loan close used by the
     * atomic net-settlement path. The loaned USDC physically left the vault
     * at `disburseLoan` time; here the deposit's own claim absorbs the debt:
     * both the claim and the outstanding-loan record shrink by the same
     * amount, so the vault's solvency invariant
     * (balance >= accountedPrincipal - totalLoaned) is untouched. No USDC
     * moves and no other depositor's slice is involved.
     */
    function netSettleLoan(uint256 depositId)
        external
        onlyRole(LENDING_OPERATOR_ROLE)
        whenNotPaused returns (uint256 outstandingCleared)
    {
        outstandingCleared = _loanedAgainstDeposit[depositId];
        if (outstandingCleared == 0) {
            return 0;
        }
        _loanedAgainstDeposit[depositId] = 0;
        totalLoaned -= outstandingCleared;
        _principalByDeposit[depositId] -= outstandingCleared;
        accountedPrincipal -= outstandingCleared;
        emit LoanNetSettledAtVault(depositId, outstandingCleared);
    }

    function principalOf(uint256 depositId) external view returns (uint256 amount) {
        return _principalByDeposit[depositId];
    }

    function loanedAgainst(uint256 depositId) external view returns (uint256 amount) {
        return _loanedAgainstDeposit[depositId];
    }

    function availableForLoan(uint256 depositId) external view returns (uint256 amount) {
        uint256 principal = _principalByDeposit[depositId];
        uint256 outstanding = _loanedAgainstDeposit[depositId];
        return principal > outstanding ? principal - outstanding : 0;
    }

    uint256[42] private __gap;
}

/**
 * @title Treasury  (canonical name: "Distribution Reserve")
 * @notice The protocol's USDC reserve + yield-distribution component.
 *
 * NAMING: per the team's naming-clarity convention this contract is the
 * "Distribution Reserve" - it does NOT trade. It only holds and
 * distributes USDC for yield and maturity obligations:
 *   - receives the 9% deposit allocation into structured reserves
 *     (interest / buyback / operational),
 *   - pays settlements (yield + matured principal) to wallets,
 *   - books early-exit penalties, and
 *   - runs the §11 premium-profit waterfall.
 * The actual market trading against the GIL/USDC LP is the separate
 * `TreasuryExecutor` contract (canonical name "Market Treasury").
 *
 * The on-chain identifier stays `Treasury` so deployed ABIs / addresses
 * / integrations are unaffected - "Distribution Reserve" is the
 * user-facing and documentation name.
 */

/**
 * §TVG - minimal view of the Market Treasury executor's canonical TVG
 * numerator ("Treasury USDC Assets" = (LP USDC - seed) + non-LP protocol
 * USDC). The Treasury delegates the pool-reserve read to the executor.
 */
interface ITreasuryUsdcAssets {
    function treasuryUsdcAssets() external view returns (uint256);
}

contract Treasury is ITreasury, GilderModule {
    uint256 public constant INTEREST_RESERVE_BPS = 5_000;
    uint256 public constant BUYBACK_RESERVE_BPS = 3_000;
    uint256 public constant OPERATIONAL_RESERVE_BPS = 2_000;
    uint256 public constant BPS_DENOMINATOR = 10_000;
    // §11.3 Twin-Engine 5:1 split of premium-zone profit surplus.
    uint256 public constant MARKETING_SPLIT_BPS = 1_667; // 16.67% -> Marketing
    uint256 public constant TREASURY_SPLIT_BPS = 8_333;  // 83.33% -> Treasury
    // §11.4 share of the Treasury portion earmarked for marketing token
    // refill (open-market purchases routed to the Marketing/Ops wallet).
    uint256 public constant MARKETING_REFILL_BPS = 2_000; // 20%

    IERC20 public asset;
    address public bondContract;
    uint256 public totalAllocated;
    uint256 public interestReserve;
    uint256 public buybackReserve;
    uint256 public operationalReserve;
    uint256 public solvencyFloor;
    uint256 public outstandingLoanPrincipal;
    // §G.2 / §11.3 - sum of every Active deposit's principal. Drives the
    // dynamic Tier-1 coverage target (`activePrincipal x 0.11`), which
    // represents 6 months of forward yield obligation + a 10% buffer.
    // Maintained by BondContract via register/unregister on every
    // open / settle / exit / abandon / rollover / liquidate path.
    uint256 public totalActivePrincipal;
    // §TVG waterfall (client, Jun 2026) - first priority is keeping 6 MONTHS
    // of interest funded. 11% target = 6 x (20% APY / 12) + 10% buffer =
    // 10% + 1%. Lives on the contract as a constant so a future governance
    // lever cannot weaken the solvency invariant arbitrarily.
    uint256 public constant COVERAGE_TARGET_BPS = 1_100;
    // §8 Step E (Tier 2) - the Buyback / Floor-defence Reserve's DYNAMIC
    // target: 5% of Safe Vault TVL (`tier2_target = safe_vault × 0.05` in the
    // v14 math-spec). Applied to SafeVault.accountedPrincipal (the protected
    // principal pool), NOT total deposit principal - Turbo routes only ~50%
    // net into the vault, so basing this on gross principal would overstate
    // the target. The waterfall fills the buyback war-chest up to this before
    // any surplus spills to Operational, so it scales with the protocol
    // instead of sitting at a static number. `buybackFloorRequired` remains
    // an optional manual override taken as the LARGER of the two.
    uint256 public constant BUYBACK_FLOOR_BPS = 500;
    // Cumulative early-exit penalties booked against Treasury (spec §8).
    // Tracking-only: the penalty's USDC already entered reserves at
    // deposit time via the 80/10/9/1 split, so this counter is for
    // transparency / indexing and is NOT re-added to a reserve bucket.
    uint256 public earlyExitPenaltyTotal;
    // §11: USDC earmarked for the Marketing/Ops wallet by the premium-
    // profit waterfall, claimable only through the MarketingEngine.
    uint256 public marketingClaimable;
    // §11.3 Step 1 - minimum interest reserve the waterfall must restore
    // before any surplus is split. Also the §11.7 solvency-lock floor.
    uint256 public interestCoverageRequired;
    // §11.3 Step 2 - minimum buyback reserve for TVT-floor defence.
    uint256 public buybackFloorRequired;
    address public marketingEngine;
    // M4 - Consolidated Yield Reinvestment. `reinvestmentVault` is the
    // sole address authorised to draw deferred-bonus USDC from Treasury;
    // `reinvestmentBonusPaid` accumulates every bonus the deferred-
    // settlement model has materialized, the Treasury-side counterpart
    // to the CYR module's own liability accounting (used by the backend
    // settlement-reconciliation service).
    address public reinvestmentVault;
    uint256 public reinvestmentBonusPaid;
    // §10 - Treasury Execution. `treasuryExecutor` is the keeper-callable
    // engine authorised to draw `buybackReserve` USDC for buybacks and to
    // sell the Treasury's GIL inventory in the premium zone; `gilToken`
    // is the GIL ERC-20 that inventory is denominated in.
    address public gilToken;
    address public treasuryExecutor;
    // §V6.3 Issue 2A - the deposit-time symmetric LP top-up leg. Authorised
    // to draw paired GIL from this Treasury's inventory via `fundLiquidity`.
    address public liquidityManager;
    // §11 Tier-3 - the 5:1 premium-surplus split only activates once
    // protocol TVL (proxied by `totalAllocated`) crosses this gate. Below
    // it, the entire surplus stays in the Distribution Reserve as backing
    // (0% marketing). Kept equal to MarketingEngine.tvlActivationThreshold
    // so the split-enable and extraction-enable thresholds coincide.
    uint256 public surplusSplitTvlGate;
    // §11.4 - USDC earmarked from the Tier-4 marketing refill pending an
    // on-market GIL buy delivered to the Marketing/Ops wallet. Tracked
    // separately from `marketingClaimable` so the refill is never paid out
    // as raw USDC via claimMarketing.
    uint256 public marketingRefillPendingGilBuy;
    // §4.5/§8 - SafeVault address authorised to deliver forfeited early-exit
    // penalty USDC into the Distribution Reserve via creditEarlyExitPenalty.
    address public safeVault;
    // §G.4 - deferred yield liability, AGGREGATE. When a settlement cannot be
    // funded from live reserves the shortfall is booked here rather than
    // defaulted; the premium-profit waterfall repays it (ahead of the buyback
    // floor) as reserves recover. Per §G.5 this is the SUM of
    // `depositUnfundedYield` - the per-deposit breakdown is authoritative and
    // this scalar is kept in lockstep for the coverage/waterfall math.
    uint256 public unfundedYield;

    /* ------------------------------------------------------------------ *
     *  §G.5 - RING-FENCED PER-DEPOSIT YIELD
     * ------------------------------------------------------------------
     *  Each deposit's 9% structural seed is isolated to that deposit's own
     *  obligations: a later cohort's seed must NEVER back-pay an earlier
     *  cohort's missed yield. Deferred yield (§G.4) is likewise tracked per
     *  deposit and repaid oldest-first.
     *
     *  Layered as an ATTRIBUTION ledger over the existing aggregate, so none of
     *  the coverage / solvency / waterfall math changes:
     *
     *      interestReserve == totalRingFencedYield + <global unencumbered>
     *
     *  - `depositYieldReserve[id]` is deposit `id`'s ring-fenced 9% seed.
     *  - The global portion (interestReserve - totalRingFencedYield) is
     *    UNENCUMBERED money: harvest/skim proceeds, deficit pulls, early-exit
     *    penalties. It may fund ANY deposit, which is what keeps the §G.4
     *    back-pay working while the isolation still holds.
     *  - A settlement for deposit `id` spends `id`'s own seed first, then the
     *    global portion. It can never reach another deposit's seed.
     *
     *  NB: a seed self-funds ~5.4 months of the 20% APR obligation (9/20 of a
     *  year). Past that horizon a deposit's yield draws on unencumbered income
     *  or defers as a §G.4 liability - it is never met from a sibling's seed.
     * ------------------------------------------------------------------ */

    /// Deposit `id`'s ring-fenced share of `interestReserve` (its 9% seed,
    /// plus any back-pay healed specifically for it).
    mapping(uint256 => uint256) public depositYieldReserve;
    /// Sum of `depositYieldReserve` - the encumbered slice of interestReserve.
    uint256 public totalRingFencedYield;
    /// Deposit `id`'s missed (deferred) yield. Sums to `unfundedYield`.
    mapping(uint256 => uint256) public depositUnfundedYield;
    /// Deposit ids in the order their yield was first missed; the §G.4 waterfall
    /// repays them from the front.
    uint256[] private _unfundedQueue;
    /// Read cursor into `_unfundedQueue`; entries before it are fully healed.
    uint256 public unfundedQueueHead;

    /// Max queue entries healed in a single waterfall call - bounds gas so a
    /// long backlog can never make `processPremiumProfit` un-callable. Any
    /// remainder heals on the next inflow (still strictly oldest-first).
    uint256 public constant MAX_HEAL_ITERATIONS = 100;

    /// §G.5 - a deposit's 9% seed was ring-fenced to it at allocation time.
    event DepositYieldRingFenced(uint256 indexed depositId, uint256 amount, uint256 depositReserve);
    /// §G.5 - a settlement spent `fromOwnSeed` of the deposit's own ring-fenced
    /// reserve plus `fromGlobalPool` of unencumbered (harvest/treasury) money.
    event DepositYieldSpent(uint256 indexed depositId, uint256 fromOwnSeed, uint256 fromGlobalPool);
    /// §G.4 - a deposit missed yield and joined/extended the back-pay queue.
    event DepositUnfundedYieldAccrued(uint256 indexed depositId, uint256 amount, uint256 depositOutstanding);
    /// §G.4 - the waterfall back-paid `amount` of a deposit's missed yield.
    event DepositUnfundedYieldHealed(uint256 indexed depositId, uint256 amount, uint256 depositOutstanding);

    error InsufficientReserve(uint256 requested, uint256 available);
    /// §G.5 - a settlement for `depositId` needed more than its own ring-fenced
    /// seed plus the unencumbered global pool. Another depositor's seed is not
    /// reachable, so the shortfall must be booked as deferred yield (§G.4).
    error RingFencedYieldExhausted(uint256 depositId, uint256 shortfall, uint256 globalAvailable);
    error SolvencyFloorBreached(uint256 balanceAfter, uint256 floor);
    error NotMarketingEngine(address caller);
    error MarketingSolvencyLocked(uint256 interestReserve_, uint256 required);
    error NotReinvestmentVault(address caller);
    error NotTreasuryExecutor(address caller);
    error NotLiquidityManager(address caller);
    error NotSafeVault(address caller);

    // §G.4 - deferred yield liability lifecycle.
    event UnfundedYieldAccrued(uint256 amount, uint256 total);
    event UnfundedYieldHealed(uint256 amount, uint256 remaining);

    function initialize(address admin, address asset_, address bondContract_) external {
        _initializeAccessControl(admin);
        if (asset_ == address(0) || bondContract_ == address(0)) {
            revert ZeroAddress();
        }
        asset = IERC20(asset_);
        bondContract = bondContract_;
        // §11.3 - bind the public split constants together so the advertised
        // TREASURY_SPLIT_BPS getter can never silently diverge from the
        // executed waterfall math (1667 + 8333 == 10000, exact, no dust).
        require(MARKETING_SPLIT_BPS + TREASURY_SPLIT_BPS == BPS_DENOMINATOR, "split bps != 10000");
        // §11.1 - default TVL gate for the Tier-3 surplus split ($1M, USDC 6dp),
        // matching MarketingEngine.tvlActivationThreshold.
        surplusSplitTvlGate = 1_000_000 * 1e6;
    }

    /** Governance can configure a minimum USDC balance the contract must
     *  retain after any outflow. Lets ops set a buffer above strict
     *  bucket accounting in case external accrual lags. */
    function setSolvencyFloor(uint256 floor) external onlyRole(PARAMETER_ROLE) {
        solvencyFloor = floor;
        emit SolvencyFloorUpdated(floor);
    }

    /** §11.1 - governance lever for the Tier-3 surplus-split TVL gate.
     *  Keep equal to MarketingEngine.tvlActivationThreshold. */
    function setSurplusSplitTvlGate(uint256 gate) external onlyRole(PARAMETER_ROLE) {
        surplusSplitTvlGate = gate;
    }

    function receiveAllocation(uint256 depositId, uint256 amount) external onlyRole(BOND_ENGINE_ROLE) whenNotPaused {
        // §V6.3 Issue 2D - the deposit's 9% structural seed funds yield
        // obligations directly, so it lands 100% in Tier 1 (interest reserve),
        // NOT a 50/30/20 split. This is what makes each cohort self-funding
        // for its first ~5.4 months (Standard) / ~9.8 months (Turbo). Tier 2
        // (buyback) and the operational bucket refill from the harvest
        // waterfall instead. (V6.2 split is superseded by the brief.)
        totalAllocated += amount;
        interestReserve += amount;
        // §G.5 - the 9% seed is ring-fenced to this deposit. It stays inside the
        // interestReserve aggregate (so all coverage math is unchanged) but is
        // recorded as encumbered: no other deposit's settlement can spend it.
        depositYieldReserve[depositId] += amount;
        totalRingFencedYield += amount;
        emit TreasuryAllocationReceived(depositId, amount);
        emit DepositYieldRingFenced(depositId, amount, depositYieldReserve[depositId]);
        emit ReserveBucketsUpdated(interestReserve, buybackReserve, operationalReserve);
    }

    /**
     * The UNENCUMBERED slice of `interestReserve` - harvest/skim proceeds,
     * deficit pulls, early-exit penalties. This is the only pool that may fund a
     * deposit beyond its own ring-fenced seed. Saturating: a catastrophic drain
     * (`_drainReserves`) can eat into the encumbered slice, in which case there
     * is simply nothing unencumbered left.
     */
    function globalYieldAvailable() public view returns (uint256) {
        uint256 fenced = totalRingFencedYield;
        return interestReserve > fenced ? interestReserve - fenced : 0;
    }

    /**
     * §G.4 - books a yield shortfall as a deferred liability, ATTRIBUTED to the
     * deposit that missed it. The obligation is recorded rather than defaulted
     * and is later repaid oldest-first by the premium-profit waterfall.
     * The deposit joins the FIFO queue the first time it misses.
     */
    function accrueUnfundedYield(uint256 depositId, uint256 amount) external onlyRole(BOND_ENGINE_ROLE) whenNotPaused {
        _accrueUnfundedYield(depositId, amount);
    }

    /**
     * Legacy pooled entry point - books the shortfall against the sentinel
     * deposit id 0 ("unattributed"). Retained so pre-ring-fencing callers keep
     * working; new callers should pass the real depositId.
     */
    function accrueUnfundedYield(uint256 amount) external onlyRole(BOND_ENGINE_ROLE) whenNotPaused {
        _accrueUnfundedYield(0, amount);
    }

    function _accrueUnfundedYield(uint256 depositId, uint256 amount) private {
        if (amount == 0) {
            return;
        }
        // First miss for this deposit -> it takes its place at the back of the
        // FIFO queue. A deposit that misses again while still queued keeps its
        // ORIGINAL position, which is what makes the repayment oldest-first.
        if (depositUnfundedYield[depositId] == 0) {
            _unfundedQueue.push(depositId);
        }
        depositUnfundedYield[depositId] += amount;
        unfundedYield += amount;
        emit DepositUnfundedYieldAccrued(depositId, amount, depositUnfundedYield[depositId]);
        emit UnfundedYieldAccrued(amount, unfundedYield);
    }

    function paySettlement(uint256 depositId, address recipient, uint256 amount) external onlyRole(BOND_ENGINE_ROLE) whenNotPaused {
        if (recipient == address(0)) {
            revert ZeroAddress();
        }
        _enforceSolvencyOnOutflow(amount);
        // §G.5 - attribute the spend to this deposit: its OWN ring-fenced seed
        // is consumed first, the rest comes from unencumbered money.
        _consumeYieldEntitlement(depositId, amount);
        if (!asset.transfer(recipient, amount)) {
            revert TransferFailed();
        }
        _drainReserves(amount);
        // §G.5 - the ring-fence invariant. `_drainReserves` only reaches
        // interestReserve once operational and buyback are exhausted; at that
        // point it would be eating OTHER depositors' seeds. Revert instead - the
        // shortfall is booked as deferred yield (§G.4) via
        // `accrueUnfundedYield(depositId, ...)`.
        if (interestReserve < totalRingFencedYield) {
            revert RingFencedYieldExhausted(
                depositId, totalRingFencedYield - interestReserve, 0
            );
        }
        emit SettlementPaid(depositId, recipient, amount);
        emit ReserveBucketsUpdated(interestReserve, buybackReserve, operationalReserve);
    }

    /**
     * §G.5 attribution. A settlement for `depositId` covers that deposit's yield
     * AND (on early exit / maturity) any principal the SafeVault slice could not
     * cover. Ring-fencing governs WHOSE money is consumed, not what it is spent
     * on, so this simply debits the deposit's own seed first and lets the
     * remainder fall to unencumbered money (operational, buyback, and the global
     * slice of interestReserve - harvest proceeds, penalties, deficit pulls).
     *
     * It never touches another deposit's seed: that is enforced by the
     * post-drain invariant in `paySettlement`.
     */
    function _consumeYieldEntitlement(uint256 depositId, uint256 amount) private {
        uint256 own = depositYieldReserve[depositId];
        if (own == 0) {
            return;
        }
        uint256 fromOwn = amount < own ? amount : own;
        depositYieldReserve[depositId] = own - fromOwn;
        totalRingFencedYield -= fromOwn;
        emit DepositYieldSpent(depositId, fromOwn, amount - fromOwn);
    }

    /**
     * Spec §8.2 reserve priority: the Interest Reserve is the highest-
     * priority bucket (it backs forward yield obligations), so it must
     * be drained LAST. Operational Reserve is subordinate, so it is
     * sacrificed first, then Buyback, and only then Interest. This keeps
     * the protocol's interest-coverage capacity intact for as long as
     * possible on every outflow.
     */
    function _drainReserves(uint256 amount) private {
        if (amount <= operationalReserve) {
            operationalReserve -= amount;
            return;
        }
        uint256 spill = amount - operationalReserve;
        operationalReserve = 0;
        if (spill <= buybackReserve) {
            buybackReserve -= spill;
            return;
        }
        spill -= buybackReserve;
        buybackReserve = 0;
        interestReserve = spill <= interestReserve ? interestReserve - spill : 0;
    }

    /**
     * Spec §4.5 / §8 / §G.3: books an early-exit penalty against Treasury
     * and rebalances reserve buckets so the penalty's USDC value sits in
     * the Distribution Reserve's interest-coverage bucket.
     *
     * The penalty's USDC was already realized into protocol reserves at
     * deposit time via the 80/10/9/1 capital split - re-adding it as a
     * fresh inflow would double-count and inflate accounting beyond the
     * contract's real USDC balance. Instead this routine REBALANCES the
     * existing reserves: it shifts up to `amount` USDC out of the lower-
     * priority operationalReserve (and, if needed, buybackReserve above
     * its TVT-floor target) into interestReserve. Net contract balance is
     * unchanged; spec compliance ("penalty -> Distribution Reserve")
     * is satisfied because interestReserve IS the Distribution Reserve's
     * forward-coverage bucket, and the rebalance preserves the strict
     * §11.7 solvency-lock priority order.
     *
     * The dedicated `earlyExitPenaltyTotal` counter remains as the
     * cumulative indexable figure for transparency.
     */
    function recordEarlyExitPenalty(uint256 depositId, uint256 amount) external onlyRole(BOND_ENGINE_ROLE) whenNotPaused {
        earlyExitPenaltyTotal += amount;
        uint256 remaining = amount;
        if (operationalReserve > 0) {
            uint256 fromOp = remaining < operationalReserve ? remaining : operationalReserve;
            operationalReserve -= fromOp;
            interestReserve += fromOp;
            remaining -= fromOp;
        }
        uint256 buybackFloor_ = buybackFloorTarget();
        if (remaining > 0 && buybackReserve > buybackFloor_) {
            uint256 excess = buybackReserve - buybackFloor_;
            uint256 fromBuyback = remaining < excess ? remaining : excess;
            buybackReserve -= fromBuyback;
            interestReserve += fromBuyback;
            remaining -= fromBuyback;
        }
        emit EarlyExitPenaltyRecorded(depositId, amount);
        emit ReserveBucketsUpdated(interestReserve, buybackReserve, operationalReserve);
    }

    /** §11: registers the MarketingEngine authorised to pull `marketingClaimable`. */
    function setMarketingEngine(address engine) external onlyRole(PARAMETER_ROLE) {
        marketingEngine = engine;
        emit MarketingEngineUpdated(engine);
    }

    /** §4.5/§8: registers the SafeVault authorised to deliver forfeited
     *  early-exit penalty USDC into the Distribution Reserve. */
    function setSafeVault(address safeVault_) external onlyRole(PARAMETER_ROLE) {
        if (safeVault_ == address(0)) {
            revert ZeroAddress();
        }
        safeVault = safeVault_;
    }

    /**
     * §4.5/§8 - books forfeited early-exit penalty USDC that SafeVault has
     * just transferred into this contract. Unlike recordEarlyExitPenalty
     * (which re-buckets value that already entered reserves at deposit
     * time), this is a FRESH inflow: the USDC physically arrived, so it
     * grows interestReserve (the Distribution Reserve's forward-coverage
     * bucket) and totalAllocated directly, with no double-count.
     */
    function creditEarlyExitPenalty(uint256 depositId, uint256 amount) external whenNotPaused {
        if (msg.sender != safeVault) {
            revert NotSafeVault(msg.sender);
        }
        earlyExitPenaltyTotal += amount;
        interestReserve += amount;
        totalAllocated += amount;
        emit EarlyExitPenaltyRecorded(depositId, amount);
        emit ReserveBucketsUpdated(interestReserve, buybackReserve, operationalReserve);
    }

    /**
     * §11.3/§11.7: governance sets the forward-coverage targets the
     * premium-profit waterfall must satisfy before splitting any surplus.
     * `interestCoverageRequired` doubles as the §11.7 solvency-lock floor.
     */
    function setCoverageTargets(uint256 interestRequired, uint256 buybackRequired)
        external
        onlyRole(PARAMETER_ROLE)
    {
        interestCoverageRequired = interestRequired;
        buybackFloorRequired = buybackRequired;
        emit CoverageTargetsUpdated(interestRequired, buybackRequired);
    }

    /* ----------------------------------------------------------------- */
    /*  §G.2 - dynamic Tier-1 coverage formula                            */
    /* ----------------------------------------------------------------- */

    event ActivePrincipalUpdated(uint256 totalActivePrincipal);

    /**
     * BondContract calls this on every successful deposit open
     * (including Turbo, AutoCompound, CYR-materialised, and Rollover
     * re-opens) so the dynamic coverage formula has live state.
     */
    function registerActivePrincipal(uint256 amount) external onlyRole(BOND_ENGINE_ROLE) whenNotPaused {
        totalActivePrincipal += amount;
        emit ActivePrincipalUpdated(totalActivePrincipal);
    }

    /**
     * BondContract calls this on every settlement transition (Matured
     * -> Closed, EarlyExit, Abandoned -> Closed, Liquidated, Rollover-of-
     * old). Saturates at zero so an over-pull from a stale upgrade cannot
     * underflow.
     */
    function unregisterActivePrincipal(uint256 amount) external onlyRole(BOND_ENGINE_ROLE) whenNotPaused {
        if (amount >= totalActivePrincipal) {
            totalActivePrincipal = 0;
        } else {
            totalActivePrincipal -= amount;
        }
        emit ActivePrincipalUpdated(totalActivePrincipal);
    }

    /**
     * §G.2 - dynamic Tier-1 forward-coverage target: `Active Principal x 11%`
     * (COVERAGE_TARGET_BPS = 1100), i.e. six months of the 20% APY obligation
     * (6 x 20%/12 = 10%) plus a 10% solvency buffer on that.
     */
    function interestCoverageTarget() public view returns (uint256) {
        return (totalActivePrincipal * COVERAGE_TARGET_BPS) / BPS_DENOMINATOR;
    }

    /**
     * Effective coverage threshold used by the waterfall, deficit-pull
     * and marketing lock. Takes the LARGER of the dynamic formula and
     * the governance override so the solvency invariant strengthens
     * automatically as the protocol grows, while still allowing
     * governance to ratchet it higher manually.
     */
    function effectiveCoverageRequired() public view returns (uint256) {
        uint256 dynamicTarget = interestCoverageTarget();
        uint256 manual = interestCoverageRequired;
        return dynamicTarget > manual ? dynamicTarget : manual;
    }

    /**
     * §8 Step E (Tier 2) - the effective Buyback / Floor-defence Reserve
     * target: `tier2_target = safe_vault × 0.05` (5% of Safe Vault TVL). It
     * takes the LARGER of this DYNAMIC target and the optional governance
     * override (`buybackFloorRequired`). Basing it on the SafeVault's
     * accountedPrincipal (the spec's `safe_vault` protected-principal pool)
     * rather than gross deposit principal keeps it exact under Turbo, where
     * only the loan-offset net (~50%) actually lands in the vault. Falls back
     * to the manual override if the SafeVault isn't wired yet.
     */
    function buybackFloorTarget() public view returns (uint256) {
        uint256 dynamicTarget = 0;
        if (safeVault != address(0)) {
            uint256 vaultTvl = ISafeVault(safeVault).accountedPrincipal();
            dynamicTarget = (vaultTvl * BUYBACK_FLOOR_BPS) / BPS_DENOMINATOR;
        }
        uint256 manual = buybackFloorRequired;
        return dynamicTarget > manual ? dynamicTarget : manual;
    }

    /**
     * Spec §11.3 - premium-zone profit waterfall. The caller must have
     * already transferred `amount` of realized premium-zone profit USDC
     * into this contract. Distribution order is strict:
     *   Step 1 - restore Interest Reserve to its required coverage.
     *   Step 2 - restore Buyback Reserve to its TVT-floor target.
     *   Step 3 - split the remaining surplus 83.33% Treasury / 16.67%
     *            Marketing, then earmark 20% of the Treasury share for
     *            marketing token refill (§11.4). Net effective marketing
     *            allocation ~ 33%, Treasury retains ~ 67% (§11.5).
     */
    function processPremiumProfit(uint256 amount) external onlyRole(BOND_ENGINE_ROLE) whenNotPaused {
        _processPremiumProfit(amount);
    }

    /**
     * Internal waterfall used by both the BOND_ENGINE_ROLE-gated
     * `processPremiumProfit` AND the §F.3 Profit-Batch trigger fired
     * automatically from `recordExecutionProceeds` whenever a premium-
     * zone sell deposits USDC into the Treasury. Routes the inflow in
     * strict priority order: Interest coverage -> TVT-floor defence ->
     * 5:1 surplus split with 20% marketing refill.
     */
    function _processPremiumProfit(uint256 amount) internal {
        uint256 remaining = amount;
        uint256 coverageTarget = effectiveCoverageRequired();

        // Step 1 - Interest Reserve coverage (highest priority).
        uint256 toInterest = 0;
        if (interestReserve < coverageTarget) {
            uint256 gap = coverageTarget - interestReserve;
            toInterest = gap < remaining ? gap : remaining;
            interestReserve += toInterest;
            remaining -= toInterest;
        }

        // Step 1b - repay any deferred yield liability before the buyback floor.
        // Once forward coverage is met, returning profit settles obligations
        // deferred while reserves were short. Repayment is strictly OLDEST-FIRST
        // across the queue of deposits that missed yield, and the healed amount
        // is re-fenced (§G.5) to the deposit it belongs to so it cannot be spent
        // by anyone else. Skipped while unfundedYield is zero, so the common
        // path is unchanged.
        if (unfundedYield > 0 && remaining > 0) {
            remaining -= _healUnfundedFifo(remaining);
        }

        // Step 2 - TVT-floor defence: top up the Buyback Reserve.
        uint256 toBuyback = 0;
        uint256 buybackFloor_ = buybackFloorTarget();
        if (remaining > 0 && buybackReserve < buybackFloor_) {
            uint256 gap = buybackFloor_ - buybackReserve;
            toBuyback = gap < remaining ? gap : remaining;
            buybackReserve += toBuyback;
            remaining -= toBuyback;
        }

        // Step 3 - 5:1 split of the surplus, but ONLY once TVL crosses the
        // §11.1 gate. Below the gate the entire surplus stays in the
        // Distribution Reserve (operationalReserve) as backing - 0% marketing.
        uint256 toMarketing = 0;
        uint256 refill = 0;
        uint256 treasuryShare = remaining;
        if (remaining > 0 && totalAllocated >= surplusSplitTvlGate) {
            toMarketing = (remaining * MARKETING_SPLIT_BPS) / BPS_DENOMINATOR;
            treasuryShare = remaining - toMarketing;
            // §11.4 - 20% of the Treasury share is earmarked for marketing
            // token (GIL) refill. It is NOT mixed into USDC marketingClaimable
            // (which claimMarketing pays out as USDC); it accrues in a
            // dedicated counter pending the on-market GIL buy so accounting
            // stays separate and the refill cannot leak out as USDC.
            refill = (treasuryShare * MARKETING_REFILL_BPS) / BPS_DENOMINATOR;
            treasuryShare -= refill;
            marketingClaimable += toMarketing;
            marketingRefillPendingGilBuy += refill;
        }

        operationalReserve += treasuryShare;
        totalAllocated += amount;

        // Event marketing leg reports the full marketing-directed value
        // (USDC claimable + GIL-refill earmark) for downstream reconciliation.
        emit PremiumProfitProcessed(amount, toInterest, toBuyback, treasuryShare, toMarketing + refill);
        emit ReserveBucketsUpdated(interestReserve, buybackReserve, operationalReserve);
    }

    /**
     * §G.4 - the retroactive healing queue. Repays deferred yield strictly
     * oldest-first out of `budget` (unencumbered premium proceeds), returning
     * the amount actually healed.
     *
     * Each healed instalment is credited into `interestReserve` AND re-fenced to
     * the deposit it is owed to (`depositYieldReserve`, §G.5), so the back-pay
     * cannot be spent by a different depositor on its way to settlement.
     *
     * The walk is bounded by MAX_HEAL_ITERATIONS: a partially-healed deposit
     * stays at the head of the queue, so a long backlog simply continues on the
     * next inflow - never out of order, never stuck.
     */
    function _healUnfundedFifo(uint256 budget) private returns (uint256 healed) {
        uint256 i = unfundedQueueHead;
        uint256 len = _unfundedQueue.length;
        uint256 steps = 0;

        while (i < len && budget > 0 && steps < MAX_HEAL_ITERATIONS) {
            uint256 id = _unfundedQueue[i];
            uint256 owed = depositUnfundedYield[id];
            if (owed == 0) {
                // Already settled (or a stale duplicate) - skip past it.
                unchecked { ++i; ++steps; }
                continue;
            }

            uint256 pay = owed < budget ? owed : budget;
            depositUnfundedYield[id] = owed - pay;
            budget -= pay;
            healed += pay;

            // The back-pay is earmarked for THIS deposit, not the common pool.
            depositYieldReserve[id] += pay;
            totalRingFencedYield += pay;

            emit DepositUnfundedYieldHealed(id, pay, depositUnfundedYield[id]);

            if (depositUnfundedYield[id] != 0) {
                // Partial heal - the budget ran out. This deposit KEEPS the head
                // position so the next inflow resumes exactly here (FIFO).
                break;
            }
            unchecked { ++i; ++steps; }
        }

        unfundedQueueHead = i;
        if (healed > 0) {
            unfundedYield -= healed;
            interestReserve += healed;
            emit UnfundedYieldHealed(healed, unfundedYield);
        }
    }

    /** Number of deposits still owed back-pay, in FIFO order. */
    function unfundedQueueLength() external view returns (uint256) {
        return _unfundedQueue.length - unfundedQueueHead;
    }

    /** The depositId next in line for back-pay (0 if the queue is drained). */
    function nextUnfundedDeposit() external view returns (uint256) {
        uint256 i = unfundedQueueHead;
        uint256 len = _unfundedQueue.length;
        while (i < len) {
            uint256 id = _unfundedQueue[i];
            if (depositUnfundedYield[id] > 0) {
                return id;
            }
            unchecked { ++i; }
        }
        return 0;
    }

    /**
     * §F.3 Deficit-Pull Trigger - rebalances surplus reserves back into
     * the Interest Reserve whenever forward-coverage falls below
     * `interestCoverageRequired`. Pulls FIRST from operationalReserve
     * (lowest priority), THEN from buybackReserve above its TVT-floor
     * target. Never touches the SafeVault and never moves USDC out of
     * the contract - only re-categorises existing balance to preserve
     * solvency guarantees per §11.7.
     *
     * Permissionless: anyone can keeper this, the logic is deterministic.
     */
    function pullDeficit() external whenNotPaused returns (uint256 pulled) {
        uint256 coverageTarget = effectiveCoverageRequired();
        if (interestReserve >= coverageTarget) {
            return 0;
        }
        uint256 deficit = coverageTarget - interestReserve;

        if (operationalReserve > 0) {
            uint256 fromOp = deficit < operationalReserve ? deficit : operationalReserve;
            operationalReserve -= fromOp;
            interestReserve += fromOp;
            pulled += fromOp;
            deficit -= fromOp;
        }
        uint256 buybackFloor_ = buybackFloorTarget();
        if (deficit > 0 && buybackReserve > buybackFloor_) {
            uint256 excess = buybackReserve - buybackFloor_;
            uint256 fromBuyback = deficit < excess ? deficit : excess;
            buybackReserve -= fromBuyback;
            interestReserve += fromBuyback;
            pulled += fromBuyback;
        }
        if (pulled > 0) {
            emit DeficitPulled(pulled, interestReserve, buybackReserve, operationalReserve);
            emit ReserveBucketsUpdated(interestReserve, buybackReserve, operationalReserve);
        }
    }

    /**
     * §Code-Review H4 (Jul 2026) - books an abandoned-deposit decay fee into
     * the marketing budget. The BondContract has already moved the USDC here
     * from SafeVault; this only does the accounting, so the fee becomes
     * spendable ONLY through `claimMarketing` - i.e. behind the per-period
     * extraction cap, the TVL gate and the interest-coverage solvency lock.
     * Previously the fee was paid straight to the marketing wallet and
     * bypassed all three.
     */
    function creditMarketingFromDecay(uint256 depositId, uint256 amount)
        external
        onlyRole(BOND_ENGINE_ROLE)
    whenNotPaused {
        if (amount == 0) {
            return;
        }
        marketingClaimable += amount;
        emit MarketingDecayCredited(depositId, amount, marketingClaimable);
    }

    /**
     * §11.6/§11.7 - the MarketingEngine pulls earmarked marketing budget.
     * Hard-gated: only the registered engine may call, the amount cannot
     * exceed `marketingClaimable`, and extraction is LOCKED whenever the
     * Interest Reserve sits below its required forward coverage - yield
     * obligations always outrank growth spending.
     */
    function claimMarketing(address to, uint256 amount) external nonReentrant whenNotPaused {
        if (msg.sender != marketingEngine) {
            revert NotMarketingEngine(msg.sender);
        }
        if (to == address(0)) {
            revert ZeroAddress();
        }
        if (amount > marketingClaimable) {
            revert InsufficientReserve(amount, marketingClaimable);
        }
        uint256 coverageTarget = effectiveCoverageRequired();
        if (interestReserve < coverageTarget) {
            revert MarketingSolvencyLocked(interestReserve, coverageTarget);
        }
        _enforceSolvencyOnOutflow(amount);
        marketingClaimable -= amount;
        if (!asset.transfer(to, amount)) {
            revert TransferFailed();
        }
        emit MarketingClaimPaid(to, amount);
    }

    /* ----------------------------------------------------------------- */
    /*  M4 - Consolidated Yield Reinvestment deferred-liability funding   */
    /* ----------------------------------------------------------------- */

    event ReinvestmentVaultUpdated(address indexed vault);
    event ReinvestmentBonusPaid(uint256 indexed poolId, address indexed recipient, uint256 amount);

    /** §M4: registers the CYR module authorised to draw deferred bonuses. */
    function setReinvestmentVault(address vault) external onlyRole(PARAMETER_ROLE) {
        reinvestmentVault = vault;
        emit ReinvestmentVaultUpdated(vault);
    }

    /**
     * Funds a materialized Consolidated-Reinvestment bonus.
     *
     * The CYR module computes the compound-over-simple bonus owed on a
     * pooled deposit at settlement time and calls this to draw the USDC.
     * Only the registered `reinvestmentVault` may call. The outflow
     * passes the same solvency-floor + reserve-drain discipline as a
     * normal settlement, so honouring a deferred liability can never
     * breach the protocol's interest-coverage guarantees. The cumulative
     * `reinvestmentBonusPaid` counter is the on-chain figure the backend
     * reconciles against the CYR module's `cumulativeMaterializedBonus`.
     */
    function payReinvestmentBonus(uint256 poolId, address recipient, uint256 amount) external nonReentrant whenNotPaused {
        if (msg.sender != reinvestmentVault) {
            revert NotReinvestmentVault(msg.sender);
        }
        if (recipient == address(0)) {
            revert ZeroAddress();
        }
        _enforceSolvencyOnOutflow(amount);
        if (!asset.transfer(recipient, amount)) {
            revert TransferFailed();
        }
        _drainReserves(amount);
        reinvestmentBonusPaid += amount;
        emit ReinvestmentBonusPaid(poolId, recipient, amount);
        emit ReserveBucketsUpdated(interestReserve, buybackReserve, operationalReserve);
    }

    /* ----------------------------------------------------------------- */
    /*  §10 - Treasury Execution funding (buyback / premium-zone sell)    */
    /* ----------------------------------------------------------------- */

    event TreasuryExecutorUpdated(address indexed executor);
    event GilTokenUpdated(address indexed gilToken);
    event BuybackFunded(address indexed executor, uint256 usdcAmount);
    event SellInventoryFunded(address indexed executor, uint256 gilAmount);
    event ExecutionProceedsRecorded(address indexed executor, uint256 usdcAmount);
    event LiquidityManagerUpdated(address indexed liquidityManager);
    event LiquidityInventoryFunded(address indexed liquidityManager, uint256 gilAmount);

    /** §10: registers the GIL token whose inventory the Treasury sells. */
    function setGilToken(address gilToken_) external onlyRole(PARAMETER_ROLE) {
        gilToken = gilToken_;
        emit GilTokenUpdated(gilToken_);
    }

    /** §10: registers the keeper-callable Treasury Execution engine. */
    function setTreasuryExecutor(address executor) external onlyRole(PARAMETER_ROLE) {
        treasuryExecutor = executor;
        emit TreasuryExecutorUpdated(executor);
    }

    /** §V6.3 Issue 2A: registers the deposit-time LP top-up manager. */
    function setLiquidityManager(address manager) external onlyRole(PARAMETER_ROLE) {
        liquidityManager = manager;
        emit LiquidityManagerUpdated(manager);
    }

    /**
     * §10.4 discount-zone buyback funding. The executor draws USDC from
     * the dedicated Buyback Reserve; it then swaps it for GIL on the
     * pool and the GIL lands back here as inventory. The outflow passes
     * the standard solvency-floor guard, and the Interest Reserve is
     * never touched - buyback capital is strictly its own bucket.
     */
    function fundBuyback(uint256 usdcAmount) external nonReentrant whenNotPaused {
        if (msg.sender != treasuryExecutor) {
            revert NotTreasuryExecutor(msg.sender);
        }
        if (usdcAmount > buybackReserve) {
            revert InsufficientReserve(usdcAmount, buybackReserve);
        }
        _enforceSolvencyOnOutflow(usdcAmount);
        buybackReserve -= usdcAmount;
        if (!asset.transfer(treasuryExecutor, usdcAmount)) {
            revert TransferFailed();
        }
        emit BuybackFunded(treasuryExecutor, usdcAmount);
        emit ReserveBucketsUpdated(interestReserve, buybackReserve, operationalReserve);
    }

    /**
     * §10.3 premium-zone sell funding. Hands the executor GIL from the
     * Treasury's token inventory; the executor swaps it for USDC and
     * routes the proceeds back through `recordExecutionProceeds`.
     */
    function fundSell(uint256 gilAmount) external nonReentrant whenNotPaused {
        if (msg.sender != treasuryExecutor) {
            revert NotTreasuryExecutor(msg.sender);
        }
        if (!IERC20(gilToken).transfer(treasuryExecutor, gilAmount)) {
            revert TransferFailed();
        }
        emit SellInventoryFunded(treasuryExecutor, gilAmount);
    }

    /**
     * §V6.3 Issue 2A - hands the deposit-time LP top-up manager the GIL that
     * pairs with a deposit's 1% USDC slice, drawn from the Treasury's token
     * inventory. The manager adds both sides to the pool (growing Live K) and
     * locks the LP tokens back here. Inventory-only: never touches USDC
     * reserves, so the §11 solvency floor is unaffected.
     */
    function fundLiquidity(uint256 gilAmount) external nonReentrant whenNotPaused {
        if (msg.sender != liquidityManager) {
            revert NotLiquidityManager(msg.sender);
        }
        if (!IERC20(gilToken).transfer(liquidityManager, gilAmount)) {
            revert TransferFailed();
        }
        emit LiquidityInventoryFunded(liquidityManager, gilAmount);
    }

    /**
     * §F.3 Profit-Batch Trigger - books USDC proceeds from a premium-
     * zone sell through the §11.3 premium-profit waterfall. The executor
     * must have already transferred the USDC into this contract.
     *
     * Previously this routine dumped 100% into `buybackReserve`, which
     * bypassed the spec's strict reserve priority (Interest > Buyback >
     * Operational > Marketing). Now the inflow runs through the same
     * `_processPremiumProfit` waterfall as a BOND_ENGINE_ROLE-initiated
     * batch - proceeds top up forward interest coverage first, TVT-floor
     * defence second, then split the surplus 83.3/16.7 with a 20%
     * Treasury-share refill for marketing token buys.
     */
    function recordExecutionProceeds(uint256 usdcAmount) external whenNotPaused {
        if (msg.sender != treasuryExecutor) {
            revert NotTreasuryExecutor(msg.sender);
        }
        _processPremiumProfit(usdcAmount);
        emit ExecutionProceedsRecorded(treasuryExecutor, usdcAmount);
    }

    /**
     * Disburses operational-reserve capital as a loan to the borrower.
     * Only the Lending module (LENDING_OPERATOR_ROLE) may call. The
     * outstanding principal is tracked separately so solvency math can
     * subtract it from totalAllocated when assessing reserve health.
     */
    function disburseLoanCapital(uint256 depositId, address borrower, uint256 amount)
        external
        onlyRole(LENDING_OPERATOR_ROLE)
    whenNotPaused {
        if (borrower == address(0)) {
            revert ZeroAddress();
        }
        if (amount > operationalReserve) {
            revert InsufficientReserve(amount, operationalReserve);
        }
        _enforceSolvencyOnOutflow(amount);
        operationalReserve -= amount;
        outstandingLoanPrincipal += amount;
        if (!asset.transfer(borrower, amount)) {
            revert TransferFailed();
        }
        emit LoanCapitalDisbursed(depositId, borrower, amount);
        emit ReserveBucketsUpdated(interestReserve, buybackReserve, operationalReserve);
    }

    /**
     * Called by Lending after pulling loan repayment USDC into Treasury.
     * Splits the inflow into principal (returned to operationalReserve)
     * and interest (booked to interestReserve so it can fund settlements).
     */
    function returnLoanCapital(uint256 depositId, uint256 principalPortion, uint256 interestPortion)
        external
        onlyRole(LENDING_OPERATOR_ROLE)
    whenNotPaused {
        if (principalPortion > outstandingLoanPrincipal) {
            outstandingLoanPrincipal = 0;
        } else {
            outstandingLoanPrincipal -= principalPortion;
        }
        operationalReserve += principalPortion;
        interestReserve += interestPortion;
        totalAllocated += interestPortion;
        emit LoanCapitalReturned(depositId, principalPortion, interestPortion);
        emit ReserveBucketsUpdated(interestReserve, buybackReserve, operationalReserve);
    }

    /**
     * §TVG: TVT = Treasury USDC Assets / circulating supply, scaled 1e18
     * (USDC 6dp => result is humanTVG x 1e6). "Treasury USDC Assets" per the
     * client spec/sim = (live LP USDC reserve - initial seed) + every non-LP
     * protocol USDC bucket. The Market Treasury executor owns the pool-reserve
     * read, so we source the numerator from it; until it's wired (pre-market
     * deployments) we fall back to this contract's raw USDC balance.
     */
    function treasuryValuePerToken(uint256 circulatingSupply) external view returns (uint256 tvt) {
        if (circulatingSupply == 0) {
            return 0;
        }
        uint256 numerator = treasuryExecutor != address(0)
            ? ITreasuryUsdcAssets(treasuryExecutor).treasuryUsdcAssets()
            : asset.balanceOf(address(this));
        return (numerator * 1e18) / circulatingSupply;
    }

    function _enforceSolvencyOnOutflow(uint256 amount) private view {
        uint256 balance = asset.balanceOf(address(this));
        if (amount > balance) {
            revert InsufficientReserve(amount, balance);
        }
        uint256 remaining = balance - amount;
        if (remaining < solvencyFloor) {
            revert SolvencyFloorBreached(remaining, solvencyFloor);
        }
    }

    // __gap shrunk 36 -> 34 (reinvestmentVault + reinvestmentBonusPaid),
    // then 34 -> 33 (this comment counts slots, see below) - §V6.3 2A adds
    // `liquidityManager` (1 slot), so the array drops by one more.
    // -> 32 (gilToken + treasuryExecutor).
    // -> 31 (safeVault), then 31 -> 30 (unfundedYield).
    // -> 25: §G.5 ring-fencing adds 5 slots - depositYieldReserve,
    //    totalRingFencedYield, depositUnfundedYield, _unfundedQueue,
    //    unfundedQueueHead. (MAX_HEAL_ITERATIONS is a constant - no slot.)
    uint256[25] private __gap;
}

/**
 * @title DepositNFT
 * @notice ERC-721C token representing ownership of a term deposit.
 *
 * Standards implemented:
 *   - ERC-721 (ownerOf, balanceOf, transferFrom, safeTransferFrom, approve,
 *             setApprovalForAll, getApproved, isApprovedForAll).
 *   - ERC-165 (supportsInterface for ERC-721, ERC-2981 and itself).
 *   - ERC-2981 (royaltyInfo for marketplace royalty enforcement at 2%).
 *
 * Marketplace gating: every transfer (including marketplace operator
 * transfers) is filtered through `transferWhitelist`. Only addresses
 * explicitly approved by governance - typically the proprietary
 * marketplace contract once Phase 2 ships - can move tokens, which is
 * how on-chain royalty enforcement is preserved.
 */
contract DepositNFT is IDepositNFT, GilderModule {
    using GilderStrings for uint256;

    bytes4 private constant INTERFACE_ID_ERC165 = 0x01ffc9a7;
    bytes4 private constant INTERFACE_ID_ERC721 = 0x80ac58cd;
    bytes4 private constant INTERFACE_ID_ERC721_METADATA = 0x5b5e139f;
    bytes4 private constant INTERFACE_ID_ERC2981 = 0x2a55205a;
    bytes4 private constant ERC721_RECEIVED = 0x150b7a02;

    // §M6 (Jul 2026 client review) - secondary-sale royalty cut from 5% to
    // 2%. Every Phase-2 marketplace sale routes 2% of the sale price to
    // `royaltyReceiver`.
    uint256 public constant ROYALTY_BPS = 200;
    uint256 public constant ROYALTY_DENOMINATOR = 10_000;

    string public constant name = "GILDer Term Deposit";
    string public constant symbol = "GILDPOS";

    address public bondContract;
    address public royaltyReceiver;
    address public metadataRenderer;
    address public cyrContract;
    string private _baseTokenUri;
    mapping(uint256 tokenId => address owner) private _owners;
    mapping(address account => uint256 balance) private _balances;
    mapping(uint256 tokenId => address approved) private _tokenApprovals;
    mapping(address owner => mapping(address operator => bool approved)) private _operatorApprovals;
    mapping(address account => bool allowed) public transferWhitelist;
    // §Phase 2 Marketplace - the authorised Bond Marketplace contract. Only
    // this address may flip a token's `listed` state. Governance wires it via
    // setMarketplace (which also whitelists it for transfers).
    address public marketplace;
    // §Phase 2 Marketplace - listing lock. While true, BondContract blocks
    // every value-extracting action on the deposit (interest withdrawal, early
    // exit, settle, rollover, abandoned withdraw) so accrued yield stays with
    // the position and transfers intact to the buyer. Transfers themselves are
    // already gated by `transferWhitelist`, so a seller can never move a listed
    // token except through the marketplace.
    mapping(uint256 tokenId => bool listed) public isListed;

    error NotOwnerOrApproved();
    error TransferToNonReceiver();
    error UnknownToken(uint256 tokenId);
    error TokenAlreadyMinted(uint256 tokenId);
    error TransferNotWhitelisted(address account);
    error TokenPoolAttached(uint256 tokenId);
    error NotMarketplace();

    event CyrContractSet(address indexed cyr);
    // MarketplaceSet / ListedStateSet are declared on IDepositNFT (inherited).

    function initialize(address admin, address bondContract_) external {
        _initializeAccessControl(admin);
        if (bondContract_ == address(0)) {
            revert ZeroAddress();
        }
        bondContract = bondContract_;
        royaltyReceiver = admin;
        // Owners can always move their own token; marketplace operators
        // get added explicitly by governance via setTransferWhitelist.
        transferWhitelist[admin] = true;
    }

    function mintForDeposit(address owner, uint256 depositId) external onlyRole(NFT_MINTER_ROLE) whenNotPaused returns (uint256 tokenId) {
        if (owner == address(0)) {
            revert ZeroAddress();
        }
        if (_owners[depositId] != address(0)) {
            revert TokenAlreadyMinted(depositId);
        }
        tokenId = depositId;
        _owners[tokenId] = owner;
        _balances[owner] += 1;
        emit DepositTokenMinted(tokenId, owner, depositId);
        emit Transfer(address(0), owner, tokenId);
    }

    /**
     * Burns a deposit token. Only the BondContract (NFT_MINTER_ROLE)
     * may burn so a token cannot outlive its deposit lifecycle.
     */
    function burn(uint256 tokenId) external onlyRole(NFT_MINTER_ROLE) whenNotPaused {
        address owner = _owners[tokenId];
        if (owner == address(0)) {
            revert UnknownToken(tokenId);
        }
        delete _tokenApprovals[tokenId];
        _balances[owner] -= 1;
        delete _owners[tokenId];
        emit Transfer(owner, address(0), tokenId);
        emit DepositBurned(tokenId);
    }

    function transferFrom(address from, address to, uint256 tokenId) public whenNotPaused {
        _transfer(from, to, tokenId);
    }

    function safeTransferFrom(address from, address to, uint256 tokenId) external whenNotPaused {
        _transfer(from, to, tokenId);
        _checkOnERC721Received(from, to, tokenId, "");
    }

    function safeTransferFrom(address from, address to, uint256 tokenId, bytes calldata data) external whenNotPaused {
        _transfer(from, to, tokenId);
        _checkOnERC721Received(from, to, tokenId, data);
    }

    function approve(address to, uint256 tokenId) external whenNotPaused {
        address owner = _owners[tokenId];
        if (owner == address(0)) {
            revert UnknownToken(tokenId);
        }
        if (msg.sender != owner && !_operatorApprovals[owner][msg.sender]) {
            revert NotOwnerOrApproved();
        }
        _tokenApprovals[tokenId] = to;
        emit Approval(owner, to, tokenId);
    }

    function setApprovalForAll(address operator, bool approved) external whenNotPaused {
        if (operator == msg.sender) {
            revert NotOwnerOrApproved();
        }
        _operatorApprovals[msg.sender][operator] = approved;
        emit ApprovalForAll(msg.sender, operator, approved);
    }

    function getApproved(uint256 tokenId) external view returns (address) {
        if (_owners[tokenId] == address(0)) {
            revert UnknownToken(tokenId);
        }
        return _tokenApprovals[tokenId];
    }

    function isApprovedForAll(address owner, address operator) external view returns (bool) {
        return _operatorApprovals[owner][operator];
    }

    function setTransferWhitelist(address account, bool allowed) external onlyRole(PARAMETER_ROLE) {
        if (account == address(0)) {
            revert ZeroAddress();
        }
        transferWhitelist[account] = allowed;
        emit TransferWhitelistSet(account, allowed);
    }

    /**
     * §Phase 2 Marketplace - registers the authorised Bond Marketplace and
     * whitelists it for transfers in the same call (a listed sale moves the
     * token through the marketplace, which would otherwise hit the whitelist
     * gate). Only the marketplace may subsequently flip `isListed`.
     */
    function setMarketplace(address marketplace_) external onlyRole(PARAMETER_ROLE) {
        if (marketplace_ == address(0)) {
            revert ZeroAddress();
        }
        marketplace = marketplace_;
        transferWhitelist[marketplace_] = true;
        emit MarketplaceSet(marketplace_);
        emit TransferWhitelistSet(marketplace_, true);
    }

    /**
     * §Phase 2 Marketplace - flips a token's listing lock. Marketplace-only.
     * BondContract reads `isListed` to freeze value extraction while a bond
     * is listed for secondary sale.
     */
    function setListedState(uint256 tokenId, bool listed) external {
        if (msg.sender != marketplace) {
            revert NotMarketplace();
        }
        if (_owners[tokenId] == address(0)) {
            revert UnknownToken(tokenId);
        }
        isListed[tokenId] = listed;
        emit ListedStateSet(tokenId, listed);
    }

    /**
     * §Phase 2 Marketplace - public view of the §M4 pool-attachment state so
     * the marketplace can reject listing a pooled deposit up-front (a listed
     * pooled NFT would otherwise fail at purchase when `_transfer` reverts
     * with TokenPoolAttached).
     */
    function isPoolAttached(uint256 tokenId) external view returns (bool) {
        address cyr = cyrContract;
        return cyr != address(0) && ICyrAttachView(cyr).isAttached(tokenId);
    }

    function setBaseTokenUri(string calldata baseTokenUri) external onlyRole(PARAMETER_ROLE) {
        _baseTokenUri = baseTokenUri;
        emit BaseTokenUriSet(baseTokenUri);
    }

    function setMetadataRenderer(address renderer) external onlyRole(PARAMETER_ROLE) {
        metadataRenderer = renderer;
        emit MetadataRendererSet(renderer);
    }

    /**
     * Registers the M4 Consolidated Yield Reinvestment module. Once set,
     * any token whose deposit is attached to a Reinvestment Pool is
     * frozen for transfer (spec §M4 "marketplace transfer restriction
     * logic for pooled NFTs") - the position must be detached, which
     * settles the pooled bonus, before the NFT can change hands.
     */
    function setCyrContract(address cyr) external onlyRole(PARAMETER_ROLE) {
        cyrContract = cyr;
        emit CyrContractSet(cyr);
    }

    function setRoyaltyReceiver(address receiver) external onlyRole(PARAMETER_ROLE) {
        if (receiver == address(0)) {
            revert ZeroAddress();
        }
        royaltyReceiver = receiver;
    }

    function tokenURI(uint256 tokenId) external view returns (string memory uri) {
        if (_owners[tokenId] == address(0)) {
            revert UnknownToken(tokenId);
        }
        if (metadataRenderer != address(0)) {
            return IDepositMetadataRenderer(metadataRenderer).tokenURI(tokenId);
        }
        return string(abi.encodePacked(_baseTokenUri, tokenId.toString()));
    }

    function royaltyInfo(uint256, uint256 salePrice) external view returns (address receiver, uint256 royaltyAmount) {
        // Royalty is a protocol receivable, so round UP (ceil) in the
        // protocol's favor - mirrors the loan-interest receivable in
        // _pendingInterest. roundUpToUser is the shared ceil primitive.
        return (royaltyReceiver, RoundingLib.roundUpToUser(salePrice * ROYALTY_BPS, ROYALTY_DENOMINATOR));
    }

    function balanceOf(address owner) external view returns (uint256 balance) {
        if (owner == address(0)) {
            revert ZeroAddress();
        }
        return _balances[owner];
    }

    function ownerOf(uint256 tokenId) external view returns (address owner) {
        owner = _owners[tokenId];
        if (owner == address(0)) {
            revert UnknownToken(tokenId);
        }
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == INTERFACE_ID_ERC165 || interfaceId == INTERFACE_ID_ERC721
            || interfaceId == INTERFACE_ID_ERC721_METADATA || interfaceId == INTERFACE_ID_ERC2981;
    }

    function _transfer(address from, address to, uint256 tokenId) private {
        address owner = _owners[tokenId];
        if (owner == address(0)) {
            revert UnknownToken(tokenId);
        }
        if (owner != from) {
            revert NotOwnerOrApproved();
        }
        if (to == address(0)) {
            revert ZeroAddress();
        }
        bool authorized = msg.sender == owner || _operatorApprovals[owner][msg.sender]
            || _tokenApprovals[tokenId] == msg.sender;
        if (!authorized) {
            revert NotOwnerOrApproved();
        }
        // Whitelist gate (spec §18.2: "No unrestricted peer-to-peer
        // transfers"). EVERY transfer - including ones the token owner
        // initiates directly - must be executed by a whitelisted
        // marketplace / operator contract, so royalty capture and
        // compliance controls can never be bypassed by a direct
        // owner-to-peer transfer. Governance manages the whitelist via
        // `setTransferWhitelist`.
        if (!transferWhitelist[msg.sender]) {
            revert TransferNotWhitelisted(msg.sender);
        }
        // §M4: a pooled deposit's NFT is frozen - its position carries an
        // unsettled deferred bonus, so it must be detached before sale.
        if (cyrContract != address(0) && ICyrAttachView(cyrContract).isAttached(tokenId)) {
            revert TokenPoolAttached(tokenId);
        }

        delete _tokenApprovals[tokenId];
        _balances[from] -= 1;
        _balances[to] += 1;
        _owners[tokenId] = to;
        // Spec §18.1: the NFT IS the deposit. Push the new holder into
        // BondContract's canonical `deposit.owner` in the SAME tx so
        // lifecycle authorisation follows the token. tokenId == depositId.
        IBondOwnerSync(bondContract).syncDepositOwner(tokenId, to);
        emit Transfer(from, to, tokenId);
    }

    function _checkOnERC721Received(address from, address to, uint256 tokenId, bytes memory data) private {
        // Skip the receiver check for EOAs.
        if (to.code.length == 0) return;
        try IERC721Receiver(to).onERC721Received(msg.sender, from, tokenId, data) returns (bytes4 retval) {
            if (retval != ERC721_RECEIVED) {
                revert TransferToNonReceiver();
            }
        } catch {
            revert TransferToNonReceiver();
        }
    }

    // __gap shrunk 40 -> 39 (cyrContract), then 39 -> 37: §Phase 2 Marketplace
    // added `marketplace` (1 slot) + the `isListed` mapping (1 slot).
    uint256[37] private __gap;
}

interface IERC721Receiver {
    function onERC721Received(address operator, address from, uint256 tokenId, bytes calldata data) external returns (bytes4);
}

/**
 * @title DepositMetadataRenderer
 * @notice Live, on-chain metadata renderer for DepositNFT tokens.
 *
 * Returns a `data:application/json;base64,...` URI containing a minimal
 * SVG image and trait metadata derived from the deposit's current
 * state. Reading from BondContract guarantees marketplaces and wallets
 * always reflect live principal, accrued interest, days-to-maturity,
 * lifecycle state, loan exposure and compound mode without an off-chain
 * indexer.
 */
contract DepositMetadataRenderer is IDepositMetadataRenderer {
    using GilderStrings for uint256;

    address public immutable bondContract;

    constructor(address bondContract_) {
        bondContract = bondContract_;
    }

    function tokenURI(uint256 tokenId) external view returns (string memory) {
        IBondContract.Deposit memory d = IBondContract(bondContract).getDeposit(tokenId);
        // Render live, time-projected accrual rather than the stale stored
        // field. previewAccruedInterest caps at maturity and nets realized.
        uint256 accrued = IBondContract(bondContract).previewAccruedInterest(tokenId);
        // Fully-settled terminal positions hold no value; show zeros so
        // marketplaces don't render principal/accrued for closed deposits.
        bool terminal = d.state == IGilderTypes.DepositState.Closed
            || d.state == IGilderTypes.DepositState.Exited;
        uint256 dispPrincipal = terminal ? 0 : d.principal;
        uint256 dispAccrued = terminal ? 0 : accrued;
        string memory stateLabel = _stateLabel(d.state);
        uint256 daysToMaturity = block.timestamp >= d.maturityTime ? 0 : (d.maturityTime - block.timestamp) / 1 days;
        string memory svg = _renderSvg(tokenId, dispPrincipal, dispAccrued, daysToMaturity, stateLabel);
        string memory json = string(
            abi.encodePacked(
                "{\"name\":\"GILDer Deposit #",
                tokenId.toString(),
                "\",\"description\":\"Capital-protected term deposit position.\",",
                "\"image\":\"data:image/svg+xml;base64,",
                _base64(bytes(svg)),
                "\",\"attributes\":[",
                "{\"trait_type\":\"Principal (USDC 6dp)\",\"value\":\"",
                dispPrincipal.toString(),
                "\"},{\"trait_type\":\"Accrued Interest (USDC 6dp)\",\"value\":\"",
                dispAccrued.toString(),
                "\"},{\"trait_type\":\"Loan Balance (USDC 6dp)\",\"value\":\"",
                d.loanBalance.toString(),
                "\"},{\"trait_type\":\"Days to Maturity\",\"value\":\"",
                daysToMaturity.toString(),
                "\"},{\"trait_type\":\"Status\",\"value\":\"",
                stateLabel,
                "\"},{\"trait_type\":\"Compound Mode\",\"value\":\"",
                _compoundLabel(d.compoundMode),
                "\"}]}"
            )
        );
        return string(abi.encodePacked("data:application/json;base64,", _base64(bytes(json))));
    }

    function _renderSvg(
        uint256 tokenId,
        uint256 principal,
        uint256 accrued,
        uint256 daysToMaturity,
        string memory stateLabel
    ) private pure returns (string memory) {
        return string(
            abi.encodePacked(
                "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 400 240\">",
                "<rect width=\"400\" height=\"240\" fill=\"#1D3E29\"/>",
                "<text x=\"24\" y=\"40\" fill=\"#FBC206\" font-family=\"sans-serif\" font-size=\"18\" font-weight=\"700\">GILDer Deposit #",
                tokenId.toString(),
                "</text>",
                "<text x=\"24\" y=\"90\" fill=\"#EAFFEF\" font-family=\"sans-serif\" font-size=\"14\">Principal: ",
                principal.toString(),
                "</text>",
                "<text x=\"24\" y=\"120\" fill=\"#EAFFEF\" font-family=\"sans-serif\" font-size=\"14\">Accrued: ",
                accrued.toString(),
                "</text>",
                "<text x=\"24\" y=\"150\" fill=\"#EAFFEF\" font-family=\"sans-serif\" font-size=\"14\">Days to Maturity: ",
                daysToMaturity.toString(),
                "</text>",
                "<text x=\"24\" y=\"180\" fill=\"#FBC206\" font-family=\"sans-serif\" font-size=\"14\" font-weight=\"700\">Status: ",
                stateLabel,
                "</text></svg>"
            )
        );
    }

    function _stateLabel(IGilderTypes.DepositState state) private pure returns (string memory) {
        if (state == IGilderTypes.DepositState.Active) return "Active";
        if (state == IGilderTypes.DepositState.Matured) return "Matured";
        if (state == IGilderTypes.DepositState.Dormant) return "Dormant";
        if (state == IGilderTypes.DepositState.Abandoned) return "Abandoned";
        if (state == IGilderTypes.DepositState.Exited) return "Exited";
        if (state == IGilderTypes.DepositState.Closed) return "Closed";
        return "Unknown";
    }

    function _compoundLabel(uint8 mode) private pure returns (string memory) {
        if (mode == 1) return "Standard";
        if (mode == 2) return "Turbo";
        return "Off";
    }

    /**
     * Minimal RFC 4648 base64 encoder. Adapted from OpenZeppelin's MIT-licensed
     * implementation. Used only by the renderer so we keep it inline rather
     * than pulling in a dependency.
     */
    function _base64(bytes memory data) private pure returns (string memory) {
        if (data.length == 0) return "";
        string memory table = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
        uint256 encodedLen = 4 * ((data.length + 2) / 3);
        bytes memory result = new bytes(encodedLen);
        bytes memory tableBytes = bytes(table);
        uint256 i = 0;
        uint256 j = 0;
        while (i + 3 <= data.length) {
            uint256 triple = (uint256(uint8(data[i])) << 16) | (uint256(uint8(data[i + 1])) << 8) | uint256(uint8(data[i + 2]));
            result[j] = tableBytes[(triple >> 18) & 0x3F];
            result[j + 1] = tableBytes[(triple >> 12) & 0x3F];
            result[j + 2] = tableBytes[(triple >> 6) & 0x3F];
            result[j + 3] = tableBytes[triple & 0x3F];
            i += 3;
            j += 4;
        }
        uint256 remainder = data.length - i;
        if (remainder == 1) {
            uint256 single = uint256(uint8(data[i])) << 16;
            result[j] = tableBytes[(single >> 18) & 0x3F];
            result[j + 1] = tableBytes[(single >> 12) & 0x3F];
            result[j + 2] = "=";
            result[j + 3] = "=";
        } else if (remainder == 2) {
            uint256 dbl = (uint256(uint8(data[i])) << 16) | (uint256(uint8(data[i + 1])) << 8);
            result[j] = tableBytes[(dbl >> 18) & 0x3F];
            result[j + 1] = tableBytes[(dbl >> 12) & 0x3F];
            result[j + 2] = tableBytes[(dbl >> 6) & 0x3F];
            result[j + 3] = "=";
        }
        return string(result);
    }
}

/**
 * @title Lending
 * @notice Collateralised borrowing against an active term deposit.
 *
 * Capital source: the borrower's OWN SafeVault slice (per spec §6 user
 * direction: each user borrows from their own deposit, never from
 * another user's collateral). The 75% LTV cap means a $100 deposit can
 * borrow up to $60 - funded by its own $80 SafeVault portion.
 *
 * Collateral source: same SafeVault slice (the loan is self-collateralised).
 * On liquidation the slice is forfeited, the debt is cleared and the
 * liquidator earns a bonus from the surplus.
 *
 * Interest source: still Treasury (interest accrues to the borrower via
 * the protocol's pooled interest reserve - SafeVault holds only principal).
 * Loan interest paid by the borrower lands in Treasury.interestReserve so
 * it can fund future settlements.
 *
 * Solvency invariants:
 *   - openLoan only succeeds while LTV <= MAX_LTV_BPS (default 7,500).
 *   - liquidate only succeeds while LTV >= LIQ_THRESHOLD_BPS (default 8,500).
 *   - SafeVault enforces that loaned amount <= safeVault slice per deposit,
 *     making cross-deposit funding structurally impossible.
 *   - Settlement on the BondContract reverts with OutstandingLoan if
 *     loanBalance or loanAccruedInterest is non-zero.
 */
contract Lending is ILending, GilderModule {
    uint256 public constant BPS_DENOMINATOR = 10_000;
    uint256 public constant DAYS_PER_YEAR = 365;
    uint256 public constant LIQUIDATION_BONUS_BPS = 500;
    // §Code-Review N4 (Jul 2026) - post-maturity grace window for leveraged
    // positions. Bond interest accrual hard-caps at maturity while loan
    // interest keeps running, so the self-paying-netting defence goes
    // structurally empty the moment a bond matures. During this window a
    // position may only be liquidated above the HARD ceiling below - the
    // standard threshold resumes once the grace window lapses.
    uint256 public constant TURBO_POST_MATURITY_GRACE_PERIOD = 90 days;
    // §Code-Review N4 - hard liquidation ceiling that stays enforceable even
    // inside the grace window, so grace can never be used to strand deeply
    // underwater debt (reviewer condition (a) on Fix 3).
    uint256 public constant HARD_LIQUIDATION_CEILING_BPS = 9_500;

    IERC20 public asset;
    address public bondContract;
    address public treasury;
    address public safeVault;
    address public cyrContract;
    // §V6.3 Turbo loop - the Turbo orchestrator authorised to borrow against
    // Turbo (mode-1) rungs via `openLoanForTurboLoop` (the only path exempt
    // from `_assertNotTurbo`). User-facing borrows against Turbo stay blocked.
    address public turboLoopContract;
    uint256 public maxLtvBps;
    uint256 public liquidationThresholdBps;
    uint256 public loanAprBps;
    mapping(uint256 depositId => Loan loan) private _loans;

    event CyrContractSet(address indexed cyr);
    event TurboLoopContractSet(address indexed turboLoop);
    event MarketplaceSet(address indexed marketplace);
    // §Phase 2 Marketplace - a listed bond's loan follows the NFT to the
    // buyer, who becomes the borrower of record (per client: Turbo/Leverage
    // debt travels with the position; nothing is repaid on transfer).
    event BorrowerMigrated(uint256 indexed depositId, address indexed from, address indexed to);

    error AssetNotSet();
    error NotMarketplace(address caller);
    // §Phase 2 Marketplace - borrowing against a listed deposit is blocked so a
    // seller cannot drain collateral out from under a buyer.
    error DepositListedForLoan(uint256 depositId);
    error LoanAlreadyOpen(uint256 depositId);
    error LoanNotOpen(uint256 depositId);
    error InvalidDepositForLoan(uint256 depositId);
    error NotCyrCaller(address caller);
    error NotTurboLoopCaller(address caller);
    error NotBondContractCaller(address caller);
    error LtvExceedsMax(uint256 ltvBps, uint256 maxBps);
    error LtvBelowLiquidation(uint256 ltvBps, uint256 thresholdBps);
    error RepayExceedsDebt(uint256 paid, uint256 owed);
    error NothingToNet();
    // §V6.2 - Turbo deposits represent the FINAL state of a 2.5x
    // leveraged convergence. By construction the SafeVault slice is
    // already fully deployed (80/10/9/1 routing reflects the
    // post-loop state), so no fresh user-driven borrow against a
    // Turbo deposit is permitted. The CYR auto-compound path goes
    // through `openLoanForCyr` and is exempt - internal protocol
    // mechanics handle their own leverage accounting.
    error NoBorrowingAgainstTurbo(uint256 depositId);
    // §M4 - a deposit attached to a Consolidated Reinvestment Pool is frozen:
    // its borrow capacity is reserved for the pool's own Turbo sweep, so a
    // user-driven loan/Turbo against it is rejected. Detach first.
    error DepositPoolAttached(uint256 depositId);

    function initialize(
        address admin,
        address asset_,
        address bondContract_,
        address treasury_,
        address safeVault_,
        uint256 maxLtvBps_,
        uint256 liquidationThresholdBps_,
        uint256 loanAprBps_
    ) external {
        _initializeAccessControl(admin);
        if (
            asset_ == address(0) || bondContract_ == address(0) || treasury_ == address(0)
                || safeVault_ == address(0)
        ) {
            revert ZeroAddress();
        }
        asset = IERC20(asset_);
        bondContract = bondContract_;
        treasury = treasury_;
        safeVault = safeVault_;
        maxLtvBps = maxLtvBps_;
        liquidationThresholdBps = liquidationThresholdBps_;
        loanAprBps = loanAprBps_;
    }

    function setMaxLtvBps(uint256 newBps) external onlyRole(PARAMETER_ROLE) {
        maxLtvBps = newBps;
        emit ParameterUpdated(keccak256("MAX_LTV_BPS"), newBps);
    }

    function setLiquidationThresholdBps(uint256 newBps) external onlyRole(PARAMETER_ROLE) {
        liquidationThresholdBps = newBps;
        emit ParameterUpdated(keccak256("LIQ_THRESHOLD_BPS"), newBps);
    }

    /* ----------------------------------------------------------------- */
    /*  §M6 - who may liquidate, and where the bonus goes                 */
    /* ----------------------------------------------------------------- */

    /**
     * §M6 (Jul 2026 client review): "I would rather any liquidations were
     * done automatically by the system (or triggered by admin), not a random
     * person. With the balance going to Ops/mar wallet, not some 3rd party."
     *
     * When true, `liquidate` is restricted to holders of LIQUIDATOR_ROLE -
     * i.e. the protocol's own keeper and whoever governance authorises.
     * When false it is permissionless again (the original design, where an
     * open market of liquidators guarantees bad debt is always cleared even
     * if the protocol's own keeper is down).
     *
     * Governance can flip this at any time; it is a policy lever, not an
     * economic invariant. The 85% threshold, the atomic bond-interest
     * netting that precedes it, and the depositor's right to the collateral
     * residual are all unchanged either way.
     */
    bool public restrictedLiquidation;

    /**
     * §M6 - where the liquidation bonus is paid. When set, the bonus goes
     * here (the Ops / marketing wallet) instead of to whoever sent the
     * transaction. Unset (address(0)) preserves the original behaviour of
     * paying the caller, which is what makes permissionless liquidation
     * economically self-sustaining.
     */
    address public liquidationBonusReceiver;

    event LiquidationPolicyUpdated(bool restricted, address bonusReceiver);

    error LiquidationRestricted(address caller);

    function setLiquidationPolicy(bool restricted, address bonusReceiver)
        external
        onlyRole(PARAMETER_ROLE)
    {
        restrictedLiquidation = restricted;
        liquidationBonusReceiver = bonusReceiver;
        emit LiquidationPolicyUpdated(restricted, bonusReceiver);
    }

    function setLoanAprBps(uint256 newBps) external onlyRole(PARAMETER_ROLE) {
        loanAprBps = newBps;
        emit ParameterUpdated(keccak256("LOAN_APR_BPS"), newBps);
    }

    /**
     * Registers the M4 Consolidated Yield Reinvestment module so
     * `liquidate` can notify it when a pooled deposit is wound down -
     * the pool then materializes whatever bonus had accrued for its
     * owner before the position closes.
     */
    function setCyrContract(address cyr) external onlyRole(PARAMETER_ROLE) {
        cyrContract = cyr;
        emit CyrContractSet(cyr);
    }

    function openLoan(uint256 depositId, uint256 amount) external nonReentrant whenNotPaused {
        // §V6.2 - Turbo deposits expose no borrow capacity to the user.
        // The Turbo product's routing (80/10/9/1) already reflects
        // the converged 2.5x leveraged end-state, so any additional
        // user-driven loan against it would breach the spec's "all
        // collateral already deployed" invariant. CYR auto-compound
        // (which routes through `openLoanForCyr`) is the only path
        // still allowed to draw against a Turbo deposit, and only to
        // fund a fresh compounded Turbo NFT - internal mechanics, not
        // discretionary user borrow.
        _assertNotTurbo(depositId);
        // §M4 - a pool-attached deposit is frozen; its borrow capacity belongs
        // to the pool's Turbo sweep. Reject user-driven borrows (the pool's
        // own sweep uses openLoanForCyr, which is intentionally not guarded).
        if (cyrContract != address(0) && ICyrAttachView(cyrContract).isAttached(depositId)) {
            revert DepositPoolAttached(depositId);
        }
        _openLoanCore(depositId, amount, msg.sender, msg.sender);
    }

    /**
     * Operator-only loan opener used by Turbo + AutoCompound to borrow
     * on behalf of a deposit owner. USDC is delivered to `recipient`
     * (the calling Turbo / AutoCompound contract) rather than the
     * borrower, so the orchestrator can chain it into a follow-up
     * action (e.g. `openDepositFor(borrower, amount)`).
     *
     * Authentication: msg.sender must hold LENDING_OPERATOR_ROLE.
     * The borrower MUST be the deposit's owner - operator can borrow
     * for them but cannot reassign ownership.
     */
    function openLoanForBorrower(address borrower, uint256 depositId, uint256 amount, address recipient)
        external
        nonReentrant
        onlyRole(LENDING_OPERATOR_ROLE)
    whenNotPaused {
        if (recipient == address(0)) {
            revert ZeroAddress();
        }
        // §V6.2 - see openLoan: Turbo blocked at the user-facing entry
        // points. Legacy Turbo / AutoCompound contracts route through
        // here; both are dormant in V6.2 strict so the guard is
        // tightening the surface, not breaking a live flow.
        _assertNotTurbo(depositId);
        // §M4 - same freeze as openLoan: a pool-attached deposit cannot be
        // leveraged via the user Turbo path (executeTurbo) or independent
        // Turbo auto-compound. The pool's own sweep uses openLoanForCyr.
        if (cyrContract != address(0) && ICyrAttachView(cyrContract).isAttached(depositId)) {
            revert DepositPoolAttached(depositId);
        }
        _openLoanCore(depositId, amount, borrower, recipient);
    }

    /** §V6.3 Turbo loop - registers the Turbo orchestrator permitted to
     *  borrow against Turbo rungs via `openLoanForTurboLoop`. */
    function setTurboLoopContract(address turboLoop) external onlyRole(PARAMETER_ROLE) {
        turboLoopContract = turboLoop;
        emit TurboLoopContractSet(turboLoop);
    }

    /**
     * §V6.3 Turbo-loop borrow leg. Like `openLoanForBorrower` but callable
     * ONLY by the registered Turbo orchestrator and the SOLE path EXEMPT
     * from `_assertNotTurbo` - the recursive leverage loop must borrow
     * against each Turbo (mode-1) rung it mints. User-facing borrows against
     * Turbo stay blocked; the pool-attached freeze still applies. USDC goes
     * to `recipient` (the Turbo contract); the loan stays owned by the
     * deposit owner, who remains liable and must repay to settle the rung.
     */
    function openLoanForTurboLoop(uint256 depositId, uint256 amount, address recipient)
        external
        nonReentrant
        whenNotPaused returns (address borrower)
    {
        if (msg.sender != turboLoopContract) {
            revert NotTurboLoopCaller(msg.sender);
        }
        if (recipient == address(0)) {
            revert ZeroAddress();
        }
        IBondContract.Deposit memory deposit = IBondContract(bondContract).getDeposit(depositId);
        borrower = deposit.owner;
        // Intentionally NO _assertNotTurbo here - the one exempt path.
        if (cyrContract != address(0) && ICyrAttachView(cyrContract).isAttached(depositId)) {
            revert DepositPoolAttached(depositId);
        }
        _openLoanCore(depositId, amount, borrower, recipient);
    }

    /**
     * §I.6 CYR-callable loan opener for pool-level Auto-Compound
     * sweeps. The Turbo flavour of `sweepPool` iterates pool members
     * borrowing incrementally until enough leverage is gathered to
     * fund the new compounded deposit; this is the per-member draw.
     * USDC is delivered to `recipient` (CYR), the loan stays owned by
     * the deposit's owner. Authorisation is by stored address so CYR
     * doesn't need an additional role grant.
     */
    function openLoanForCyr(uint256 depositId, uint256 amount, address recipient)
        external
        nonReentrant
        whenNotPaused returns (address borrower)
    {
        if (msg.sender != cyrContract) {
            revert NotCyrCaller(msg.sender);
        }
        if (recipient == address(0)) {
            revert ZeroAddress();
        }
        IBondContract.Deposit memory deposit = IBondContract(bondContract).getDeposit(depositId);
        borrower = deposit.owner;
        _openLoanCore(depositId, amount, borrower, recipient);
    }

    /**
     * View used by CYR's Turbo sweep to figure out which member
     * deposits still have borrow headroom. Returns the additional
     * USDC the deposit can be drawn against right now, respecting
     * the live LTV cap. Returns 0 if there is no headroom (already at
     * cap, deposit inactive, or loan in liquidation state).
     */
    function availableBorrowCapacity(uint256 depositId) external view returns (uint256 capacity) {
        IBondContract.Deposit memory deposit = IBondContract(bondContract).getDeposit(depositId);
        if (deposit.owner == address(0)) return 0;
        if (deposit.state != IGilderTypes.DepositState.Active) return 0;
        // §V6.2 - Turbo deposits report zero capacity to USER-facing
        // callers. The SafeVault slot still holds 50% of principal so
        // CYR's internal auto-compound flows need real numbers - they
        // call `internalBorrowCapacity` (below) which skips this
        // guard. Returning 0 here keeps the Lending page, frontend
        // headroom, and Dashboard "Available to borrow" line in
        // lockstep with the `_assertNotTurbo` revert at write time.
        if (deposit.productMode == 1) return 0;
        return _rawBorrowCapacity(deposit, depositId);
    }

    /**
     * §V6.2 - CYR-only view that returns real borrow capacity
     * regardless of productMode. The pool-sweep + independent-compound
     * flows need this on Turbo source deposits so the Turbo leverage
     * leg actually gets funded; reusing the user-facing
     * `availableBorrowCapacity` (which masks Turbo to zero) would
     * make every Turbo auto-compound revert with
     * `InsufficientLeverageCapacity`.
     *
     * Access-controlled: only the registered CYR module may call.
     * Same gating pattern as `openLoanForCyr`.
     */
    function internalBorrowCapacity(uint256 depositId) external view returns (uint256 capacity) {
        if (msg.sender != cyrContract) revert NotCyrCaller(msg.sender);
        IBondContract.Deposit memory deposit = IBondContract(bondContract).getDeposit(depositId);
        if (deposit.owner == address(0)) return 0;
        if (deposit.state != IGilderTypes.DepositState.Active) return 0;
        return _rawBorrowCapacity(deposit, depositId);
    }

    /**
     * Shared math for both capacity views: collateral x maxLtvBps,
     * net of any outstanding debt. Product-mode-agnostic.
     */
    function _rawBorrowCapacity(IBondContract.Deposit memory deposit, uint256 depositId)
        private
        view
        returns (uint256)
    {
        uint256 collateralValue = _collateralValue(deposit);
        uint256 maxDebt = (collateralValue * maxLtvBps) / BPS_DENOMINATOR;
        Loan storage loan = _loans[depositId];
        uint256 currentDebt = loan.open ? loan.principal + loan.accruedInterest : 0;
        if (currentDebt >= maxDebt) return 0;
        uint256 ltvHeadroom = maxDebt - currentDebt;
        // Cap advertised headroom by what SafeVault can actually disburse so
        // availableBorrowCapacity / internalBorrowCapacity never over-report
        // capacity the vault would reject at disburseLoan time.
        uint256 vaultHeadroom = ISafeVault(safeVault).availableForLoan(depositId);
        return ltvHeadroom < vaultHeadroom ? ltvHeadroom : vaultHeadroom;
    }

    /**
     * §V6.2 - guard used by user-facing loan entry points to refuse
     * borrows against Turbo deposits. CYR's auto-compound flow
     * (`openLoanForCyr`) deliberately doesn't call this - internal
     * leverage draws for sweep-driven compounding are still allowed.
     */
    function _assertNotTurbo(uint256 depositId) private view {
        IBondContract.Deposit memory deposit = IBondContract(bondContract).getDeposit(depositId);
        if (deposit.productMode == 1) {
            revert NoBorrowingAgainstTurbo(depositId);
        }
    }

    function _openLoanCore(uint256 depositId, uint256 amount, address borrower, address recipient) private {
        IBondContract.Deposit memory deposit = IBondContract(bondContract).getDeposit(depositId);
        if (deposit.owner == address(0)) {
            revert InvalidDepositForLoan(depositId);
        }
        if (deposit.owner != borrower) {
            revert InvalidDepositForLoan(depositId);
        }
        if (deposit.state != IGilderTypes.DepositState.Active) {
            revert InvalidDepositForLoan(depositId);
        }
        // §Phase 2 Marketplace - a listed deposit's collateral is frozen. Without
        // this a seller could list, borrow out the Safe-Vault collateral (keeping
        // the USDC), then sell the debt to a buyer who paid a price set against
        // the pre-borrow leverage. Covers every borrow path (user, Turbo re-loop,
        // CYR) since they all funnel through here; fresh rungs are never listed,
        // so the legitimate Turbo/CYR flows are unaffected.
        if (IBondContract(bondContract).isDepositListed(depositId)) {
            revert DepositListedForLoan(depositId);
        }
        Loan storage loan = _loans[depositId];
        uint256 collateralValue = _collateralValue(deposit);

        if (loan.open) {
            // Incremental (split) borrow: the deposit already carries an
            // open loan, so this draw ADDS to it instead of being
            // rejected. A borrower can therefore consume their capacity
            // in several chunks rather than one lump sum. We accrue
            // first so the LTV gate sees up-to-date interest, then check
            // the COMBINED debt (existing principal + accrued interest +
            // new draw) against maxLtvBps.
            if (loan.borrower != borrower) {
                revert InvalidDepositForLoan(depositId);
            }
            _accrue(loan, depositId);
            // §Code-Review C2 Fix 1 - netting on-touch: every loan touch point
            // cancels available bond interest against the accrued loan
            // interest, so a position that is being actively used never
            // drifts toward the liquidation threshold through inaction.
            _netAgainstBondInterest(depositId, loan);
            uint256 newDebt = loan.principal + loan.accruedInterest + amount;
            uint256 ltvAfter = (newDebt * BPS_DENOMINATOR) / collateralValue;
            if (ltvAfter > maxLtvBps) {
                revert LtvExceedsMax(ltvAfter, maxLtvBps);
            }
            loan.principal += amount;
            IBondContract(bondContract).setLoanState(depositId, loan.principal, loan.accruedInterest);
            ISafeVault(safeVault).disburseLoan(depositId, recipient, amount);
            emit LoanOpened(depositId, borrower, amount);
            return;
        }

        uint256 ltv = (amount * BPS_DENOMINATOR) / collateralValue;
        if (ltv > maxLtvBps) {
            revert LtvExceedsMax(ltv, maxLtvBps);
        }

        loan.borrower = borrower;
        loan.principal = amount;
        loan.accruedInterest = 0;
        loan.openedAt = uint64(block.timestamp);
        loan.lastAccruedAt = uint64(block.timestamp);
        loan.open = true;

        IBondContract(bondContract).setLoanState(depositId, amount, 0);
        ISafeVault(safeVault).disburseLoan(depositId, recipient, amount);
        emit LoanOpened(depositId, borrower, amount);
    }

    function repayLoan(uint256 depositId, uint256 amount) external nonReentrant whenNotPaused {
        Loan storage loan = _loans[depositId];
        if (!loan.open) {
            revert LoanNotOpen(depositId);
        }
        _accrue(loan, depositId);
        // §Code-Review C2 Fix 1 - netting on-touch (see _openLoanCore). The
        // borrower's available bond interest services the loan interest
        // first, so out-of-pocket repayment only covers the true shortfall.
        _netAgainstBondInterest(depositId, loan);
        uint256 owed = loan.principal + loan.accruedInterest;
        if (amount > owed) {
            revert RepayExceedsDebt(amount, owed);
        }
        _executeRepay(loan, depositId, amount);
    }

    /**
     * Full-repay shortcut: pays whatever is owed at THIS block, eliminating
     * the dust that results from interest accruing between an off-chain
     * preview and the on-chain tx (which can leave ~$0.000004 outstanding
     * after a "full" repay quoted client-side).
     *
     * Caller MUST have approved Lending for at least the off-chain quote
     * plus a safety margin. The standard frontend uses `MaxUint256`, so
     * any growth between approval time and tx execution is covered.
     */
    function repayFull(uint256 depositId) external nonReentrant whenNotPaused {
        Loan storage loan = _loans[depositId];
        if (!loan.open) {
            revert LoanNotOpen(depositId);
        }
        _accrue(loan, depositId);
        // §Code-Review C2 Fix 1 - netting on-touch: bond interest services the
        // loan interest first, so the borrower's wallet only funds the rest.
        _netAgainstBondInterest(depositId, loan);
        uint256 owed = loan.principal + loan.accruedInterest;
        if (owed == 0) {
            revert LoanNotOpen(depositId);
        }
        _executeRepay(loan, depositId, owed);
    }

    function _executeRepay(Loan storage loan, uint256 depositId, uint256 amount) private {
        uint256 interestPaid = amount > loan.accruedInterest ? loan.accruedInterest : amount;
        uint256 principalPaid = amount - interestPaid;

        // Single allowance pattern: the borrower approves Lending only.
        // Lending pulls the whole repayment into itself, then forwards
        // principal to SafeVault and interest to Treasury via plain
        // transfers (no further approvals required). This keeps the UX
        // to ONE approve(lending, ...) call per borrower.
        if (!asset.transferFrom(loan.borrower, address(this), amount)) {
            revert TransferFailed();
        }

        if (principalPaid > 0) {
            if (!asset.transfer(safeVault, principalPaid)) {
                revert TransferFailed();
            }
            ISafeVault(safeVault).noteRepayment(depositId, loan.borrower, principalPaid);
        }
        if (interestPaid > 0) {
            if (!asset.transfer(treasury, interestPaid)) {
                revert TransferFailed();
            }
            ITreasury(treasury).returnLoanCapital(depositId, 0, interestPaid);
        }
        loan.accruedInterest -= interestPaid;
        loan.principal -= principalPaid;

        if (loan.principal == 0 && loan.accruedInterest == 0) {
            loan.open = false;
        }
        IBondContract(bondContract).setLoanState(depositId, loan.principal, loan.accruedInterest);
        emit LoanRepaid(depositId, loan.borrower, amount);
    }

    function accrueLoan(uint256 depositId) external whenNotPaused returns (uint256 newlyAccrued) {
        Loan storage loan = _loans[depositId];
        if (!loan.open) {
            revert LoanNotOpen(depositId);
        }
        newlyAccrued = _accrue(loan, depositId);
        // §Code-Review C2 Fix 1 - netting on-touch: any keeper/indexer poke
        // that accrues the loan also applies the self-paying defence, so
        // positions that are monitored can never drift by omission.
        _netAgainstBondInterest(depositId, loan);
    }

    function liquidate(uint256 depositId) external nonReentrant whenNotPaused returns (uint256 collateralSeized) {
        // §M6 - optional allowlist. Off by default at the contract level;
        // the deploy script turns it ON and grants LIQUIDATOR_ROLE to the
        // protocol keeper, per the client's "triggered by the system or
        // admin, not a random person".
        if (restrictedLiquidation && !hasRole(LIQUIDATOR_ROLE, msg.sender)) {
            revert LiquidationRestricted(msg.sender);
        }
        Loan storage loan = _loans[depositId];
        if (!loan.open) {
            revert LoanNotOpen(depositId);
        }
        _accrue(loan, depositId);
        // §Code-Review C2/N3 (Jul 2026) - the netting defence is ATOMIC inside
        // liquidate itself: accrue the bond side, net available bond interest
        // against the loan, and only THEN test the threshold. With this
        // ordering a borrower whose accrued bond interest covers the loan
        // drift can never be wrongfully seized, no keeper race exists, and
        // permissionless liquidation is safe by construction - it only
        // succeeds against a genuine shortfall.
        _netAgainstBondInterest(depositId, loan);
        IBondContract.Deposit memory deposit = IBondContract(bondContract).getDeposit(depositId);
        // Defence-in-depth (review observation 4): terminal-state deposits can
        // never interact with the loan path. A live loan structurally implies
        // Active/Matured/Dormant/Abandoned, but enforce it explicitly.
        if (
            deposit.state == IGilderTypes.DepositState.None
                || deposit.state == IGilderTypes.DepositState.Exited
                || deposit.state == IGilderTypes.DepositState.Closed
        ) {
            revert InvalidDepositForLoan(depositId);
        }
        uint256 collateralValue = _collateralValue(deposit);
        uint256 debt = loan.principal + loan.accruedInterest;
        uint256 ltv = (debt * BPS_DENOMINATOR) / collateralValue;
        // §Code-Review N4 - inside the post-maturity grace window only the
        // HARD ceiling is liquidatable; the standard threshold resumes after
        // the window lapses. Pre-maturity the standard threshold applies
        // (netting above already guarantees a genuine shortfall).
        uint256 threshold = liquidationThresholdBps;
        if (
            block.timestamp >= deposit.maturityTime
                && block.timestamp < uint256(deposit.maturityTime) + TURBO_POST_MATURITY_GRACE_PERIOD
                && HARD_LIQUIDATION_CEILING_BPS > threshold
        ) {
            threshold = HARD_LIQUIDATION_CEILING_BPS;
        }
        if (ltv < threshold) {
            revert LtvBelowLiquidation(ltv, threshold);
        }

        // Liquidation forfeits the full collateral slice from SafeVault.
        // The deposit's safeVault slice was the loan's source AND its
        // collateral; SafeVault clears the debt, pays the liquidator
        // bonus out of the (collateral - debt) surplus, and returns the
        // REMAINING principal to the depositor (spec §14.5).
        uint256 liquidatorBonus = (debt * LIQUIDATION_BONUS_BPS) / BPS_DENOMINATOR;
        loan.principal = 0;
        loan.accruedInterest = 0;
        loan.open = false;

        // §M6 - the bonus goes to the configured Ops / marketing wallet when
        // one is set, so value never leaks to an unrelated third party. Falls
        // back to the caller (the original permissionless incentive) when
        // governance has left the receiver unset.
        address bonusTo = liquidationBonusReceiver == address(0)
            ? msg.sender
            : liquidationBonusReceiver;
        (uint256 forfeited, uint256 outstandingCleared) =
            ISafeVault(safeVault).forfeitCollateral(depositId, deposit.owner, bonusTo, liquidatorBonus);
        collateralSeized = forfeited;
        IBondContract(bondContract).setLoanState(depositId, 0, 0);
        IBondContract(bondContract).markLiquidated(depositId);

        // §M4: if the liquidated deposit was pooled, let the CYR module
        // materialize its accrued bonus + auto-detach. Best-effort
        // (try/catch) so a fault in the reinvestment module can never
        // block a liquidation - solvency discipline outranks it.
        address cyr = cyrContract;
        if (cyr != address(0)) {
            // SettlementReason.Liquidation == 4
            try ICyrSettlementHook(cyr).onSettlement(depositId, 4) {} catch {}
        }

        // Report the full cancelled debt (principal + loan interest), not the
        // SafeVault principal-only figure, so the event reconciles with debt.
        emit LoanLiquidated(depositId, msg.sender, debt, collateralSeized, liquidatorBonus);
    }

    /**
     * §Code-Review C2/N3 (Jul 2026) - PERMISSIONLESS. Previously gated behind
     * LENDING_OPERATOR_ROLE, which left the netting defence "orphaned" (no
     * code path invoked it). The function is safe to open up because the
     * netted amount is derived ON-CHAIN from the deposit's real accrued bond
     * interest - `depositInterestAvailable` is honoured only as an upper
     * bound, never trusted as the availability figure. Netting is capped at
     * `loan.accruedInterest` and can only ever improve a position.
     */
    function netInterestAgainstLoan(uint256 depositId, uint256 depositInterestAvailable)
        external
        whenNotPaused returns (uint256 netted)
    {
        Loan storage loan = _loans[depositId];
        if (!loan.open) {
            return 0;
        }
        _accrue(loan, depositId);
        if (depositInterestAvailable == 0 || loan.accruedInterest == 0) {
            return 0;
        }
        netted = _netAgainstBondInterest(depositId, loan, depositInterestAvailable);
    }

    /**
     * §Code-Review N4 (Jul 2026) - atomic net-settlement leg. Called ONLY by
     * BondContract's `settleMaturedNet`: nets whatever bond interest is still
     * available, then closes the loan against the settlement proceeds -
     * SafeVault's claim on the deposit shrinks by the loan principal
     * (accounting-only, the USDC left the vault at disburse time) and the
     * remaining loan interest is reported back so the settlement engine can
     * withhold it from the Treasury payout. Removes the need for a borrower
     * to source external USDC to unwind a matured leveraged stack.
     */
    function closeLoanForSettlement(uint256 depositId)
        external
        nonReentrant
        whenNotPaused returns (uint256 principalOwed, uint256 interestOwed)
    {
        if (msg.sender != bondContract) {
            revert NotBondContractCaller(msg.sender);
        }
        Loan storage loan = _loans[depositId];
        if (!loan.open) {
            return (0, 0);
        }
        _accrue(loan, depositId);
        // Give the position its netting defence first - bond interest still
        // on the books cancels loan interest 1:1 before any withholding.
        _netAgainstBondInterest(depositId, loan, type(uint256).max);
        principalOwed = loan.principal;
        interestOwed = loan.accruedInterest;
        address borrower = loan.borrower;
        loan.principal = 0;
        loan.accruedInterest = 0;
        loan.open = false;
        // Clear the vault-side debt against the deposit's own claim - no
        // USDC moves (the loaned capital left the vault at disburse time;
        // the depositor's claim shrinks by exactly that amount).
        ISafeVault(safeVault).netSettleLoan(depositId);
        IBondContract(bondContract).setLoanState(depositId, 0, 0);
        emit LoanNetSettled(depositId, borrower, principalOwed, interestOwed);
    }

    /**
     * Shared netting core (§Code-Review C2 Fix 1). Brings the BOND side
     * current, derives the real bond-interest availability on-chain, and
     * cancels the lesser of (available bond interest, accrued loan interest,
     * `maxAmount`) against the loan. Mirrored through
     * `applyInterestToLoan` so the deposit's withdrawable interest drops by
     * the same amount (disclosed to users via SelfPayingNettingApplied).
     * Caller must have `_accrue`d the loan already.
     */
    function _netAgainstBondInterest(uint256 depositId, Loan storage loan, uint256 maxAmount)
        private
        returns (uint256 netted)
    {
        if (!loan.open || loan.accruedInterest == 0 || maxAmount == 0) {
            return 0;
        }
        IBondContract(bondContract).accrueInterest(depositId);
        IBondContract.Deposit memory deposit = IBondContract(bondContract).getDeposit(depositId);
        uint256 available = deposit.accruedInterest;
        if (available == 0) {
            return 0;
        }
        netted = available < loan.accruedInterest ? available : loan.accruedInterest;
        if (netted > maxAmount) {
            netted = maxAmount;
        }
        loan.accruedInterest -= netted;
        IBondContract(bondContract).applyInterestToLoan(depositId, netted);
        IBondContract(bondContract).setLoanState(depositId, loan.principal, loan.accruedInterest);
        emit SelfPayingNettingApplied(depositId, netted);
    }

    /// Two-arg convenience overload used by the touch points.
    function _netAgainstBondInterest(uint256 depositId, Loan storage loan) private returns (uint256 netted) {
        return _netAgainstBondInterest(depositId, loan, type(uint256).max);
    }

    function loanOf(uint256 depositId) external view returns (Loan memory loan) {
        return _loans[depositId];
    }

    /**
     * §Phase 2 Marketplace - registers the authorised Bond Marketplace, the
     * only contract permitted to migrate a loan's borrower on secondary sale.
     */
    function setMarketplace(address marketplace_) external onlyRole(PARAMETER_ROLE) {
        if (marketplace_ == address(0)) {
            revert ZeroAddress();
        }
        marketplace = marketplace_;
        emit MarketplaceSet(marketplace_);
    }

    /**
     * §Phase 2 Marketplace - re-points an open loan's borrower to the NFT's
     * new owner during atomic marketplace settlement. Per the client's ruling,
     * Turbo/Leverage debt travels with the position: nothing is repaid on
     * transfer, the buyer simply becomes the borrower of record (and inherits
     * the liquidation risk, disclosed in the UI before purchase).
     *
     * Marketplace-only, and only for an open loan. The principal, accrued
     * interest and accrual clock are untouched - only the `borrower` address
     * moves - so the debt's economics are identical before and after the sale.
     * A no-op (returns without event) when the deposit carries no open loan,
     * so the marketplace can call it unconditionally over every position
     * member without first branching on loan state.
     */
    function migrateBorrower(uint256 depositId, address newBorrower) external whenNotPaused {
        if (msg.sender != marketplace) {
            revert NotMarketplace(msg.sender);
        }
        if (newBorrower == address(0)) {
            revert ZeroAddress();
        }
        Loan storage loan = _loans[depositId];
        if (!loan.open) {
            return;
        }
        address previous = loan.borrower;
        if (previous == newBorrower) {
            return;
        }
        loan.borrower = newBorrower;
        emit BorrowerMigrated(depositId, previous, newBorrower);
    }

    function currentLtvBps(uint256 depositId) external view returns (uint256 ltvBps) {
        Loan storage loan = _loans[depositId];
        if (!loan.open) {
            return 0;
        }
        IBondContract.Deposit memory deposit = IBondContract(bondContract).getDeposit(depositId);
        uint256 collateralValue = _collateralValue(deposit);
        if (collateralValue == 0) {
            return type(uint256).max;
        }
        uint256 debt = loan.principal + loan.accruedInterest + _pendingInterest(loan);
        return (debt * BPS_DENOMINATOR) / collateralValue;
    }

    function _accrue(Loan storage loan, uint256 depositId) private returns (uint256 newlyAccrued) {
        newlyAccrued = _pendingInterest(loan);
        if (newlyAccrued == 0) {
            return 0;
        }
        loan.accruedInterest += newlyAccrued;
        loan.lastAccruedAt = uint64(block.timestamp);
        IBondContract(bondContract).setLoanState(depositId, loan.principal, loan.accruedInterest);
        emit LoanAccrued(depositId, newlyAccrued);
    }

    function _pendingInterest(Loan storage loan) private view returns (uint256) {
        if (block.timestamp <= loan.lastAccruedAt) return 0;
        uint256 elapsed = block.timestamp - loan.lastAccruedAt;
        // Spec §C.5: interest collections (protocol receivable) round UP
        // toward the protocol. RoundingLib.roundUpToUser is the ceiling
        // primitive - its naming reflects the bond-interest payout case,
        // but mathematically it is exactly the upward direction needed
        // here so the protocol never loses sub-wei of accrued debt to
        // truncation across many small accrual ticks.
        return RoundingLib.roundUpToUser(
            loan.principal * loanAprBps * elapsed,
            BPS_DENOMINATOR * DAYS_PER_YEAR * 1 days
        );
    }

    function _collateralValue(IBondContract.Deposit memory deposit) private pure returns (uint256) {
        // Collateral = the SafeVault protected-principal slice only. This is
        // the sole quantity SafeVault can disburse (disburseLoan) and forfeit
        // (forfeitCollateral). Bond interest accrues on full principal and is
        // paid from Treasury - it is never custodied in SafeVault, so it must
        // not inflate borrow capacity, the LTV gates, or the liquidation
        // trigger. This keeps capacity/LTV consistent with what is actually
        // seizable and removes the stale-accrued wrongful-liquidation vector.
        return deposit.safeVaultAmount;
    }

    // §Phase 2 Marketplace - authorised marketplace (borrower-migration
    // caller). Appended at the end of storage so the upgradeable layout is
    // preserved; the __gap absorbs the slot below.
    address public marketplace;

    // __gap shrunk 40 -> 39 (`cyrContract`), then 39 -> 38 (§M6's
    // `restrictedLiquidation` + `liquidationBonusReceiver` packed into one
    // slot), then 38 -> 37: §Phase 2 `marketplace` consumed one slot.
    uint256[37] private __gap;
}

/**
 * @title Turbo (M3)
 * @notice Atomic leverage: borrow against an existing deposit via the
 *         Lending module + immediately open a NEW deposit funded by the
 *         borrowed USDC. Net effect: 1 user-signed tx leaves the user
 *         with a fresh leveraged position on top of the source deposit.
 *
 * Flow:
 *   1. User calls `executeTurbo(sourceDepositId, borrowAmount)`.
 *   2. Turbo invokes `Lending.openLoanForBorrower(user, sourceDepositId,
 *      borrowAmount, address(this))` -> records loan against user's
 *      source deposit + delivers borrowed USDC to Turbo.
 *   3. Turbo approves BondContract for `borrowAmount`.
 *   4. Turbo calls `BondContract.openDepositFor(user, borrowAmount)` ->
 *      new deposit minted to user, NFT minted to user, capital routed
 *      80/10/9/1 as usual.
 *   5. Single TurboExecuted event ties source <-> new deposit so the
 *      indexer / UI can group them visually.
 */
contract Turbo is ITurbo, GilderModule {
    IERC20 public asset;
    address public bondContract;
    address public lending;

    // §V6.3 Turbo loop - gas backstop; the $100 min-deposit floor normally
    // stops the loop in ~5 rounds (each round borrows ~0.6x the prior deposit).
    uint256 public constant MAX_TURBO_LOOP_ROUNDS = 12;
    // Mirrors BondContract.MIN_DEPOSIT_AMOUNT (100 USDC, 6-dec): a round whose
    // borrow would fall below this stops the loop.
    uint256 public constant MIN_TURBO_REDEPOSIT = 100e6;

    event TurboLoopExecuted(uint256 indexed sourceDepositId, uint256 indexed lastDepositId, uint256 rounds, uint256 totalBorrowed);
    // TurboPositionMemberAdded is declared on ITurbo (inherited).

    error TurboNotInitialised();
    error NotDepositOwner(uint256 depositId, address caller);

    function initialize(address admin, address asset_, address bondContract_, address lending_) external {
        _initializeAccessControl(admin);
        if (asset_ == address(0) || bondContract_ == address(0) || lending_ == address(0)) {
            revert ZeroAddress();
        }
        asset = IERC20(asset_);
        bondContract = bondContract_;
        lending = lending_;
    }

    /// @notice Turbo always opens a fresh FIXED_TERM (1095-day) bond per spec V6.2.
    function executeTurbo(uint256 depositId, uint256 borrowAmount) external nonReentrant whenNotPaused returns (uint256 newDepositId) {
        return _executeTurbo(msg.sender, depositId, borrowAmount);
    }

    /**
     * Operator-only Turbo for protocol modules (e.g. AutoCompound in
     * Turbo mode) that need to leverage a deposit on behalf of its
     * owner. The caller must hold LENDING_OPERATOR_ROLE; `user` must be
     * the deposit's owner (enforced downstream by Lending's owner check).
     */
    function executeTurboFor(address user, uint256 depositId, uint256 borrowAmount)
        external
        nonReentrant
        onlyRole(LENDING_OPERATOR_ROLE)
        whenNotPaused returns (uint256 newDepositId)
    {
        return _executeTurbo(user, depositId, borrowAmount);
    }

    /**
     * §V6.3 - ONE-TX Turbo entry. Pulls the user's USDC, opens the initial
     * Turbo deposit, sets its auto-reinvest mode, and runs the full recursive
     * leverage loop - all in a single signed transaction. The frontend routes
     * every Turbo deposit here, so the user never needs a separate
     * executeTurboLoop / setCompoundMode call.
     *
     * Requires the user to have approved THIS contract for `amount` USDC.
     */
    function openTurboPosition(uint256 amount, uint8 compoundMode)
        external
        nonReentrant
        whenNotPaused returns (uint256 firstDepositId, uint256 lastDepositId, uint256 rounds)
    {
        if (bondContract == address(0) || lending == address(0)) {
            revert TurboNotInitialised();
        }
        address user = msg.sender;
        // Pull the user's USDC in, then fund the initial Turbo deposit via the
        // BondContract (which pulls from this contract as the payer).
        if (!asset.transferFrom(user, address(this), amount)) revert TransferFailed();
        if (!asset.approve(bondContract, amount)) revert TransferFailed();
        firstDepositId = IBondContract(bondContract).openDepositFor(user, amount, uint8(1)); // Turbo
        // Set auto-reinvest at creation (no separate setCompoundMode tx); the
        // loop then propagates it to every rung.
        if (compoundMode != 0) {
            IBondContract(bondContract).setCompoundMode(firstDepositId, compoundMode);
        }
        (lastDepositId, rounds, ) = _executeTurboLoop(user, firstDepositId);
    }

    /**
     * §V6.3 - the recursive Turbo leverage loop. Starting from `depositId`,
     * each round borrows `maxLtvBps` (75%) of the rung's Safe-Vault collateral
     * and re-deposits it as a fresh Turbo (mode-1) rung. The geometric series
     * (each round ~0.6x the prior deposit) converges to ~2.5x total gross and
     * ~1.5x total loan, so the net 27.5% EMERGES (20% per rung, 15% loan) -
     * it is not a stored rate. Stops when the next borrow falls below the
     * $100 min-deposit floor or MAX_TURBO_LOOP_ROUNDS is hit. One signed tx.
     *
     * Each rung's loan is owned by the user and collateralised by that rung's
     * Safe Vault. To settle/mature the stack the loans must be repaid: the
     * rungs unwind TOP-DOWN - the last (un-borrowed-against) rung settles
     * first and funds repayment of the loan below it, and so on up.
     */
    function executeTurboLoop(uint256 depositId)
        external
        nonReentrant
        whenNotPaused returns (uint256 lastDepositId, uint256 rounds, uint256 totalBorrowed)
    {
        return _executeTurboLoop(msg.sender, depositId);
    }

    /**
     * §V6.3 - operator-only Turbo loop for protocol modules (e.g. the CYR
     * Automated-Reinvestment keeper) that run the loop on a fresh reinvested
     * deposit on the owner's behalf. Caller must hold LENDING_OPERATOR_ROLE;
     * `user` must own `depositId` (enforced inside the loop).
     */
    function executeTurboLoopFor(address user, uint256 depositId)
        external
        nonReentrant
        onlyRole(LENDING_OPERATOR_ROLE)
        whenNotPaused returns (uint256 lastDepositId, uint256 rounds, uint256 totalBorrowed)
    {
        return _executeTurboLoop(user, depositId);
    }

    function _executeTurboLoop(address user, uint256 depositId)
        private
        returns (uint256 lastDepositId, uint256 rounds, uint256 totalBorrowed)
    {
        if (bondContract == address(0) || lending == address(0)) {
            revert TurboNotInitialised();
        }
        uint256 maxLtv = ILending(lending).maxLtvBps();
        uint256 currentId = depositId;
        // §V6.3 - every rung inherits the source deposit's auto-reinvest
        // setting, so the whole leveraged stack reinvests (Turbo Automated
        // Reinvestment spec). Read once from the source.
        uint8 sourceCompoundMode = IBondContract(bondContract).getDeposit(depositId).compoundMode;

        for (uint256 i = 0; i < MAX_TURBO_LOOP_ROUNDS; i++) {
            IBondContract.Deposit memory d = IBondContract(bondContract).getDeposit(currentId);
            if (d.owner != user) revert NotDepositOwner(currentId, user);

            // Borrowable = 75% of this rung's Safe-Vault collateral, net of
            // any debt already on it (fresh rungs have none).
            uint256 maxDebt = (d.safeVaultAmount * maxLtv) / 10_000;
            uint256 existingDebt = d.loanBalance + d.loanAccruedInterest;
            if (maxDebt <= existingDebt) break;
            uint256 borrow = maxDebt - existingDebt;
            if (borrow < MIN_TURBO_REDEPOSIT) break;

            // Borrow against the rung (the §V6.3 Turbo-exempt path); USDC
            // arrives here, then funds a fresh Turbo rung owned by the user.
            ILending(lending).openLoanForTurboLoop(currentId, borrow, address(this));
            if (!asset.approve(bondContract, borrow)) revert TransferFailed();
            currentId = IBondContract(bondContract).openDepositFor(user, borrow, uint8(1));
            // §Phase 2 Marketplace - attach the fresh rung to the position root
            // (the loop's source deposit) so the whole stack lists and sells as
            // one unit. Root resolves through `depositId`, constant across the
            // loop even though the collateral parent chains rung-to-rung.
            _recordTurboMember(depositId, currentId);
            // Propagate the auto-reinvest mode onto the new rung.
            if (sourceCompoundMode != 0) {
                IBondContract(bondContract).setCompoundMode(currentId, sourceCompoundMode);
            }

            totalBorrowed += borrow;
            rounds++;
        }

        lastDepositId = currentId;
        emit TurboLoopExecuted(depositId, lastDepositId, rounds, totalBorrowed);
    }

    /**
     * §17.5 Turbo Compound helper: opens a loan against `sourceId` for
     * `borrowAmount` and routes the USDC to `recipient` (AutoCompound).
     * Does NOT redeposit - the caller combines the borrowed USDC with
     * the compound's accrued interest and opens ONE leveraged deposit
     * via BondContract directly. This collapses the legacy two-deposit
     * compound pattern (seed + leveraged inner) into a single deposit
     * whose principal = `interest + borrow`, neatly clearing the §3.2
     * $100 MIN_DEPOSIT floor without needing a bypass.
     */
    function borrowForCompound(
        address user,
        uint256 sourceId,
        uint256 borrowAmount,
        address recipient
    )
        external
        nonReentrant
        onlyRole(LENDING_OPERATOR_ROLE)
    whenNotPaused {
        if (lending == address(0)) {
            revert TurboNotInitialised();
        }
        ILending(lending).openLoanForBorrower(user, sourceId, borrowAmount, recipient);
    }

    function _executeTurbo(address user, uint256 depositId, uint256 borrowAmount)
        private
        returns (uint256 newDepositId)
    {
        if (bondContract == address(0) || lending == address(0)) {
            revert TurboNotInitialised();
        }
        // Step 1: borrow on the user's behalf, USDC arrives here.
        ILending(lending).openLoanForBorrower(user, depositId, borrowAmount, address(this));

        // Step 2: approve BondContract to pull the borrowed USDC and
        // mint the leveraged deposit under the user. The redeposit
        // amount must clear the §3.2 $100 MIN_DEPOSIT floor. §V6.2 -
        // a Turbo leveraged redeposit produces a Turbo product (1).
        if (!asset.approve(bondContract, borrowAmount)) {
            revert TransferFailed();
        }
        newDepositId = IBondContract(bondContract).openDepositFor(user, borrowAmount, uint8(1));
        // §Phase 2 Marketplace - attach the leveraged child to its position
        // root so the marketplace transfers the parent and every child rung
        // together as a single economic position (spec §D.6).
        _recordTurboMember(depositId, newDepositId);

        emit TurboExecuted(depositId, newDepositId, borrowAmount);
    }

    /**
     * §Phase 2 Marketplace - records `newRung` as a member of the Turbo
     * position rooted at `sourceId`'s ultimate root. The root is the original
     * (unleveraged) deposit the user holds and would list; every rung minted
     * by the loop - however deep the collateral chain - resolves to that same
     * root here. The member list is seeded with the root itself as element 0
     * on first attachment, so `positionMembers(root)` returns [root, ...rungs].
     */
    function _recordTurboMember(uint256 sourceId, uint256 newRung) private {
        uint256 root = turboRootOf[sourceId];
        if (root == 0) {
            root = sourceId;
        }
        if (_turboMembers[root].length == 0) {
            _turboMembers[root].push(root);
        }
        _turboMembers[root].push(newRung);
        turboRootOf[newRung] = root;
        emit TurboPositionMemberAdded(root, newRung);
    }

    /**
     * §Phase 2 Marketplace - resolves the position root for any token: the
     * token's root if it is a leveraged rung, else the token itself.
     */
    function turboRoot(uint256 tokenId) public view returns (uint256 root) {
        root = turboRootOf[tokenId];
        if (root == 0) {
            root = tokenId;
        }
    }

    /**
     * §Phase 2 Marketplace - the full set of deposit/NFT ids that make up the
     * position containing `tokenId`, including the root. A plain (never-Turbo)
     * deposit returns just `[tokenId]`, so the marketplace can treat every
     * listing uniformly as a bundle.
     *
     * NOTE on size: MAX_TURBO_LOOP_ROUNDS bounds a SINGLE _executeTurboLoop call,
     * NOT the cumulative member list - the same root can be Turbo'd repeatedly,
     * appending a rung each time, so this array grows with the owner's own
     * activity (bounded only by their seed capital / the $100 min-deposit). It is
     * therefore NOT hard-capped on-chain; a holder can only inflate their OWN
     * position (self-inflicted, no third-party grief), and the marketplace loops
     * skip burned members, so stale liquidated rungs never revert the sale.
     */
    function positionMembers(uint256 tokenId) external view returns (uint256[] memory members) {
        uint256 root = turboRoot(tokenId);
        uint256[] storage stored = _turboMembers[root];
        if (stored.length == 0) {
            members = new uint256[](1);
            members[0] = tokenId;
        } else {
            members = stored;
        }
    }

    // §Phase 2 Marketplace - position grouping. `turboRootOf[child] = root`
    // for every leveraged rung; `_turboMembers[root] = [root, ...rungs]` for a
    // position that has been leveraged at least once. Appended before __gap so
    // the upgradeable layout is preserved.
    mapping(uint256 childDepositId => uint256 rootDepositId) public turboRootOf;
    mapping(uint256 rootDepositId => uint256[] members) private _turboMembers;

    // __gap 47 -> 45: §Phase 2 `turboRootOf` + `_turboMembers` mappings.
    uint256[45] private __gap;
}

/**
 * @title AutoCompound (M3)
 * @notice Reinvests a deposit's accrued interest into a fresh deposit
 *         (Standard mode) OR uses it as collateral seed for a Turbo
 *         redeposit (Turbo mode). Triggered when the accrued interest
 *         crosses `BondContract.AUTO_COMPOUND_TRIGGER` (default 100 USDC).
 *
 * Trigger model: anyone can call `executeCompound(depositId)` once the
 * trigger threshold is met - the borrower's compoundMode (Off / Standard
 * / Turbo) decides which path runs. A keeper bot in the backend wakes
 * up periodically and fires eligible deposits.
 */
contract AutoCompound is IAutoCompound, GilderModule {
    // The compound trigger is single-sourced from BondContract
    // (AUTO_COMPOUND_TRIGGER) so the gate can never diverge from the
    // on-chain deposit floor; read live in executeCompound.

    IERC20 public asset;
    address public bondContract;
    address public treasury;
    address public turbo;
    mapping(uint256 depositId => CompoundMode mode) public compoundModeByDeposit;

    event CompoundExecuted(uint256 indexed sourceDepositId, uint256 indexed newDepositId, uint256 interestUsed, CompoundMode mode);

    error CompoundModeOff(uint256 depositId);
    error TriggerNotMet(uint256 accrued, uint256 trigger);
    error AutoCompoundNotInitialised();
    error CompoundOnInactiveDeposit(uint256 depositId, IGilderTypes.DepositState state);
    error NotDepositOwner(uint256 depositId, address caller);

    function initialize(
        address admin,
        address asset_,
        address bondContract_,
        address treasury_,
        address turbo_
    ) external {
        _initializeAccessControl(admin);
        if (
            asset_ == address(0) || bondContract_ == address(0) || treasury_ == address(0)
                || turbo_ == address(0)
        ) {
            revert ZeroAddress();
        }
        asset = IERC20(asset_);
        bondContract = bondContract_;
        treasury = treasury_;
        turbo = turbo_;
    }

    /**
     * Records the borrower's preferred compounding strategy. Bonded to
     * the BondContract via `BondContract.setCompoundMode` so the deposit
     * struct's compoundMode field stays the canonical source for the UI.
     */
    function setCompoundMode(uint256 depositId, CompoundMode mode) external whenNotPaused {
        // Only the deposit owner may set its compound mode (spec §I.6).
        // Authorize BEFORE any state write so a failed-auth tx leaves the
        // local mapping untouched.
        IBondContract.Deposit memory deposit = IBondContract(bondContract).getDeposit(depositId);
        if (msg.sender != deposit.owner) {
            revert NotDepositOwner(depositId, msg.sender);
        }
        compoundModeByDeposit[depositId] = mode;
        // Mirror to the deposit struct so indexers + the NFT renderer
        // pick up the change without a second contract read.
        IBondContractWithCompound(bondContract).setCompoundMode(depositId, uint8(mode));
        emit CompoundModeSet(depositId, mode);
    }

    /**
     * Permissionless trigger: anyone can call once the deposit has
     * crossed the AUTO_COMPOUND_TRIGGER. Refuses Off-mode deposits.
     */
    function executeCompound(uint256 depositId) external nonReentrant whenNotPaused returns (uint256 newDepositId) {
        if (bondContract == address(0) || treasury == address(0)) {
            revert AutoCompoundNotInitialised();
        }
        CompoundMode mode = compoundModeByDeposit[depositId];
        if (mode == CompoundMode.Off) {
            revert CompoundModeOff(depositId);
        }
        IBondContract.Deposit memory deposit = IBondContract(bondContract).getDeposit(depositId);
        // Only Active deposits may compound - guard against re-compounding a
        // Closed/Exited/Matured/Dormant/Abandoned position (which would
        // double-pay interest from Treasury). State cannot change between
        // here and the re-read after accrueInterest.
        if (deposit.state != IGilderTypes.DepositState.Active) {
            revert CompoundOnInactiveDeposit(depositId, deposit.state);
        }
        // §Code-Review C2 follow-up - SERVICE THE LOAN BEFORE SIZING THE
        // COMPOUND. This entry point is permissionless, so without it a third
        // party could repeatedly compound someone else's deposit, drain the
        // bond interest that the self-paying netting defence runs on, and let
        // the position drift into a bounty-paying liquidation months later.
        // Netting first means only the surplus above the loan's accrued
        // interest is ever compounded. Runs BEFORE the accrue/read below,
        // because netting reduces the figure this function then sizes from.
        IBondContractWithCompound(bondContract).netLoanInterest(depositId);
        // Fold any time-since-last-tx accrual into the on-chain counter
        // so we don't leave value on the table.
        IBondContract(bondContract).accrueInterest(depositId);
        deposit = IBondContract(bondContract).getDeposit(depositId);

        uint256 trigger = IBondContractWithCompound(bondContract).AUTO_COMPOUND_TRIGGER();
        if (deposit.accruedInterest < trigger) {
            revert TriggerNotMet(deposit.accruedInterest, trigger);
        }
        uint256 interestUsed = deposit.accruedInterest;
        address user = deposit.owner;

        // Drain the interest from Treasury into AutoCompound, then deduct
        // the matching amount from the deposit's accrued counter so the
        // user cannot double-claim at settle. NOTE: this whole function
        // is one atomic tx - if any step below reverts (e.g. the Turbo
        // leg can't satisfy LTV), this drain is rolled back too and the
        // interest is left intact to keep accruing (spec §17.6).
        ITreasury(treasury).paySettlement(depositId, address(this), interestUsed);
        IBondContractWithCompound(bondContract).consumeAccruedInterest(depositId, interestUsed);

        if (mode == CompoundMode.Standard) {
            // Standard: open a fresh deposit funded by the interest alone.
            // §V6.2 - productMode 0 = Standard economics.
            if (!asset.approve(bondContract, interestUsed)) {
                revert TransferFailed();
            }
            newDepositId = IBondContract(bondContract).openDepositFor(user, interestUsed, uint8(0));
        } else {
            // Turbo (§17.5): borrow against the SOURCE deposit's safe-
            // vault collateral, combine the proceeds with the consumed
            // interest, and mint a SINGLE leveraged deposit funded by
            // `interest + borrow`. This collapses the legacy two-step
            // (seed + leveraged inner) into one deposit, and the
            // combined principal - at the §17.2 trigger interest = $100
            // and turboBorrow = interest x 60% = $60 - is $160, which
            // automatically clears the §3.2 $100 MIN_DEPOSIT floor with
            // no contract bypass needed.
            //
            // Borrow sizing uses the same SafeVaultxmaxLTV model the rest
            // of the protocol uses: interest x 0.80 (SafeVault slice) x
            // 0.75 (max LTV) = 60% of interest, matching CYR's defaults
            // instead of a stale 56% magic number. Source's resulting LTV
            // is checked by Lending; if it would breach the 75% cap
            // (§17.5), `openLoanForBorrower` reverts and the whole compound
            // atomically unwinds (interest stays untouched, §17.6).
            uint256 TURBO_SAFE_BPS = 8000;
            uint256 TURBO_LTV_BPS = 7500;
            uint256 turboBorrow = (interestUsed * TURBO_SAFE_BPS * TURBO_LTV_BPS) / (10_000 * 10_000);
            ITurboExecutor(turbo).borrowForCompound(user, depositId, turboBorrow, address(this));
            uint256 combinedPrincipal = interestUsed + turboBorrow;
            if (!asset.approve(bondContract, combinedPrincipal)) {
                revert TransferFailed();
            }
            // §V6.2 - Turbo auto-compound produces a Turbo product (1).
            newDepositId = IBondContract(bondContract).openDepositFor(user, combinedPrincipal, uint8(1));
        }

        emit CompoundExecuted(depositId, newDepositId, interestUsed, mode);
    }

    uint256[44] private __gap;
}

interface IBondContractWithCompound {
    function setCompoundMode(uint256 depositId, uint8 mode) external;
    function consumeAccruedInterest(uint256 depositId, uint256 amount) external;
    // §Code-Review C2 follow-up - services the deposit's open loan out of its
    // bond interest. Called before sizing a compound so the loan is paid
    // ahead of the depositor's surplus.
    function netLoanInterest(uint256 depositId) external;
    // Public-constant getter on BondContract; read here so AutoCompound's
    // trigger tracks the single source of truth instead of a duplicated value.
    function AUTO_COMPOUND_TRIGGER() external view returns (uint256);
}

interface ITurboExecutor {
    function executeTurbo(uint256 depositId, uint256 borrowAmount) external returns (uint256 newDepositId);
    function executeTurboFor(address user, uint256 depositId, uint256 borrowAmount) external returns (uint256 newDepositId);
    function borrowForCompound(address user, uint256 sourceId, uint256 borrowAmount, address recipient) external;
}

/**
 * @title Governance
 * @notice Two-step parameter committal: propose() records the change with
 *         a timelock delay, execute() forwards the encoded calldata to
 *         the target module (which must grant Governance PARAMETER_ROLE).
 *
 * Audit-friendly because every parameter change is queued with a key
 * (e.g. keccak256("MAX_LTV_BPS")) plus the human-readable value so a
 * watchtower can preview the change between propose and execute.
 */
contract Governance is IGovernance, GilderModule {
    struct Proposal {
        address target;
        bytes32 key;
        uint256 value;
        bytes callData;
        uint64 readyAt;
        bool executed;
    }

    address public timelock;
    uint64 public delaySeconds;
    uint256 public nextProposalId;
    mapping(uint256 proposalId => Proposal proposal) private _proposals;

    error TimelockDelayActive(uint64 readyAt, uint64 currentTime);
    error UnknownProposal(uint256 proposalId);
    error AlreadyExecuted(uint256 proposalId);
    error ProposalCallFailed(uint256 proposalId);

    function initialize(address admin, address timelock_) external {
        _initializeAccessControl(admin);
        timelock = timelock_;
        delaySeconds = 1 days;
        nextProposalId = 1;
        emit TimelockSet(timelock_);
    }

    function setTimelock(address timelock_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (timelock_ == address(0)) {
            revert ZeroAddress();
        }
        timelock = timelock_;
        emit TimelockSet(timelock_);
    }

    function setDelaySeconds(uint64 seconds_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        delaySeconds = seconds_;
    }

    function proposeParameter(address target, bytes32 key, uint256 value, bytes calldata callData)
        external
        onlyRole(PARAMETER_ROLE)
        returns (uint256 proposalId)
    {
        if (target == address(0)) {
            revert ZeroAddress();
        }
        proposalId = nextProposalId++;
        _proposals[proposalId] = Proposal({
            target: target,
            key: key,
            value: value,
            callData: callData,
            readyAt: uint64(block.timestamp) + delaySeconds,
            executed: false
        });
        emit ParameterProposed(key, value, target);
    }

    function executeParameter(uint256 proposalId) external onlyRole(PARAMETER_ROLE) {
        Proposal storage proposal = _proposals[proposalId];
        if (proposal.target == address(0)) {
            revert UnknownProposal(proposalId);
        }
        if (proposal.executed) {
            revert AlreadyExecuted(proposalId);
        }
        if (block.timestamp < proposal.readyAt) {
            revert TimelockDelayActive(proposal.readyAt, uint64(block.timestamp));
        }
        proposal.executed = true;
        (bool ok, ) = proposal.target.call(proposal.callData);
        if (!ok) {
            revert ProposalCallFailed(proposalId);
        }
        emit ParameterCommitted(proposal.key, proposal.value, proposal.target, uint64(block.timestamp));
    }

    function proposalOf(uint256 proposalId) external view returns (Proposal memory) {
        return _proposals[proposalId];
    }

    uint256[44] private __gap;
}

contract GilderSystem is IGilderTypes {}
