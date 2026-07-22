// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {ERC20PermitUpgradeable} from
    "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IQuiverStrategy} from "./interfaces/IQuiverStrategy.sol";

/// @title QuiverVault — price-blind proportional shares over a CL position.
/// @notice Shares are a plain ERC-20 (+permit) claim on a fraction of the
///         strategy's liquidity. No oracle ever enters the share math:
///         deposits are strictly proportional (excess is never pulled),
///         withdrawals are always in-kind. The vault is immutable; the
///         strategy pointer is swappable behind a delay — that is the only
///         upgrade path.
contract QuiverVault is ERC20PermitUpgradeable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    enum VaultState {
        Active,
        Paused,
        Panicked
    }

    uint256 public constant STRATEGY_SWAP_DELAY = 48 hours;
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;

    address public factory;
    address public owner; // the timelock
    address public guardian; // emergency-only powers
    address public keeper; // the agent — emergency powers here, rails live in the strategy

    IQuiverStrategy public strategy;
    IERC20 public token0;
    IERC20 public token1;
    VaultState public state;

    address public proposedStrategy;
    uint256 public strategySwapEta;

    event Deposit(address indexed user, address indexed receiver, uint256 shares, uint256 amount0, uint256 amount1);
    event Withdraw(address indexed user, address indexed receiver, uint256 shares, uint256 amount0, uint256 amount1, bool inKind);
    event StateChanged(VaultState state);
    event StrategyProposed(address indexed strategy, uint256 eta);
    event StrategyProposalCancelled(address indexed strategy);
    event StrategySwapped(address indexed oldStrategy, address indexed newStrategy);
    event OwnerSet(address owner);
    event GuardianSet(address guardian);
    event KeeperSet(address keeper);

    error NotOwner();
    error NotEmergencyAuthority();
    error NotFactory();
    error NotActive();
    error NotCalm();
    error WrongState();
    error ZeroAmount();
    error ZeroAddress();
    error SlippageShares();
    error SlippageAmounts();
    error NoProposal();
    error TimelockNotElapsed();
    error TokenMismatch();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    /// @dev pause/panic are risk-reducing: owner, guardian and the agent may all trigger them.
    modifier onlyEmergencyAuthority() {
        if (msg.sender != owner && msg.sender != guardian && msg.sender != keeper) revert NotEmergencyAuthority();
        _;
    }

    constructor() {
        _disableInitializers();
    }

    function initialize(
        address strategy_,
        address owner_,
        address guardian_,
        address keeper_,
        string calldata name_,
        string calldata symbol_
    ) external initializer {
        if (strategy_ == address(0) || owner_ == address(0) || guardian_ == address(0) || keeper_ == address(0)) {
            revert ZeroAddress();
        }
        __ERC20_init(name_, symbol_);
        __ERC20Permit_init(name_);

        factory = msg.sender;
        strategy = IQuiverStrategy(strategy_);
        token0 = IERC20(IQuiverStrategy(strategy_).token0());
        token1 = IERC20(IQuiverStrategy(strategy_).token1());
        owner = owner_;
        guardian = guardian_;
        keeper = keeper_;
        state = VaultState.Active;
    }

    // ---------------------------------------------------------------- views

    function isActive() external view returns (bool) {
        return state == VaultState.Active;
    }

    /// @notice Liquidity units one full share represents, scaled by 1e18.
    ///         Monotonically increasing through compounding; display-only.
    function pricePerFullShare() external view returns (uint256) {
        uint256 supply = totalSupply();
        if (supply == 0) return 1e18;
        return Math.mulDiv(strategy.totalLiquidity(), 1e18, supply);
    }

    // ------------------------------------------------------------- user flow

    /// @notice Proportional two-token deposit. Pulls exactly what the current
    ///         position composition needs (never more than the stated maxima),
    ///         mints shares equal to the fraction of liquidity added.
    function deposit(uint256 amount0Max, uint256 amount1Max, uint256 minShares, address receiver)
        external
        nonReentrant
        returns (uint256 shares)
    {
        if (state != VaultState.Active) revert NotActive();
        if (receiver == address(0)) revert ZeroAddress();
        // Deposits only in calm periods: the required token ratio is derived
        // from the current price, so a flash-skewed pool must not set it.
        if (!strategy.isCalm()) revert NotCalm();

        // Compound pending yield first so entry PPS is honest (harvestOnDeposit);
        // the depositor earns the caller fee for the gas they spend.
        strategy.harvest(msg.sender);

        uint128 liquidityBefore = strategy.totalLiquidity();
        (uint256 used0, uint256 used1, uint128 quotedLiquidity) = strategy.quoteDeposit(amount0Max, amount1Max);
        if (quotedLiquidity == 0) revert ZeroAmount();

        if (used0 > 0) token0.safeTransferFrom(msg.sender, address(strategy), used0);
        if (used1 > 0) token1.safeTransferFrom(msg.sender, address(strategy), used1);
        uint128 liquidityAdded = strategy.invest(used0, used1);
        if (liquidityAdded == 0) revert ZeroAmount();

        uint256 supply = totalSupply();
        shares = supply == 0 ? liquidityAdded : Math.mulDiv(supply, liquidityAdded, liquidityBefore);
        if (shares == 0 || shares < minShares) revert SlippageShares();

        _mint(receiver, shares);
        emit Deposit(msg.sender, receiver, shares, used0, used1);
    }

    /// @notice In-kind pro-rata withdrawal. Callable in EVERY state — pause and
    ///         panic never block exits. No swap, no oracle.
    function withdraw(uint256 shares, uint256 min0, uint256 min1, address receiver)
        external
        nonReentrant
        returns (uint256 out0, uint256 out1)
    {
        if (shares == 0) revert ZeroAmount();
        if (receiver == address(0)) revert ZeroAddress();

        uint256 supply = totalSupply();
        _burn(msg.sender, shares); // CEI: burn before external interaction

        (out0, out1) = strategy.divest(shares, supply, receiver);
        if (out0 < min0 || out1 < min1) revert SlippageAmounts();

        emit Withdraw(msg.sender, receiver, shares, out0, out1, true);
    }

    // ------------------------------------------------------------- emergency

    function pause() external onlyEmergencyAuthority {
        if (state != VaultState.Active) revert WrongState();
        state = VaultState.Paused;
        emit StateChanged(state);
    }

    function unpause() external onlyOwner {
        if (state != VaultState.Paused) revert WrongState();
        state = VaultState.Active;
        emit StateChanged(state);
    }

    /// @notice Evacuate the pool position. Zero swaps, zero oracle reads —
    ///         works mid-manipulation. Withdrawals stay open throughout.
    function panic() external onlyEmergencyAuthority {
        if (state == VaultState.Panicked) revert WrongState();
        state = VaultState.Panicked;
        strategy.emergencyExit();
        emit StateChanged(state);
    }

    function unpanic() external onlyOwner {
        if (state != VaultState.Panicked) revert WrongState();
        state = VaultState.Active;
        strategy.reinvestIdle();
        emit StateChanged(state);
    }

    // ------------------------------------------------- strategy swap (48h)

    function proposeStrategy(address newStrategy) external onlyOwner {
        if (newStrategy == address(0)) revert ZeroAddress();
        if (
            IQuiverStrategy(newStrategy).token0() != address(token0)
                || IQuiverStrategy(newStrategy).token1() != address(token1)
        ) revert TokenMismatch();
        proposedStrategy = newStrategy;
        strategySwapEta = block.timestamp + STRATEGY_SWAP_DELAY;
        emit StrategyProposed(newStrategy, strategySwapEta);
    }

    function cancelStrategyProposal() external onlyOwner {
        emit StrategyProposalCancelled(proposedStrategy);
        proposedStrategy = address(0);
        strategySwapEta = 0;
    }

    function executeStrategySwap() external onlyOwner nonReentrant {
        address next = proposedStrategy;
        if (next == address(0)) revert NoProposal();
        if (block.timestamp < strategySwapEta) revert TimelockNotElapsed();

        address old = address(strategy);
        proposedStrategy = address(0);
        strategySwapEta = 0;

        IQuiverStrategy(old).retireTo(next);
        strategy = IQuiverStrategy(next);
        if (state == VaultState.Active) IQuiverStrategy(next).reinvestIdle();

        emit StrategySwapped(old, next);
    }

    // ----------------------------------------------------------------- admin

    function setOwner(address owner_) external onlyOwner {
        if (owner_ == address(0)) revert ZeroAddress();
        owner = owner_;
        emit OwnerSet(owner_);
    }

    function setGuardian(address guardian_) external onlyOwner {
        if (guardian_ == address(0)) revert ZeroAddress();
        guardian = guardian_;
        emit GuardianSet(guardian_);
    }

    function setKeeper(address keeper_) external onlyOwner {
        if (keeper_ == address(0)) revert ZeroAddress();
        keeper = keeper_;
        emit KeeperSet(keeper_);
    }

    /// @notice Factory-only: invest the seed amounts (already transferred to the
    ///         strategy) and mint the resulting shares to the dead address, so
    ///         no first depositor ever holds a manipulable full supply.
    function seedDeposit(uint256 amount0, uint256 amount1) external returns (uint128 seedLiquidity) {
        if (msg.sender != factory) revert NotFactory();
        if (totalSupply() != 0) revert WrongState();
        seedLiquidity = strategy.invest(amount0, amount1);
        if (seedLiquidity == 0) revert ZeroAmount();
        _mint(DEAD, seedLiquidity);
    }
}
