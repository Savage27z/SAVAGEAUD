// SPDX-License-Identifier: MIT
// Source: 0x73fc59c56Aa57da86a17c26d1fcc0846735AFd92

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC4626}         from "../../lib/openzeppelin-contracts/contracts/token/ERC20/extensions/ERC4626.sol";
import {ERC20}           from "../../lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {IERC20}          from "../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20}       from "../../lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable}         from "../../lib/openzeppelin-contracts/contracts/access/Ownable.sol";
import {Pausable}        from "../../lib/openzeppelin-contracts/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "../../lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";

// ── Adapter interface ─────────────────────────────────────────────────────────

interface IUniV3Adapter {
    /// @dev Transfers `amount` USDC from caller, opens/adds to LP position.
    function deposit(uint256 amount)  external returns (uint256);

    /// @dev Closes the ENTIRE LP position and sends all USDC to the vault.
    ///      The adapter always performs a full close regardless of any amount argument,
    ///      so this surface makes that explicit. Must transfer proceeds before returning.
    function withdrawAll()            external returns (uint256 received);

    /// @dev Collect accrued LP fees, swap to USDC, transfer realized profit to vault.
    ///      Returns only the realized profit transferred — NOT a totalAssets delta.
    function harvest()                external returns (uint256 profit);

    /// @dev Trigger dynamic range rebalance. Cooldown enforced inside adapter.
    function rebalance()              external;

    /// @dev Close position and return all funds. Called on emergency — same as withdrawAll.
    function emergencyExit()          external;

    /// @dev Live LP value: liquidity * sqrtPrice math, no stale cache.
    function getTVL()                 external view returns (uint256);

    /// @dev Sample current pool tick into adapter volatility ring buffer.
    function recordTick()             external;
}

/**
 * @title  GrowthVaultV5
 * @notice ERC-4626 USDC vault backed by a single UniV3DynamicAdapterV5 position.
 *
 * Capital flow:
 *   deposit()    → USDC held idle in vault; keeper calls deployIdle() to push to adapter
 *   deployIdle() → deploys idle above reserve; reserve = idle * reserveRatio (not TVL-based)
 *   harvest()    → realized LP fee income returned; perf fee charged on realized profit only
 *   rebalance()  → adapter re-centres tick range; cooldown + benefit guards inside adapter
 *   withdraw()   → _ensureIdle pulls full adapter position if idle insufficient
 *
 * Accounting invariants:
 *   totalAssets() = vault.idleUSDC + adapter.getTVL()   (no phantom)
 *   harvest fee   = performanceFee bps on adapter.harvest() return value only
 *   reserve       = idle * reserveRatio / BPS           (no dependency on volatile TVL)
 */
contract GrowthVaultV5 is ERC4626, Ownable, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ── Constants ─────────────────────────────────────────────────────────────

    uint256 public constant MAX_PERFORMANCE_FEE = 2_000;   // 20 % hard cap (bps)
    uint256 public constant MAX_RESERVE_RATIO   = 5_000;   // 50 % hard cap
    uint256 public constant BPS                 = 10_000;

    // ── State ─────────────────────────────────────────────────────────────────

    IUniV3Adapter public adapter;
    address       public keeper;
    address       public feeRecipient;

    uint256 public performanceFee;   // bps
    uint256 public reserveRatio;     // bps of idle kept liquid
    uint256 public depositCap;       // 0 = uncapped
    uint256 public minDeposit;

    // ── Events ────────────────────────────────────────────────────────────────

    event Deployed(uint256 amount);
    event Harvested(uint256 realizedProfit, uint256 feeMinted);
    event Rebalanced();
    event EmergencyExitTriggered();
    event KeeperUpdated(address indexed keeper);
    event AdapterUpdated(address indexed adapter);
    event PerformanceFeeUpdated(uint256 bps);
    event ReserveRatioUpdated(uint256 bps);
    event FeeRecipientUpdated(address indexed recipient);
    event DepositCapUpdated(uint256 cap);

    // ── Errors ────────────────────────────────────────────────────────────────

    error NotKeeper();
    error ZeroAddress();
    error BelowMinDeposit();
    error DepositCapExceeded();
    error FeeTooHigh();
    error RatioTooHigh();
    error AdapterNotSet();
    error WithdrawShortfall(uint256 needed, uint256 idleAfter);

    // ── Modifiers ─────────────────────────────────────────────────────────────

    modifier onlyKeeper() {
        if (msg.sender != keeper && msg.sender != owner()) revert NotKeeper();
        _;
    }

    // ── Constructor ───────────────────────────────────────────────────────────

    constructor(
        IERC20        _asset,
        string memory _name,
        string memory _symbol,
        address       _keeper,
        address       _feeRecipient,
        uint256       _performanceFee,
        uint256       _reserveRatio
    )
        ERC4626(_asset)
        ERC20(_name, _symbol)
        Ownable(msg.sender)
    {
        if (_keeper == address(0) || _feeRecipient == address(0)) revert ZeroAddress();
        if (_performanceFee > MAX_PERFORMANCE_FEE) revert FeeTooHigh();
        if (_reserveRatio   > MAX_RESERVE_RATIO)   revert RatioTooHigh();

        keeper         = _keeper;
        feeRecipient   = _feeRecipient;
        performanceFee = _performanceFee;
        reserveRatio   = _reserveRatio;
    }

    // ── ERC-4626 ──────────────────────────────────────────────────────────────

    /// @dev idle USDC + live LP value. adapter.getTVL() uses sqrtPrice, not a cache.
    function totalAssets() public view override returns (uint256) {
        uint256 idle = IERC20(asset()).balanceOf(address(this));
        if (address(adapter) == address(0)) return idle;
        return idle + adapter.getTVL();
    }

    function deposit(uint256 assets, address receiver)
        public override nonReentrant whenNotPaused
        returns (uint256 shares)
    {
        if (assets < minDeposit) revert BelowMinDeposit();
        if (depositCap > 0 && totalAssets() + assets > depositCap) revert DepositCapExceeded();
        shares = super.deposit(assets, receiver);
    }

    function mint(uint256 shares, address receiver)
        public override nonReentrant whenNotPaused
        returns (uint256 assets)
    {
        assets = previewMint(shares);
        if (assets < minDeposit)                                    revert BelowMinDeposit();
        if (depositCap > 0 && totalAssets() + assets > depositCap) revert DepositCapExceeded();
        assets = super.mint(shares, receiver);
    }

    function withdraw(uint256 assets, address receiver, address _owner)
        public override nonReentrant whenNotPaused
        returns (uint256 shares)
    {
        _ensureIdle(assets);
        shares = super.withdraw(assets, receiver, _owner);
    }

    function redeem(uint256 shares, address receiver, address _owner)
        public override nonReentrant whenNotPaused
        returns (uint256 assets)
    {
        _ensureIdle(previewRedeem(shares));
        assets = super.redeem(shares, receiver, _owner);
    }

    // ── Keeper operations ─────────────────────────────────────────────────────

    /**
     * @notice Deploy idle USDC above the reserve into the adapter.
     * @dev    Reserve = idle * reserveRatio / BPS.
     *         Deliberately does NOT use totalAssets() to avoid a volatile getTVL() call
     *         affecting how much liquid buffer the vault retains.
     */
    function deployIdle() external onlyKeeper whenNotPaused {
        if (address(adapter) == address(0)) revert AdapterNotSet();
        uint256 idle    = IERC20(asset()).balanceOf(address(this));
        uint256 reserve = (idle * reserveRatio) / BPS;
        if (idle <= reserve) return;
        uint256 toDeploy = idle - reserve;
        IERC20(asset()).forceApprove(address(adapter), toDeploy);
        adapter.deposit(toDeploy);
        emit Deployed(toDeploy);
    }

    /**
     * @notice Collect realized LP fee income and charge performance fee.
     * @dev    Fee base = adapter.harvest() return value (USDC already in vault).
     *         totalAssets() delta is intentionally NOT used — unrealized price moves
     *         in the LP are not income and must not be taxed.
     */
    function harvest() external onlyKeeper nonReentrant whenNotPaused {
        if (address(adapter) == address(0)) revert AdapterNotSet();

        // realized profit: adapter collects fees, swaps WETH→USDC, transfers to vault
        uint256 profit = adapter.harvest();

        uint256 feeMinted;
        if (profit > 0 && performanceFee > 0 && feeRecipient != address(0)) {
            uint256 feeAssets = (profit * performanceFee) / BPS;
            feeMinted = convertToShares(feeAssets);
            if (feeMinted > 0) _mint(feeRecipient, feeMinted);
        }

        emit Harvested(profit, feeMinted);
    }

    /**
     * @notice Trigger the adapter's on-chain range rebalance.
     *         Cooldown, near-edge, and benefit guards are enforced inside the adapter.
     */
    function rebalance() external onlyKeeper whenNotPaused {
        if (address(adapter) == address(0)) revert AdapterNotSet();
        adapter.rebalance();
        emit Rebalanced();
    }

    /// @notice Sample current pool tick into adapter volatility ring buffer.
    function recordTick() external onlyKeeper {
        if (address(adapter) == address(0)) return;
        adapter.recordTick();
    }

    // ── Emergency ─────────────────────────────────────────────────────────────

    /// @notice Close adapter position immediately; vault paused until owner unpauses.
    function emergencyExit() external onlyOwner {
        _pause();
        if (address(adapter) != address(0)) adapter.emergencyExit();
        emit EmergencyExitTriggered();
    }

    function pause()   external onlyOwner { _pause();   }
    function unpause() external onlyOwner { _unpause(); }

    // ── Admin ─────────────────────────────────────────────────────────────────

    function setAdapter(address _adapter) external onlyOwner {
        if (_adapter == address(0)) revert ZeroAddress();
        adapter = IUniV3Adapter(_adapter);
        emit AdapterUpdated(_adapter);
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
        if (bps > MAX_RESERVE_RATIO) revert RatioTooHigh();
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

    // ── Internal ──────────────────────────────────────────────────────────────

    /**
     * @dev Guarantee the vault holds at least `needed` idle USDC before a withdrawal.
     *
     *      If idle is insufficient, the ENTIRE adapter position is closed via withdrawAll().
     *      The adapter does not support partial LP closes — calling withdrawAll() is the only
     *      safe path. Excess returned USDC stays idle; deployIdle() re-deploys it later.
     *
     *      Post-balance check guards against swap slippage or any shortfall the adapter
     *      returns vs. what the vault balance actually reflects.
     */
    function _ensureIdle(uint256 needed) internal {
        uint256 idle = IERC20(asset()).balanceOf(address(this));
        if (idle >= needed) return;
        if (address(adapter) == address(0)) return;

        // Full close: adapter swaps WETH→USDC, burns NFT, transfers all proceeds here.
        // Return value is informational; vault balance is the authoritative source.
        adapter.withdrawAll();

        uint256 idleAfter = IERC20(asset()).balanceOf(address(this));
        if (idleAfter < needed) revert WithdrawShortfall(needed, idleAfter);
    }
}
