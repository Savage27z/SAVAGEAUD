// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IAgentCredit} from "../interfaces/IAgentCredit.sol";
import {MathLib} from "../libraries/MathLib.sol";
import {ErrorLib} from "../libraries/ErrorLib.sol";

/// @title AgentCredit
/// @author Arcis Protocol
/// @notice Identity-aware lending module for autonomous AI agents
/// @dev Agents borrow USDC against raUSDC collateral. Collateral ratios are
///      determined by the agent's ERC-8004 reputation score. Higher reputation = lower ratio.
///
///      Interest accrues per-block. Liquidation is instant with no grace period.
///      Agents are machines; they do not need grace periods.
///
///      Phase 2 contract — depends on ArcisVault being deployed.
contract AgentCredit is IAgentCredit {
    using MathLib for uint256;

    // ══════════════════════════════════════════════════════════════
    //                         CONSTANTS
    // ══════════════════════════════════════════════════════════════

    /// @notice Liquidation threshold: health factor below 1.0 triggers liquidation
    uint256 public constant LIQUIDATION_THRESHOLD = 1e18; // 1.0 in WAD

    /// @notice Liquidation bonus for liquidators (5%)
    uint256 public constant LIQUIDATION_BONUS_BPS = 500;

    /// @notice Blocks per year (Base ~2s blocks)
    uint256 public constant BLOCKS_PER_YEAR = 15_768_000;

    /// @notice Maximum interest rate: 50% APR
    uint256 public constant MAX_RATE_BPS = 5_000;
    uint256 public constant BPS_DENOMINATOR = 10_000;

    // ══════════════════════════════════════════════════════════════
    //                         STORAGE
    // ══════════════════════════════════════════════════════════════

    address public owner;
    address public immutable vault;        // ArcisVault address
    address public immutable usdc;         // USDC token
    address public identityRegistry; // ERC-8004 registry (address(0) = no identity checks)

    uint256 public loanCount;
    mapping(uint256 => Loan) public loans;

    /// @notice Base interest rate for agents with no identity (in bps)
    uint256 public baseRateBps;

    /// @notice Optimal utilization target in bps (e.g. 8000 = 80%)
    uint256 public optimalUtilBps = 8_000;

    /// @notice Rate slope below optimal utilization (bps)
    uint256 public slope1Bps = 400;

    /// @notice Rate slope above optimal utilization — steep jump rate (bps)
    uint256 public slope2Bps = 7_500;

    /// @notice Total USDC currently lent out
    uint256 public totalBorrowed;

    /// @notice Total raUSDC shares locked as collateral
    uint256 public totalCollateral;

    /// @notice USDC available for lending
    uint256 public lendingPool;

    bool public paused;
    uint256 private _locked = 1;

    // ══════════════════════════════════════════════════════════════
    //                     REPUTATION TIERS
    // ══════════════════════════════════════════════════════════════

    /// @notice Collateral ratio by reputation tier (in bps)
    /// @dev Index 0 = no identity, 1-4 = reputation quartiles
    uint256[5] public collateralRatios;

    /// @notice Interest rate discount by tier (in bps, subtracted from base)
    uint256[5] public rateDiscounts;

    // ══════════════════════════════════════════════════════════════
    //                        MODIFIERS
    // ══════════════════════════════════════════════════════════════

    modifier nonReentrant() {
        if (_locked != 1) revert ErrorLib.Unauthorized(msg.sender);
        _locked = 2;
        _;
        _locked = 1;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert ErrorLib.Unauthorized(msg.sender);
        _;
    }

    // ══════════════════════════════════════════════════════════════
    //                       CONSTRUCTOR
    // ══════════════════════════════════════════════════════════════

    /// @param _vault ArcisVault address (raUSDC source)
    /// @param _usdc USDC token address
    /// @param _identityRegistry ERC-8004 identity registry (address(0) to disable)
    /// @param _baseRateBps Base annual interest rate in bps
    constructor(
        address _vault,
        address _usdc,
        address _identityRegistry,
        uint256 _baseRateBps
    ) {
        if (_vault == address(0) || _usdc == address(0)) revert ErrorLib.ZeroAddress();
        if (_baseRateBps > MAX_RATE_BPS) revert ErrorLib.InvalidAllocation();

        vault = _vault;
        usdc = _usdc;
        identityRegistry = _identityRegistry;
        baseRateBps = _baseRateBps;
        owner = msg.sender;

        // Default collateral ratios (in bps)
        // Tier 0: No identity = 200% collateral
        // Tier 1: Score 0-25 = 175%
        // Tier 2: Score 26-50 = 150%
        // Tier 3: Score 51-75 = 130%
        // Tier 4: Score 76-100 = 115%
        collateralRatios = [uint256(20_000), 17_500, 15_000, 13_000, 11_500];

        // Rate discounts per tier (subtracted from baseRateBps)
        rateDiscounts = [uint256(0), 100, 200, 350, 500];
    }

    // ══════════════════════════════════════════════════════════════
    //                    LENDING FUNCTIONS
    // ══════════════════════════════════════════════════════════════

    /// @inheritdoc IAgentCredit
    function borrow(
        uint256 borrowAmount,
        uint256 collateralShares
    ) external nonReentrant returns (uint256 loanId) {
        if (borrowAmount == 0) revert ErrorLib.ZeroAmount();
        if (collateralShares == 0) revert ErrorLib.ZeroShares();
        if (borrowAmount > lendingPool) {
            revert ErrorLib.InsufficientLiquidity(borrowAmount, lendingPool);
        }

        // Get required collateral ratio based on agent reputation
        uint256 ratio = getCollateralRatio(msg.sender);
        uint256 interestRate = _getInterestRate(msg.sender);

        // Calculate collateral value (raUSDC shares -> USDC value)
        uint256 collateralValue = _getCollateralValue(collateralShares);
        uint256 requiredCollateral = MathLib.bps(borrowAmount, ratio);

        if (collateralValue < requiredCollateral) {
            revert ErrorLib.InsufficientCollateral(requiredCollateral, collateralValue);
        }

        // Create loan
        loanId = ++loanCount;
        loans[loanId] = Loan({
            id: loanId,
            agent: msg.sender,
            borrowedAmount: borrowAmount,
            collateralShares: collateralShares,
            interestRateBps: interestRate,
            accruedInterest: 0,
            startBlock: block.number,
            lastAccrualBlock: block.number,
            repaid: false
        });

        // Transfer collateral (raUSDC) from agent to this contract
        _safeTransferFrom(vault, msg.sender, address(this), collateralShares);

        // Transfer USDC to agent
        totalBorrowed += borrowAmount;
        totalCollateral += collateralShares;
        lendingPool -= borrowAmount;
        _safeTransfer(usdc, msg.sender, borrowAmount);

        emit LoanCreated(loanId, msg.sender, borrowAmount, collateralShares);
    }

    /// @inheritdoc IAgentCredit
    function repay(uint256 loanId) external nonReentrant {
        Loan storage loan = loans[loanId];
        if (loan.agent == address(0)) revert ErrorLib.LoanNotFound(loanId);
        if (loan.repaid) revert ErrorLib.LoanAlreadyRepaid(loanId);
        if (msg.sender != loan.agent) revert ErrorLib.NotLoanOwner(loanId, msg.sender);

        // Accrue interest
        _accrueInterest(loanId);

        uint256 amountOwed = loan.borrowedAmount + loan.accruedInterest;

        // Transfer USDC repayment from agent
        _safeTransferFrom(usdc, msg.sender, address(this), amountOwed);

        // Return collateral (raUSDC)
        _safeTransfer(vault, msg.sender, loan.collateralShares);

        // Update state
        loan.repaid = true;
        totalBorrowed -= loan.borrowedAmount;
        totalCollateral -= loan.collateralShares;
        lendingPool += amountOwed;

        emit LoanRepaid(loanId, msg.sender, amountOwed);
    }

    /// @inheritdoc IAgentCredit
    function liquidate(uint256 loanId) external nonReentrant {
        Loan storage loan = loans[loanId];
        if (loan.agent == address(0)) revert ErrorLib.LoanNotFound(loanId);
        if (loan.repaid) revert ErrorLib.LoanAlreadyRepaid(loanId);

        _accrueInterest(loanId);

        (bool healthy,) = isHealthy(loanId);
        if (healthy) revert ErrorLib.LoanHealthy(loanId);

        uint256 amountOwed = loan.borrowedAmount + loan.accruedInterest;

        // Liquidator pays the debt
        _safeTransferFrom(usdc, msg.sender, address(this), amountOwed);

        // Liquidator receives collateral + bonus
        uint256 collateralToLiquidator = loan.collateralShares;
        _safeTransfer(vault, msg.sender, collateralToLiquidator);

        // Update state
        loan.repaid = true;
        totalBorrowed -= loan.borrowedAmount;
        totalCollateral -= loan.collateralShares;
        lendingPool += amountOwed;

        emit LoanLiquidated(loanId, loan.agent, msg.sender);
    }

    // ══════════════════════════════════════════════════════════════
    //                     VIEW FUNCTIONS
    // ══════════════════════════════════════════════════════════════

    /// @inheritdoc IAgentCredit
    function getCollateralRatio(address agent) public view returns (uint256 ratio) {
        uint256 tier = _getReputationTier(agent);
        ratio = collateralRatios[tier];
    }

    /// @inheritdoc IAgentCredit
    function isHealthy(uint256 loanId) public view returns (bool healthy, uint256 healthFactor) {
        Loan storage loan = loans[loanId];
        if (loan.repaid) return (true, type(uint256).max);

        uint256 collateralValue = _getCollateralValue(loan.collateralShares);
        uint256 owedAmount = loan.borrowedAmount + loan.accruedInterest + _pendingInterest(loanId);

        if (owedAmount == 0) return (true, type(uint256).max);

        // Health factor = collateralValue / owedAmount (in WAD)
        healthFactor = MathLib.mulDiv(collateralValue, 1e18, owedAmount);
        healthy = healthFactor >= LIQUIDATION_THRESHOLD;
    }

    /// @notice Get current total owed on a loan
    function totalOwed(uint256 loanId) external view returns (uint256) {
        Loan storage loan = loans[loanId];
        return loan.borrowedAmount + loan.accruedInterest + _pendingInterest(loanId);
    }

    // ══════════════════════════════════════════════════════════════
    //                         ADMIN
    // ══════════════════════════════════════════════════════════════

    /// @notice Fund the lending pool with USDC
    function fundPool(uint256 amount) external {
        _safeTransferFrom(usdc, msg.sender, address(this), amount);
        lendingPool += amount;
        emit PoolFunded(msg.sender, amount);
    }

    /// @notice Update collateral ratios per tier
    function setCollateralRatios(uint256[5] calldata ratios) external onlyOwner {
        collateralRatios = ratios;
        emit CollateralRatiosUpdated(ratios);
    }

    /// @notice Update rate discounts per tier
    function setRateDiscounts(uint256[5] calldata discounts) external onlyOwner {
        rateDiscounts = discounts;
        emit RateDiscountsUpdated(discounts);
    }

    function setIdentityRegistry(address registry) external onlyOwner {
        address old = identityRegistry;
        identityRegistry = registry;
        emit IdentityRegistryUpdated(old, registry);
    }

    /// @notice Update the base interest rate
    /// @param newRateBps New base rate in bps (max 3000 = 30%)
    function setBaseRate(uint256 newRateBps) external onlyOwner {
        if (newRateBps > MAX_RATE_BPS) revert ErrorLib.InvalidAllocation();
        uint256 old = baseRateBps;
        baseRateBps = newRateBps;
        emit BaseRateUpdated(old, newRateBps);
    }

    /// @notice Update utilization rate curve parameters
    function setRateCurve(uint256 _optimalUtilBps, uint256 _slope1Bps, uint256 _slope2Bps) external onlyOwner {
        if (_optimalUtilBps > BPS_DENOMINATOR) revert ErrorLib.InvalidAllocation();
        optimalUtilBps = _optimalUtilBps;
        slope1Bps = _slope1Bps;
        slope2Bps = _slope2Bps;
    }

    /// @notice View the current effective rate for an agent
    function getEffectiveRate(address agent) external view returns (uint256) {
        return _getInterestRate(agent);
    }

    function pause() external onlyOwner {
        paused = true;
        emit Paused(msg.sender);
    }

    function unpause() external onlyOwner {
        paused = false;
        emit Unpaused(msg.sender);
    }

    /// @notice Transfer ownership to a new address (for multisig migration)
    /// @param newOwner Address of the new owner
    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ErrorLib.ZeroAddress();
        address old = owner;
        owner = newOwner;
        emit OwnershipTransferred(old, newOwner);
    }

    // ══════════════════════════════════════════════════════════════
    //                    INTERNAL FUNCTIONS
    // ══════════════════════════════════════════════════════════════

    /// @dev Get reputation tier (0-4) for an agent
    function _getReputationTier(address agent) internal view returns (uint256) {
        if (identityRegistry == address(0)) return 0;

        // Call ERC-8004 registry to get reputation score
        // Interface: getScore(address) returns (uint256 score) where score is 0-100
        (bool success, bytes memory data) = identityRegistry.staticcall(
            abi.encodeWithSignature("getScore(address)", agent)
        );

        if (!success || data.length < 32) return 0;

        uint256 score = abi.decode(data, (uint256));

        if (score >= 76) return 4;
        if (score >= 51) return 3;
        if (score >= 26) return 2;
        if (score >= 1) return 1;
        return 0;
    }

    /// @dev Get interest rate for an agent based on reputation
    function _getInterestRate(address agent) internal view returns (uint256) {
        // Calculate utilization-based rate
        uint256 total = lendingPool + totalBorrowed;
        uint256 utilRate = baseRateBps;

        if (total > 0) {
            uint256 utilBps = (totalBorrowed * BPS_DENOMINATOR) / total;

            if (utilBps <= optimalUtilBps) {
                // Below optimal: linear slope
                utilRate = baseRateBps + (utilBps * slope1Bps) / optimalUtilBps;
            } else {
                // Above optimal: base + full slope1 + steep slope2
                uint256 excessUtil = utilBps - optimalUtilBps;
                uint256 maxExcess = BPS_DENOMINATOR - optimalUtilBps;
                utilRate = baseRateBps + slope1Bps + (excessUtil * slope2Bps) / maxExcess;
            }
        }

        // Apply tier discount
        uint256 tier = _getReputationTier(agent);
        uint256 discount = rateDiscounts[tier];
        if (discount >= utilRate) return 0;
        return utilRate - discount;
    }

    /// @dev Get USDC value of raUSDC shares
    function _getCollateralValue(uint256 shares) internal view returns (uint256) {
        // Call vault.balance() equivalent: previewWithdraw
        (bool success, bytes memory data) = vault.staticcall(
            abi.encodeWithSignature("previewWithdraw(uint256)", shares)
        );
        if (!success || data.length < 32) return 0;
        return abi.decode(data, (uint256));
    }

    /// @dev Accrue interest on a loan up to current block
    function _accrueInterest(uint256 loanId) internal {
        Loan storage loan = loans[loanId];
        uint256 pending = _pendingInterest(loanId);
        loan.accruedInterest += pending;
        loan.lastAccrualBlock = block.number;
    }

    /// @dev Calculate pending (unaccrued) interest
    function _pendingInterest(uint256 loanId) internal view returns (uint256) {
        Loan storage loan = loans[loanId];
        if (loan.repaid) return 0;

        uint256 blocksDelta = block.number - loan.lastAccrualBlock;
        if (blocksDelta == 0) return 0;

        // interest = principal * rate * blocks / (blocksPerYear * 10000)
        return MathLib.mulDiv(
            loan.borrowedAmount * loan.interestRateBps,
            blocksDelta,
            BLOCKS_PER_YEAR * 10_000
        );
    }

    // ══════════════════════════════════════════════════════════════
    //                    SAFE TOKEN HELPERS
    // ══════════════════════════════════════════════════════════════

    function _safeTransfer(address token, address to, uint256 amount) internal {
        (bool success, bytes memory data) = token.call(
            abi.encodeWithSelector(0xa9059cbb, to, amount)
        );
        if (!success || (data.length > 0 && !abi.decode(data, (bool)))) revert ErrorLib.TransferFailed();
    }

    function _safeTransferFrom(address token, address from, address to, uint256 amount) internal {
        (bool success, bytes memory data) = token.call(
            abi.encodeWithSelector(0x23b872dd, from, to, amount)
        );
        if (!success || (data.length > 0 && !abi.decode(data, (bool)))) revert ErrorLib.TransferFailed();
    }
}
