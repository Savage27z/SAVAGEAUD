// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IAgentTreasury} from "../interfaces/IAgentTreasury.sol";
import {IStrategyAdapter} from "../interfaces/IStrategyAdapter.sol";
import {MathLib} from "../libraries/MathLib.sol";
import {ErrorLib} from "../libraries/ErrorLib.sol";

/// @title ArcisAgentVault
/// @author Arcis Protocol (arcis.money)
/// @notice Factory-deployed ERC-4626 vault for any agent token ($CUSTOS, $AKITA, ...)
/// @dev Accepts an arbitrary ERC-20 asset, mints ra<TOKEN> share tokens, routes capital
///      to per-asset yield strategies (or operates reserve-only for credit collateral).
///      Deployed exclusively by ArcisVaultFactory. Logic mirrors ArcisVault (USDC) 1:1,
///      parameterized for asset address, metadata, decimals, and minimum deposit.
///      Implements the ATI standard (deposit/withdraw/balance) plus ERC-20 for shares.
///
///      Security:
///      - Virtual shares/assets offset to prevent ERC-4626 inflation attacks
///      - Reentrancy guard on all state-changing functions
///      - Deposit cap enforced per-vault
///      - Pausable by owner (multisig)
///      - Management fee accrual on harvest
///
///      Share price: exchangeRate = totalAssets / totalShares
///      As yield accrues, each share becomes worth more of the underlying asset.
contract ArcisAgentVault is IAgentTreasury {
    using MathLib for uint256;

    // ══════════════════════════════════════════════════════════════
    //                          CONSTANTS
    // ══════════════════════════════════════════════════════════════

    /// @notice Underlying asset token address (set by factory)
    address public immutable ASSET;

    /// @notice Minimum deposit amount in asset units (set by factory)
    uint256 public immutable MIN_DEPOSIT;

    /// @notice Virtual offset for inflation-attack protection (+1 share / +1 asset).
    /// @dev Donation attacks are structurally neutralized because totalAssets() is
    ///      internal accounting (reserveBalance + deployedBalance) — direct token
    ///      transfers to the vault are not counted. The +1/+1 offset removes the
    ///      remaining rounding edge while keeping shares 1:1 with asset units.
    uint256 private constant VIRTUAL_ASSET_OFFSET = 1;

    /// @notice Maximum management fee: 5% (500 bps)
    uint256 public constant MAX_FEE_BPS = 500;

    /// @notice Fee denominator
    uint256 public constant BPS_DENOMINATOR = 10_000;

    // ══════════════════════════════════════════════════════════════
    //                        ERC-20 STORAGE
    // ══════════════════════════════════════════════════════════════

    string public name;
    string public symbol;
    uint8 public immutable decimals;

    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    /// @notice Timestamp of last deposit per agent (for withdrawal fee ramp)
    mapping(address => uint256) public lastDepositTime;

    /// @notice Early withdrawal fee in bps (applied within WITHDRAWAL_FEE_WINDOW)
    uint256 public constant WITHDRAWAL_FEE_BPS = 10; // 0.1%

    /// @notice Window after deposit during which withdrawal fee applies
    uint256 public constant WITHDRAWAL_FEE_WINDOW = 24 hours;

    // ══════════════════════════════════════════════════════════════
    //                       VAULT STORAGE
    // ══════════════════════════════════════════════════════════════

    /// @notice Total asset units held in vault reserve (not deployed to strategies)
    uint256 public reserveBalance;

    /// @notice Total asset value across all strategies (updated on harvest)
    uint256 public deployedBalance;

    /// @notice Maximum total deposits (in asset units)
    uint256 public depositCap;

    /// @notice Maximum deposit per agent (0 = no per-agent limit)
    uint256 public perAgentCap;

    /// @notice Management fee in basis points
    uint256 public feeBps;

    /// @notice Fee recipient address
    address public feeRecipient;

    /// @notice Owner (multisig)
    address public owner;

    /// @notice Pending owner for two-step transfer
    address public pendingOwner;

    /// @notice Whether deposits/withdrawals are paused
    bool public paused;

    /// @notice Reentrancy lock
    uint256 private _locked = 1;

    // ══════════════════════════════════════════════════════════════
    //                     STRATEGY STORAGE
    // ══════════════════════════════════════════════════════════════

    /// @notice Registered strategy adapters
    IStrategyAdapter[] public strategies;

    /// @notice Allocation weight per strategy (in bps, must sum to 10000)
    uint256[] public allocationWeights;

    /// @notice Whether an address is a registered strategy
    mapping(address => bool) public isStrategy;

    /// @notice Target reserve ratio in bps (portion kept liquid in vault)
    uint256 public immutable reserveRatioBps;

    /// @notice Strategy addition timelock (24 hours)
    uint256 public constant STRATEGY_TIMELOCK = 24 hours;

    /// @notice Pending strategy addition
    struct PendingStrategy {
        address strategy;
        uint256 weight;
        uint256 executeAfter;
    }
    PendingStrategy public pendingStrategy;

    event StrategyQueued(address indexed strategy, uint256 weight, uint256 executeAfter);
    event StrategyCancelled(address indexed strategy);

    // ══════════════════════════════════════════════════════════════
    //                         EVENTS
    // ══════════════════════════════════════════════════════════════

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
    event DepositCapUpdated(uint256 oldCap, uint256 newCap);
    event FeeUpdated(uint256 oldFee, uint256 newFee);
    event StrategyAdded(address indexed strategy, uint256 weight);
    event StrategyRemoved(address indexed strategy);
    event AllocationUpdated(uint256[] weights);
    event Harvested(uint256 totalYield, uint256 fee);
    event Paused(address indexed by);
    event Unpaused(address indexed by);
    event OwnershipTransferStarted(address indexed current, address indexed pending);
    event OwnershipTransferred(address indexed previous, address indexed current);
    event EmergencyWithdraw(address indexed strategy, uint256 recovered);

    // ══════════════════════════════════════════════════════════════
    //                        MODIFIERS
    // ══════════════════════════════════════════════════════════════

    modifier nonReentrant() {
        if (_locked != 1) revert ErrorLib.Unauthorized(msg.sender);
        _locked = 2;
        _;
        _locked = 1;
    }

    modifier whenNotPaused() {
        if (paused) revert ErrorLib.VaultPaused();
        _;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert ErrorLib.Unauthorized(msg.sender);
        _;
    }

    // ══════════════════════════════════════════════════════════════
    //                       CONSTRUCTOR
    // ══════════════════════════════════════════════════════════════

    /// @param _asset Underlying agent token address
    /// @param _name Share token name (e.g. "Arcis CUSTOS")
    /// @param _symbol Share token symbol (e.g. "raCUSTOS")
    /// @param _decimals Share decimals (mirrors the underlying asset)
    /// @param _minDeposit Minimum deposit in asset units
    /// @param _depositCap Initial deposit cap in asset units
    /// @param _feeBps Management fee in basis points
    /// @param _feeRecipient Address to receive management fees
    /// @param _reserveRatioBps Percentage of deposits kept liquid (10000 = reserve-only)
    /// @param _owner Vault owner (factory passes its own owner through)
    constructor(
        address _asset,
        string memory _name,
        string memory _symbol,
        uint8 _decimals,
        uint256 _minDeposit,
        uint256 _depositCap,
        uint256 _feeBps,
        address _feeRecipient,
        uint256 _reserveRatioBps,
        address _owner
    ) {
        if (_asset == address(0)) revert ErrorLib.ZeroAddress();
        if (_feeRecipient == address(0)) revert ErrorLib.ZeroAddress();
        if (_owner == address(0)) revert ErrorLib.ZeroAddress();
        if (_feeBps > MAX_FEE_BPS) revert ErrorLib.InvalidAllocation();
        if (_reserveRatioBps > BPS_DENOMINATOR) revert ErrorLib.InvalidAllocation();

        ASSET = _asset;
        name = _name;
        symbol = _symbol;
        decimals = _decimals;
        MIN_DEPOSIT = _minDeposit;
        depositCap = _depositCap;
        feeBps = _feeBps;
        feeRecipient = _feeRecipient;
        reserveRatioBps = _reserveRatioBps;
        owner = _owner;
    }

    // ══════════════════════════════════════════════════════════════
    //                  ATI INTERFACE (3 functions)
    // ══════════════════════════════════════════════════════════════

    /// @inheritdoc IAgentTreasury
    function deposit(uint256 amount) external nonReentrant whenNotPaused returns (uint256 shares) {
        if (amount == 0) revert ErrorLib.ZeroAmount();
        if (amount < MIN_DEPOSIT) revert ErrorLib.DepositTooSmall(amount, MIN_DEPOSIT);

        uint256 totalBefore = totalAssets();
        if (totalBefore + amount > depositCap) {
            revert ErrorLib.VaultCapExceeded(amount, depositCap - totalBefore);
        }

        // Per-agent cap check
        if (perAgentCap > 0) {
            uint256 currentValue = balanceOf[msg.sender] > 0 ? _convertToAssets(balanceOf[msg.sender], false) : 0;
            if (currentValue + amount > perAgentCap) {
                revert ErrorLib.VaultCapExceeded(amount, perAgentCap - currentValue);
            }
        }

        // Calculate shares BEFORE transfer (prevents manipulation)
        shares = _convertToShares(amount, false);
        if (shares == 0) revert ErrorLib.ZeroShares();

        // Transfer asset from agent to vault
        _safeTransferFrom(ASSET, msg.sender, address(this), amount);

        // Update reserve balance
        reserveBalance += amount;

        // Record deposit time for withdrawal fee ramp
        lastDepositTime[msg.sender] = block.timestamp;

        // Mint vault shares
        _mint(msg.sender, shares);

        emit Deposit(msg.sender, amount, shares);
    }

    /// @inheritdoc IAgentTreasury
    function withdraw(uint256 shares) external nonReentrant whenNotPaused returns (uint256 amount) {
        if (shares == 0) revert ErrorLib.ZeroShares();
        if (balanceOf[msg.sender] < shares) {
            revert ErrorLib.InsufficientShares(shares, balanceOf[msg.sender]);
        }

        // Calculate asset amount BEFORE burning shares
        amount = _convertToAssets(shares, false);
        if (amount == 0) revert ErrorLib.ZeroAmount();

        // Check liquidity — try reserve first, then pull from strategies
        if (amount > reserveBalance) {
            uint256 deficit = amount - reserveBalance;
            uint256 pulled = _pullFromStrategies(deficit);
            if (reserveBalance + pulled < amount) {
                revert ErrorLib.InsufficientLiquidity(amount, reserveBalance + pulled);
            }
        }

        // Burn shares
        _burn(msg.sender, shares);

        // Apply early withdrawal fee if within 24h of deposit
        uint256 fee = 0;
        if (block.timestamp < lastDepositTime[msg.sender] + WITHDRAWAL_FEE_WINDOW) {
            fee = MathLib.bps(amount, WITHDRAWAL_FEE_BPS);
            if (fee > 0 && feeRecipient != address(0)) {
                _safeTransfer(ASSET, feeRecipient, fee);
            }
            amount -= fee;
        }

        // Update reserve (full amount including fee leaves the vault)
        reserveBalance -= (amount + fee);

        // Transfer asset to agent
        _safeTransfer(ASSET, msg.sender, amount);

        emit Withdraw(msg.sender, amount, shares);
    }

    /// @notice Emergency withdrawal — works even when vault is paused
    /// @dev Only withdraws from reserve (no strategy pulls). Users can exit
    ///      after owner calls emergencyWithdrawStrategy() to refill reserve.
    /// @param shares Vault shares to redeem
    /// @return amount Asset units returned to caller
    function emergencyWithdraw(uint256 shares) external nonReentrant returns (uint256 amount) {
        if (shares == 0) revert ErrorLib.ZeroShares();
        if (balanceOf[msg.sender] < shares) {
            revert ErrorLib.InsufficientShares(shares, balanceOf[msg.sender]);
        }

        amount = _convertToAssets(shares, false);
        if (amount == 0) revert ErrorLib.ZeroAmount();

        // Emergency: reserve only, no strategy pulls
        if (amount > reserveBalance) {
            revert ErrorLib.InsufficientLiquidity(amount, reserveBalance);
        }

        _burn(msg.sender, shares);
        reserveBalance -= amount;
        _safeTransfer(ASSET, msg.sender, amount);

        emit Withdraw(msg.sender, amount, shares);
    }

    /// @inheritdoc IAgentTreasury
    function balance(address agent) external view returns (uint256) {
        if (balanceOf[agent] == 0) return 0;
        return _convertToAssets(balanceOf[agent], false);
    }

    // ══════════════════════════════════════════════════════════════
    //                      VIEW FUNCTIONS
    // ══════════════════════════════════════════════════════════════

    /// @notice Total asset value managed by the vault
    function totalAssets() public view returns (uint256) {
        return reserveBalance + deployedBalance;
    }

    /// @notice The underlying asset token address (ATI v1.1)
    /// @dev Agents call this to discover what token to approve before depositing
    function asset() external view returns (address) {
        return ASSET;
    }

    /// @notice Maximum amount that can be deposited by a given agent (ATI v1.1)
    /// @dev Returns 0 if vault is paused or at capacity
    function maxDeposit(address agent) external view returns (uint256) {
        if (paused) return 0;
        uint256 total = totalAssets();
        if (total >= depositCap) return 0;
        uint256 globalRemaining = depositCap - total;

        if (perAgentCap == 0) return globalRemaining;

        uint256 currentValue = balanceOf[agent] > 0 ? _convertToAssets(balanceOf[agent], false) : 0;
        if (currentValue >= perAgentCap) return 0;
        uint256 agentRemaining = perAgentCap - currentValue;

        return MathLib.min(globalRemaining, agentRemaining);
    }

    /// @notice Current exchange rate: asset units per share (in WAD)
    function exchangeRate() external view returns (uint256) {
        if (totalSupply == 0) return 1e18;
        return MathLib.mulDiv(totalAssets(), 1e18, totalSupply);
    }

    /// @notice Preview how many shares a deposit would mint
    function previewDeposit(uint256 assets) external view returns (uint256) {
        return _convertToShares(assets, false);
    }

    /// @notice Preview how much of the asset a withdrawal would return
    function previewWithdraw(uint256 shares) external view returns (uint256) {
        return _convertToAssets(shares, false);
    }

    // ══════════════════════════════════════════════════════════════
    //                     ERC-4626 COMPATIBILITY
    // ══════════════════════════════════════════════════════════════

    /// @notice Convert asset amount to share amount (no rounding direction preference)
    function convertToShares(uint256 assets) external view returns (uint256) {
        return _convertToShares(assets, false);
    }

    /// @notice Convert share amount to asset amount
    function convertToAssets(uint256 shares) external view returns (uint256) {
        return _convertToAssets(shares, false);
    }

    /// @notice Preview redeem (alias for previewWithdraw — same calculation)
    function previewRedeem(uint256 shares) external view returns (uint256) {
        return _convertToAssets(shares, false);
    }

    /// @notice Preview mint — how many assets needed to mint exact shares
    function previewMint(uint256 shares) external view returns (uint256) {
        return _convertToAssets(shares, true); // Round up for minting
    }

    /// @notice Maximum assets an owner can withdraw
    function maxWithdraw(address account) external view returns (uint256) {
        if (paused) return 0;
        if (balanceOf[account] == 0) return 0;
        return _convertToAssets(balanceOf[account], false);
    }

    /// @notice Maximum shares an owner can redeem
    function maxRedeem(address account) external view returns (uint256) {
        if (paused) return 0;
        return balanceOf[account];
    }

    /// @notice Maximum shares that can be minted (based on remaining deposit cap)
    function maxMint(address) external view returns (uint256) {
        if (paused) return 0;
        uint256 total = totalAssets();
        if (total >= depositCap) return 0;
        return _convertToShares(depositCap - total, false);
    }

    /// @notice Remaining capacity before deposit cap
    function remainingCapacity() external view returns (uint256) {
        uint256 total = totalAssets();
        if (total >= depositCap) return 0;
        return depositCap - total;
    }

    /// @notice Number of registered strategies
    function strategyCount() external view returns (uint256) {
        return strategies.length;
    }

    // ══════════════════════════════════════════════════════════════
    //                    STRATEGY MANAGEMENT
    // ══════════════════════════════════════════════════════════════

    /// @notice Add a new yield strategy
    /// @param strategy Address of the strategy adapter
    /// @param weight Allocation weight in bps
    function queueStrategy(address strategy, uint256 weight) external onlyOwner {
        if (strategy == address(0)) revert ErrorLib.ZeroAddress();
        if (isStrategy[strategy]) revert ErrorLib.StrategyAlreadyRegistered(strategy);

        uint256 executeAfter = block.timestamp + STRATEGY_TIMELOCK;
        pendingStrategy = PendingStrategy(strategy, weight, executeAfter);

        emit StrategyQueued(strategy, weight, executeAfter);
    }

    function executeStrategy() external onlyOwner {
        PendingStrategy memory ps = pendingStrategy;
        if (ps.strategy == address(0)) revert ErrorLib.ZeroAddress();
        if (block.timestamp < ps.executeAfter) revert ErrorLib.TimelockNotExpired(ps.executeAfter);
        if (isStrategy[ps.strategy]) revert ErrorLib.StrategyAlreadyRegistered(ps.strategy);

        strategies.push(IStrategyAdapter(ps.strategy));
        allocationWeights.push(ps.weight);
        isStrategy[ps.strategy] = true;

        _safeApprove(ASSET, ps.strategy, type(uint256).max);

        delete pendingStrategy;
        emit StrategyAdded(ps.strategy, ps.weight);
    }

    function cancelPendingStrategy() external onlyOwner {
        address s = pendingStrategy.strategy;
        delete pendingStrategy;
        emit StrategyCancelled(s);
    }

    /// @notice Update allocation weights for all strategies
    /// @param weights New weights array (must sum to 10000 - reserveRatioBps)
    function updateAllocations(uint256[] calldata weights) external onlyOwner {
        if (weights.length != strategies.length) revert ErrorLib.InvalidAllocation();

        uint256 sum = 0;
        for (uint256 i; i < weights.length; ++i) {
            sum += weights[i];
        }

        // Weights + reserve ratio must equal 10000
        if (sum + reserveRatioBps != BPS_DENOMINATOR) {
            revert ErrorLib.AllocationSumMismatch(sum + reserveRatioBps);
        }

        allocationWeights = weights;
        emit AllocationUpdated(weights);
    }

    /// @notice Deploy reserve capital to strategies according to allocation weights
    function rebalance() external onlyOwner nonReentrant {
        uint256 total = totalAssets();
        if (total == 0) return;

        uint256 targetReserve = MathLib.bps(total, reserveRatioBps);

        // Deploy excess reserve to strategies
        if (reserveBalance > targetReserve) {
            uint256 toDeploy = reserveBalance - targetReserve;
            _deployToStrategies(toDeploy);
        }
    }

    /// @notice Harvest yield from all strategies, take fee, update deployed balance
    function harvest() external nonReentrant returns (uint256 totalYield) {
        uint256 totalValueBefore = deployedBalance;
        uint256 stratLen = strategies.length;

        // Harvest each strategy
        for (uint256 i; i < stratLen; ++i) {
            if (strategies[i].isActive()) {
                strategies[i].harvest();
            }
        }

        // Recalculate total deployed value
        uint256 newDeployed = 0;
        for (uint256 i; i < stratLen; ++i) {
            newDeployed += strategies[i].totalValue();
        }

        if (newDeployed > totalValueBefore) {
            totalYield = newDeployed - totalValueBefore;

            // Take management fee on yield
            uint256 fee = MathLib.bps(totalYield, feeBps);
            if (fee > 0) {
                // Mint fee shares to feeRecipient
                uint256 feeShares = _convertToShares(fee, false);
                if (feeShares > 0) {
                    _mint(feeRecipient, feeShares);
                }
            }
        }

        deployedBalance = newDeployed;
        emit Harvested(totalYield, MathLib.bps(totalYield, feeBps));
    }

    // ══════════════════════════════════════════════════════════════
    //                     ADMIN FUNCTIONS
    // ══════════════════════════════════════════════════════════════

    function setDepositCap(uint256 newCap) external onlyOwner {
        emit DepositCapUpdated(depositCap, newCap);
        depositCap = newCap;
    }

    function setPerAgentCap(uint256 newCap) external onlyOwner {
        perAgentCap = newCap;
    }

    function setFeeBps(uint256 newFee) external onlyOwner {
        if (newFee > MAX_FEE_BPS) revert ErrorLib.InvalidAllocation();
        emit FeeUpdated(feeBps, newFee);
        feeBps = newFee;
    }

    function setFeeRecipient(address newRecipient) external onlyOwner {
        if (newRecipient == address(0)) revert ErrorLib.ZeroAddress();
        feeRecipient = newRecipient;
    }

    function pause() external onlyOwner {
        paused = true;
        emit Paused(msg.sender);
    }

    function unpause() external onlyOwner {
        paused = false;
        emit Unpaused(msg.sender);
    }

    /// @notice Two-step ownership transfer
    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ErrorLib.ZeroAddress();
        pendingOwner = newOwner;
        emit OwnershipTransferStarted(owner, newOwner);
    }

    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert ErrorLib.Unauthorized(msg.sender);
        emit OwnershipTransferred(owner, msg.sender);
        owner = msg.sender;
        pendingOwner = address(0);
    }

    /// @notice Emergency: pull all funds from a strategy
    function emergencyWithdrawStrategy(uint256 index) external onlyOwner nonReentrant {
        IStrategyAdapter strategy = strategies[index];
        uint256 recovered = strategy.emergencyWithdraw();
        reserveBalance += recovered;
        deployedBalance -= MathLib.min(strategies[index].totalValue(), deployedBalance);
        emit EmergencyWithdraw(address(strategy), recovered);
    }

    // ══════════════════════════════════════════════════════════════
    //                     ERC-20 FUNCTIONS
    // ══════════════════════════════════════════════════════════════

    function transfer(address to, uint256 amount) external returns (bool) {
        if (to == address(0)) revert ErrorLib.ZeroAddress();
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        emit Transfer(msg.sender, to, amount);
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        if (to == address(0)) revert ErrorLib.ZeroAddress();
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            allowance[from][msg.sender] = allowed - amount;
        }
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
        return true;
    }

    // ══════════════════════════════════════════════════════════════
    //                    INTERNAL FUNCTIONS
    // ══════════════════════════════════════════════════════════════

    function _convertToShares(uint256 assets, bool roundUp) internal view returns (uint256) {
        uint256 virtualShares = totalSupply + 1;
        uint256 virtualAssets = totalAssets() + VIRTUAL_ASSET_OFFSET;
        if (roundUp) return MathLib.mulDivUp(assets, virtualShares, virtualAssets);
        return MathLib.mulDiv(assets, virtualShares, virtualAssets);
    }

    function _convertToAssets(uint256 shares, bool roundUp) internal view returns (uint256) {
        uint256 virtualShares = totalSupply + 1;
        uint256 virtualAssets = totalAssets() + VIRTUAL_ASSET_OFFSET;
        if (roundUp) return MathLib.mulDivUp(shares, virtualAssets, virtualShares);
        return MathLib.mulDiv(shares, virtualAssets, virtualShares);
    }

    function _mint(address to, uint256 amount) internal {
        totalSupply += amount;
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    function _burn(address from, uint256 amount) internal {
        balanceOf[from] -= amount;
        totalSupply -= amount;
        emit Transfer(from, address(0), amount);
    }

    /// @dev Deploy capital to strategies according to allocation weights
    function _deployToStrategies(uint256 amount) internal {
        uint256 stratLen = strategies.length;
        for (uint256 i; i < stratLen; ++i) {
            if (!strategies[i].isActive()) continue;

            uint256 portion = MathLib.bps(amount, allocationWeights[i]);
            if (portion == 0) continue;

            // Transfer asset to strategy and deploy
            _safeTransfer(ASSET, address(strategies[i]), portion);
            uint256 deployed = strategies[i].deploy(portion);

            reserveBalance -= portion;
            deployedBalance += deployed;
        }
    }

    /// @dev Pull capital from strategies to cover withdrawal deficit
    function _pullFromStrategies(uint256 deficit) internal returns (uint256 totalPulled) {
        uint256 stratLen = strategies.length;
        for (uint256 i; i < stratLen && totalPulled < deficit; ++i) {
            if (!strategies[i].isActive()) continue;

            uint256 available = strategies[i].availableLiquidity();
            uint256 toPull = MathLib.min(available, deficit - totalPulled);

            if (toPull > 0) {
                uint256 pulled = strategies[i].withdrawFromStrategy(toPull);
                totalPulled += pulled;
                deployedBalance -= MathLib.min(pulled, deployedBalance);
                reserveBalance += pulled;
            }
        }
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

    function _safeApprove(address token, address spender, uint256 amount) internal {
        (bool success, bytes memory data) = token.call(
            abi.encodeWithSelector(0x095ea7b3, spender, amount)
        );
        if (!success || (data.length > 0 && !abi.decode(data, (bool)))) revert ErrorLib.ApprovalFailed();
    }
}
