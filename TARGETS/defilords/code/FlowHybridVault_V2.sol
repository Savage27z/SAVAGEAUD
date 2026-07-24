// SPDX-License-Identifier: MIT

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC4626} from "../../../lib/openzeppelin-contracts/contracts/token/ERC20/extensions/ERC4626.sol";
import {ERC20} from "../../../lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "../../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "../../../lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "../../../lib/openzeppelin-contracts/contracts/access/Ownable.sol";
import {Pausable} from "../../../lib/openzeppelin-contracts/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "../../../lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";

// ── Adapter interface ─────────────────────────────────────────────────────────

interface IFlowHybridAdapter {
    /// @dev Transfer `amount` USDC from caller, open/add to LP position.
    function deposit(uint256 amount) external returns (uint256);

    /// @dev Close the ENTIRE LP position and send all USDC to the vault.
    function withdrawAll() external returns (uint256 received);

    /// @dev Collect accrued LP fees, swap WETH→USDC, transfer realized profit to vault.
    ///      Returns only the realized profit transferred — NOT a totalAssets delta.
    function harvest() external returns (uint256 profit);

    /// @dev Rebalance the LP position centred at `centerTick`.
    function rebalanceToCenter(int24 centerTick) external;

    /// @dev Close position and return all funds. Called on emergency.
    function emergencyExit() external;

    /// @dev Live LP value: liquidity × sqrtPrice math, no stale cache.
    function getTVL() external view returns (uint256);
}

/**
 * @title  FlowHybridVault
 * @notice ERC-4626 USDC vault with three selectable fee modes:
 *         - Growth   (100% auto-compound into share price)
 *         - Balanced (50% compound / 50% claimable USDC)
 *         - Income   (10% compound / 90% claimable USDC)
 *
 * Reward accounting uses the MasterChef/Aave reward-index model:
 *   - `accRewardPerShare` accumulates realized USDC per share × PRECISION
 *   - `rewardDebt[user]` tracks the index at last settlement
 *   - `claimable[user]` holds settled but unclaimed USDC
 *   - `realizedYieldReserve` is excluded from totalAssets() to prevent double-counting
 *
 * All settlement flows through a single `_settle(address)` function.
 * Reserve solvency is asserted after every harvest.
 *
 * Architecture: new vault derived from FlowVaultBalanced.
 *   - No modifications to the live FlowVaultBalanced or FlowAdapterBalanced contracts.
 *   - V1 adapter = verbatim copy of FlowAdapterBalanced renamed FlowHybridAdapter.
 *
 * See: docs/dlflow-hybrid-accounting-spec.md
 */
contract FlowHybridVault is ERC4626, Ownable, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ── Fee mode ──────────────────────────────────────────────────────────────

    enum FeeMode {
        Growth,
        Balanced,
        Income
    }

    // ── Constants ─────────────────────────────────────────────────────────────

    uint256 public constant MAX_PERFORMANCE_FEE = 2_000; // 20% hard cap (bps)
    uint256 public constant MAX_RESERVE_RATIO = 5_000; // 50% hard cap (bps)
    /// @dev [AUDIT-H1] Minimum reserve ratio — prevents keeper draining all USDC into LP.
    ///      5% ensures a withdrawal buffer always exists without a full position close.
    uint256 public constant MIN_RESERVE_RATIO = 500; // 5% floor (bps)
    uint256 public constant BPS = 10_000;
    uint256 public constant PRECISION = 1e12; // fixed-point scale for accRewardPerShare
    uint256 public constant MIN_CLAIM_AMOUNT = 10_000; // 0.01 USDC (6-dec)
    uint256 public constant MIN_HARVEST_PROFIT = 100_000; // 0.10 USDC (6-dec)
    uint256 public constant HARVEST_COOLDOWN = 15 minutes;

    // ── Inherited state (identical to FlowVaultBalanced) ──────────────────────

    IFlowHybridAdapter public adapter;
    address public keeper;
    address public feeRecipient;

    uint256 public performanceFee; // bps
    uint256 public reserveRatio; // bps of idle kept liquid
    uint256 public depositCap; // 0 = uncapped
    uint256 public minDeposit;

    // ── Reward accounting (new) ───────────────────────────────────────────────

    /// @notice Cumulative realized USDC per share × PRECISION. Monotonically non-decreasing.
    uint256 public accRewardPerShare;

    /// @notice Per-user debt checkpoint. `rewardDebt[u] = balanceOf(u) * accRewardPerShare / PRECISION` at last settlement.
    mapping(address => uint256) public rewardDebt;

    /// @notice Settled but unclaimed USDC (6-dec) per user.
    mapping(address => uint256) public claimable;

    /// @notice Total USDC reserved for pending + claimable claims. Excluded from totalAssets().
    uint256 public realizedYieldReserve;

    // ── Mode ──────────────────────────────────────────────────────────────────

    /// @notice Active fee split mode. Default = Growth (100% compound). Set to Balanced after deploy.
    FeeMode public vaultFeeMode;

    // ── Harvest timing ────────────────────────────────────────────────────────

    /// @notice Timestamp of last successful harvest. 0 before first harvest.
    uint256 public lastHarvestAt;

    // ── Events ────────────────────────────────────────────────────────────────

    event Deployed(uint256 amount);
    event Harvested(uint256 realizedProfit, uint256 feeMinted, uint256 compoundPortion, uint256 realizedPortion);
    event Rebalanced(int24 centerTick);
    event EmergencyExitTriggered();
    event RewardAccrued(uint256 realizedPortion, uint256 newAccRewardPerShare);
    event Claimed(address indexed user, uint256 amount);
    event FeeModeChanged(FeeMode oldMode, FeeMode newMode);
    event KeeperUpdated(address indexed keeper);
    event AdapterUpdated(address indexed adapter);
    event PerformanceFeeUpdated(uint256 bps);
    event ReserveRatioUpdated(uint256 bps);
    event FeeRecipientUpdated(address indexed recipient);
    event DepositCapUpdated(uint256 cap);
    /// @notice [AUDIT-ST-C3] Emitted when owner reduces realizedYieldReserve to recover from ReserveInsolvent.
    event YieldReserveDrained(uint256 amount, uint256 newReserve);

    // ── Errors ────────────────────────────────────────────────────────────────

    error NotKeeper();
    error ZeroAddress();
    error BelowMinDeposit();
    error DepositCapExceeded();
    error FeeTooHigh();
    error RatioTooHigh();
    error RatioTooLow(); // [AUDIT-H1] reserveRatio must be >= MIN_RESERVE_RATIO
    error AdapterNotSet();
    error ClaimBelowMinimum();
    error ReserveInsufficient(uint256 reserve, uint256 requested);
    error ReserveInsolvent(uint256 reserve, uint256 vaultBalance); // [AUDIT-C2] replaces assert()
    error HarvestBelowMinimum();
    error HarvestCooldown();

    // ── Modifiers ─────────────────────────────────────────────────────────────

    modifier onlyKeeper() {
        if (msg.sender != keeper && msg.sender != owner()) revert NotKeeper();
        _;
    }

    // ── Constructor ───────────────────────────────────────────────────────────

    constructor(
        IERC20 _asset,
        string memory _name,
        string memory _symbol,
        address _keeper,
        address _feeRecipient,
        uint256 _performanceFee,
        uint256 _reserveRatio
    ) ERC4626(_asset) ERC20(_name, _symbol) Ownable(msg.sender) {
        if (_keeper == address(0) || _feeRecipient == address(0)) revert ZeroAddress();
        if (_performanceFee > MAX_PERFORMANCE_FEE) revert FeeTooHigh();
        if (_reserveRatio > MAX_RESERVE_RATIO) revert RatioTooHigh();
        // [AUDIT-C3] Enforce floor at construction — setReserveRatio() already enforces this,
        // but the constructor bypassed it. A deployment with _reserveRatio=0 would allow
        // deployIdle() to sweep the entire vault balance into the LP with no withdrawal buffer.
        if (_reserveRatio < MIN_RESERVE_RATIO) revert RatioTooLow();

        keeper = _keeper;
        feeRecipient = _feeRecipient;
        performanceFee = _performanceFee;
        reserveRatio = _reserveRatio;
        // vaultFeeMode defaults to Growth (enum index 0)
    }

    // ── ERC-4626 ──────────────────────────────────────────────────────────────

    /**
     * @notice Vault balance available to shareholders, EXCLUDING the realized yield reserve.
     *
     * The realizedYieldReserve is owed to claimants. Including it would inflate PPS and
     * cause double-counting: users redeeming shares would receive funds already earmarked
     * for claimants.
     *
     * totalAssets = max(0, vaultBalance - realizedYieldReserve) + adapter.getTVL()
     */
    function totalAssets() public view override returns (uint256) {
        uint256 bal = IERC20(asset()).balanceOf(address(this));
        uint256 available = bal >= realizedYieldReserve ? bal - realizedYieldReserve : 0;
        if (address(adapter) == address(0)) return available;
        return available + adapter.getTVL();
    }

    function deposit(uint256 assets, address receiver)
        public
        override
        nonReentrant
        whenNotPaused
        returns (uint256 shares)
    {
        if (assets < minDeposit) revert BelowMinDeposit();
        if (depositCap > 0 && totalAssets() + assets > depositCap) revert DepositCapExceeded();
        shares = super.deposit(assets, receiver);
    }

    function mint(uint256 shares, address receiver)
        public
        override
        nonReentrant
        whenNotPaused
        returns (uint256 assets)
    {
        assets = previewMint(shares);
        if (assets < minDeposit) revert BelowMinDeposit();
        if (depositCap > 0 && totalAssets() + assets > depositCap) revert DepositCapExceeded();
        assets = super.mint(shares, receiver);
    }

    function withdraw(uint256 assets, address receiver, address _owner)
        public
        override
        nonReentrant
        whenNotPaused
        returns (uint256 shares)
    {
        _ensureIdle(assets);
        shares = super.withdraw(assets, receiver, _owner);
    }

    function redeem(uint256 shares, address receiver, address _owner)
        public
        override
        nonReentrant
        whenNotPaused
        returns (uint256 assets)
    {
        _ensureIdle(previewRedeem(shares));
        assets = super.redeem(shares, receiver, _owner);
    }

    // ── Keeper operations ─────────────────────────────────────────────────────

    /**
     * @notice Deploy idle USDC above the reserve into the adapter.
     *
     * @dev    [AUDIT-ST-C3] The deployable amount is computed from the AVAILABLE balance,
     *         which excludes realizedYieldReserve. The old implementation used raw balanceOf(),
     *         causing deployIdle() to progressively deplete the USDC earmarked for claimants
     *         into the LP. Over time this caused realizedYieldReserve > vaultBalance → harvest()
     *         reverts with ReserveInsolvent.
     *
     *         Fix: available = max(0, balanceOf - realizedYieldReserve).
     *         The reserve ratio then applies to available, leaving the yield reserve
     *         physically untouched in the vault. deployIdle will self-skip when
     *         available ≤ reserve (e.g., if the entire available balance is below reserve).
     */
    function deployIdle() external onlyKeeper whenNotPaused {
        if (address(adapter) == address(0)) revert AdapterNotSet();
        uint256 balance = IERC20(asset()).balanceOf(address(this));
        // Exclude earmarked yield reserve — cannot be deployed into LP
        uint256 available = balance >= realizedYieldReserve ? balance - realizedYieldReserve : 0;
        uint256 reserve = (available * reserveRatio) / BPS;
        if (available <= reserve) return;
        uint256 toDeploy = available - reserve;
        IERC20(asset()).forceApprove(address(adapter), toDeploy);
        adapter.deposit(toDeploy);
        // [AUDIT-H3] Revoke residual allowance after deposit. If adapter is ever replaced
        // via setAdapter(), the old adapter must NOT retain a live spending allowance.
        IERC20(asset()).forceApprove(address(adapter), 0);
        emit Deployed(toDeploy);
    }

    /**
     * @notice Harvest LP fees and split per vaultFeeMode.
     *
     * Flow:
     *   1. Cooldown check (skipped on first harvest when lastHarvestAt == 0)
     *   2. adapter.harvest() — adapter collects fees, swaps WETH→USDC, transfers profit here
     *   3. Dust guard: profit must be ≥ MIN_HARVEST_PROFIT
     *   4. Compute protocol fee shares (convertToShares against depositor-only supply)
     *   5. Mode split: compound portion raises PPS; realized portion → realizedYieldReserve
     *   6. accRewardPerShare updated for realized portion (BEFORE fee shares are minted)
     *   7. Mint fee shares AFTER accRPS is final — _settle(feeRecipient) sees correct index
     *   8. lastHarvestAt updated
     *   9. Reserve solvency check
     *
     * [AUDIT-C2] Order matters: fee shares must be minted AFTER accRewardPerShare is updated.
     * Minting before the update causes _settle(feeRecipient) to use the old index, then the
     * new index is computed over a totalSupply that already includes the fee shares → feeRecipient
     * accrues phantom rewards on shares it received in the same tx ("double-dipping").
     * Correct order: compute accRPS over depositor-only supply → mint → _settle sees new accRPS
     * → rewardDebt[feeRecipient] == feeMinted × newAccRPS / PREC → pendingRewards == 0 ✓
     */
    function harvest() external onlyKeeper nonReentrant whenNotPaused {
        if (address(adapter) == address(0)) revert AdapterNotSet();

        // Cooldown: skip on first harvest (lastHarvestAt == 0)
        if (lastHarvestAt != 0 && block.timestamp < lastHarvestAt + HARVEST_COOLDOWN) {
            revert HarvestCooldown();
        }

        uint256 profit = adapter.harvest();
        if (profit < MIN_HARVEST_PROFIT) revert HarvestBelowMinimum();

        // ── Step 1: Compute protocol fee (no state changes yet) ───────────────
        // convertToShares() is called here, BEFORE fee shares are minted, so it
        // reflects the pre-harvest depositor-only supply and pre-harvest PPS.
        uint256 feeMinted;
        uint256 netUserFees = profit;
        if (performanceFee > 0 && feeRecipient != address(0)) {
            uint256 feeAssets = (profit * performanceFee) / BPS;
            feeMinted = convertToShares(feeAssets);
            netUserFees = profit - feeAssets;
        }

        // ── Step 2: Mode split ────────────────────────────────────────────────
        (uint16 compoundBps,) = modeConfig(vaultFeeMode);
        uint256 compoundPortion = (netUserFees * compoundBps) / BPS;
        uint256 realizedPortion = netUserFees - compoundPortion; // avoids rounding loss

        // ── Step 3: Update accRewardPerShare (BEFORE minting fee shares) ─────
        // totalSupply() here = depositor-only supply (no fee shares yet).
        // When _mint(feeRecipient) triggers _update → _settle(feeRecipient) below,
        // rewardDebt[feeRecipient] will be set to feeMinted × newAccRPS / PREC.
        // pendingRewards(feeRecipient) = feeMinted × newAccRPS / PREC - that debt = 0 ✓
        if (realizedPortion > 0) {
            realizedYieldReserve += realizedPortion;
            uint256 supply = totalSupply(); // depositor-only supply
            if (supply > 0) {
                accRewardPerShare += (realizedPortion * PRECISION) / supply;
            }
            emit RewardAccrued(realizedPortion, accRewardPerShare);
        }

        // ── Step 4: Mint fee shares (AFTER accRPS is final) ──────────────────
        // _update → _settle(feeRecipient) sees the new accRPS.
        // feeRecipient's rewardDebt is set to feeMinted × newAccRPS / PREC.
        // No phantom rewards accumulate on this harvest. [AUDIT-C2]
        if (feeMinted > 0) _mint(feeRecipient, feeMinted);

        lastHarvestAt = block.timestamp;

        // ── Step 5: Solvency invariant ────────────────────────────────────────
        // [AUDIT-C2] revert instead of assert() — assert triggers Panic(0x01) consuming
        // all gas and making the vault permanently unrecoverable. A revert allows the
        // owner to call drainYieldReserve() and then retry.
        uint256 vaultBalance = IERC20(asset()).balanceOf(address(this));
        if (realizedYieldReserve > vaultBalance) {
            revert ReserveInsolvent(realizedYieldReserve, vaultBalance);
        }

        emit Harvested(profit, feeMinted, compoundPortion, realizedPortion);
    }

    /**
     * @notice Rebalance LP position to a flow-derived centre tick.
     */
    function rebalance(int24 centerTick) external onlyKeeper whenNotPaused {
        if (address(adapter) == address(0)) revert AdapterNotSet();
        adapter.rebalanceToCenter(centerTick);
        emit Rebalanced(centerTick);
    }

    /**
     * @notice Claim accrued USDC rewards (V1: USDC only).
     *
     * Settles any pending rewards, then transfers claimable USDC to caller.
     * Minimum claim: MIN_CLAIM_AMOUNT (0.01 USDC) to avoid dust transfers.
     */
    function claim() external nonReentrant whenNotPaused {
        _settle(msg.sender);
        uint256 amount = claimable[msg.sender];
        if (amount < MIN_CLAIM_AMOUNT) revert ClaimBelowMinimum();
        if (realizedYieldReserve < amount) revert ReserveInsufficient(realizedYieldReserve, amount);

        claimable[msg.sender] = 0;
        realizedYieldReserve -= amount;

        IERC20(asset()).safeTransfer(msg.sender, amount);
        emit Claimed(msg.sender, amount);
    }

    // ── Emergency ─────────────────────────────────────────────────────────────

    /// @notice Close adapter position immediately; vault paused until owner unpauses.
    function emergencyExit() external onlyOwner {
        _pause();
        if (address(adapter) != address(0)) adapter.emergencyExit();
        emit EmergencyExitTriggered();
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    // ── Admin ─────────────────────────────────────────────────────────────────

    function setAdapter(address _adapter) external onlyOwner {
        if (_adapter == address(0)) revert ZeroAddress();
        adapter = IFlowHybridAdapter(_adapter);
        emit AdapterUpdated(_adapter);
    }

    /**
     * @notice Safe adapter migration: closes the current LP position before switching.
     *
     * @dev    [AUDIT-ST-C1] setAdapter() switches the adapter immediately without closing
     *         the old LP position. This causes totalAssets() to drop by the LP value the
     *         moment the new adapter (with getTVL()=0) is set, crashing the share price.
     *
     *         migrateAdapter() solves this:
     *           1. withdrawAll() — close old position, return USDC to vault
     *           2. Revoke old adapter allowance (defence-in-depth)
     *           3. Switch adapter pointer to the new address
     *
     *         The withdrawAll() call is best-effort — if the old adapter is already empty
     *         (e.g., after emergencyExit()), the catch block skips silently and migration
     *         proceeds. This is the correct behaviour for post-emergency recovery.
     *
     *         For routine planned migrations (e.g., adapter upgrade):
     *           1. pause()            — prevent new deposits during migration
     *           2. migrateAdapter()   — close old LP, switch adapter
     *           3. unpause()          — users can withdraw; vault is all-idle
     *           4. deployIdle()       — keeper re-deploys idle into new adapter
     *
     *         Do NOT use setAdapter() while the old adapter holds an open position.
     */
    function migrateAdapter(address _newAdapter) external onlyOwner {
        if (_newAdapter == address(0)) revert ZeroAddress();

        // Step 1: close old position (best-effort — skip if already empty or adapter not set)
        if (address(adapter) != address(0)) {
            try adapter.withdrawAll() returns (uint256) {}
            catch {}
            // Step 2: revoke residual USDC allowance on old adapter
            IERC20(asset()).forceApprove(address(adapter), 0);
        }

        // Step 3: switch adapter pointer
        adapter = IFlowHybridAdapter(_newAdapter);
        emit AdapterUpdated(_newAdapter);
    }

    /**
     * @notice Emergency recovery: reduce realizedYieldReserve to unblock a ReserveInsolvent state.
     *
     * @dev    [AUDIT-ST-C3] When deployIdle() depletes vault idle below realizedYieldReserve
     *         (the old ST-C3 bug), harvest() reverts permanently with ReserveInsolvent. The fix
     *         to deployIdle() prevents this from recurring, but this function is retained as an
     *         owner-only last resort for vaults deployed before the fix.
     *
     *         Semantics:
     *           - Reduces realizedYieldReserve by `amount` (clamped to avoid underflow).
     *           - Does NOT modify any user's claimable[] mapping — their entitlement is preserved.
     *           - Users may temporarily be unable to claim until the next harvest replenishes
     *             the reserve. The owner is expected to call drainYieldReserve() only to the
     *             minimum amount that unblocks harvest(), not to zero out the entire reserve.
     *           - Subsequent harvests will rebuild realizedYieldReserve via the normal path.
     *
     *         Recommended usage (ReserveInsolvent recovery):
     *           uint256 shortfall = realizedYieldReserve - USDC.balanceOf(vault);
     *           vault.drainYieldReserve(shortfall + 1);  // drain to exactly solvent + 1 wei
     *           vault.harvest();                          // should now succeed
     */
    function drainYieldReserve(uint256 amount) external onlyOwner {
        if (amount > realizedYieldReserve) amount = realizedYieldReserve;
        realizedYieldReserve -= amount;
        emit YieldReserveDrained(amount, realizedYieldReserve);
    }

    function setKeeper(address _keeper) external onlyOwner {
        if (_keeper == address(0)) revert ZeroAddress();
        keeper = _keeper;
        emit KeeperUpdated(_keeper);
    }

    function setFeeRecipient(address _recipient) external onlyOwner {
        if (_recipient == address(0)) revert ZeroAddress();
        feeRecipient = _recipient;
        emit FeeRecipientUpdated(_recipient);
    }

    function setPerformanceFee(uint256 bps) external onlyOwner {
        if (bps > MAX_PERFORMANCE_FEE) revert FeeTooHigh();
        performanceFee = bps;
        emit PerformanceFeeUpdated(bps);
    }

    function setReserveRatio(uint256 bps) external onlyOwner {
        // [AUDIT-H1] Enforce both bounds: floor prevents full-LP drain, ceiling prevents hoarding.
        if (bps > MAX_RESERVE_RATIO) revert RatioTooHigh();
        if (bps < MIN_RESERVE_RATIO) revert RatioTooLow();
        reserveRatio = bps;
        emit ReserveRatioUpdated(bps);
    }

    function setDepositCap(uint256 cap) external onlyOwner {
        depositCap = cap;
        emit DepositCapUpdated(cap);
    }

    function setMinDeposit(uint256 min) external onlyOwner {
        minDeposit = min;
    }

    /**
     * @notice Change the active fee mode.
     * @dev    Vault-level only in V1. Per-user modes are a V2 roadmap item.
     */
    function setFeeMode(FeeMode mode) external onlyOwner {
        FeeMode old = vaultFeeMode;
        vaultFeeMode = mode;
        emit FeeModeChanged(old, mode);
    }

    // ── View helpers ──────────────────────────────────────────────────────────

    /**
     * @notice Returns (compoundBps, realizedBps) for the given fee mode.
     *         compoundBps + realizedBps == BPS always.
     *
     * Income uses 10% compound (not 0%) to keep LP position health intact.
     */
    function modeConfig(FeeMode mode) public pure returns (uint16 compoundBps, uint16 realizedBps) {
        if (mode == FeeMode.Growth) return (10_000, 0);
        if (mode == FeeMode.Balanced) return (5_000, 5_000);
        if (mode == FeeMode.Income) return (1_000, 9_000);
        revert("unreachable");
    }

    /**
     * @notice Unsettled rewards for `user` (not yet in claimable).
     *         Read-only — does not update state.
     */
    function pendingRewards(address user) public view returns (uint256) {
        uint256 accrued = (balanceOf(user) * accRewardPerShare) / PRECISION;
        return accrued > rewardDebt[user] ? accrued - rewardDebt[user] : 0;
    }

    /**
     * @notice Total USDC the user can claim: settled + unsettled.
     */
    function totalClaimable(address user) external view returns (uint256) {
        return pendingRewards(user) + claimable[user];
    }

    // ── Internal ──────────────────────────────────────────────────────────────

    /**
     * @dev Settle all pending rewards for `user` into claimable[user].
     *      Syncs rewardDebt to current balance. Safe to call on address(0) (no-op).
     *
     *      Called from:
     *        - _update() before balance changes
     *        - claim() before reading claimable balance
     *
     *      IMPORTANT: after _settle(), rewardDebt[user] reflects the PRE-transfer balance.
     *      The _update() hook overwrites it again after super._update() changes balances.
     */
    function _settle(address user) internal {
        if (user == address(0)) return;
        uint256 shares = balanceOf(user);
        uint256 accrued = (shares * accRewardPerShare) / PRECISION;
        uint256 pending = accrued > rewardDebt[user] ? accrued - rewardDebt[user] : 0;
        if (pending > 0) claimable[user] += pending;
        rewardDebt[user] = accrued; // sync even when pending == 0
    }

    /**
     * @dev ERC20 transfer/mint/burn hook.
     *      Settles rewards BEFORE balance changes, then resyncs rewardDebt AFTER.
     *
     *      Step 1 (_settle): settle pending on PRE-transfer balance, write rewardDebt based on that.
     *      Step 2 (super._update): balances change.
     *      Step 3 (post-sync): overwrite rewardDebt to POST-transfer balance.
     *
     *      The post-sync is required: _settle wrote rewardDebt based on old balance;
     *      without overwriting it, the next _settle call would compute phantom rewards.
     */
    function _update(address from, address to, uint256 value) internal override {
        // Settle BEFORE balance changes (pending computed on current balance)
        _settle(from);
        _settle(to);

        super._update(from, to, value); // balances change here

        // Sync rewardDebt to NEW balance (accRewardPerShare unchanged — no new pending)
        if (from != address(0)) rewardDebt[from] = (balanceOf(from) * accRewardPerShare) / PRECISION;
        if (to != address(0)) rewardDebt[to] = (balanceOf(to) * accRewardPerShare) / PRECISION;
    }

    /**
     * @dev Guarantee the vault holds at least `needed` idle USDC before a withdrawal.
     *      If idle is insufficient, the ENTIRE adapter position is closed.
     *      Excess returned USDC stays idle; deployIdle() re-deploys it later.
     *
     *      Note: idle check uses raw balanceOf, not the reserve-adjusted available amount.
     *      This is intentional: _ensureIdle is a liquidity guarantee for withdrawers,
     *      not a totalAssets calculation.
     */
    function _ensureIdle(uint256 needed) internal {
        uint256 idle = IERC20(asset()).balanceOf(address(this));
        if (idle >= needed) return;
        if (address(adapter) == address(0)) return;
        adapter.withdrawAll();
    }
}
