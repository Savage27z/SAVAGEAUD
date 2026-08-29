// SPDX-License-Identifier: MIT
//https://deadeye.garden/
pragma solidity 0.8.29;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { ImmutableState } from "@uniswap/v4-periphery/src/base/ImmutableState.sol";
import { IPositionManager } from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import { Hooks } from "@uniswap/v4-core/src/libraries/Hooks.sol";
import { IHooks } from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import { SafeCast } from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { Currency, CurrencyLibrary } from "@uniswap/v4-core/src/types/Currency.sol";
import { PoolId, PoolIdLibrary } from "@uniswap/v4-core/src/types/PoolId.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { ModifyLiquidityParams, SwapParams } from "@uniswap/v4-core/src/types/PoolOperation.sol";
import { BalanceDelta } from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {
    BeforeSwapDelta, BeforeSwapDeltaLibrary, toBeforeSwapDelta
} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import { ISherwoodHook } from "./interfaces/ISherwoodHook.sol";
import { IRewardController } from "./interfaces/IRewardController.sol";
import { ISherwoodToken } from "./interfaces/ISherwoodToken.sol";
import { ISherwoodVault } from "./interfaces/ISherwoodVault.sol";
import { SherwoodBoard } from "./libraries/SherwoodBoard.sol";
import { SherwoodFee } from "./libraries/SherwoodFee.sol";
import { SherwoodGame } from "./libraries/SherwoodGame.sol";
import { SherwoodWeather } from "./libraries/SherwoodWeather.sol";
import {
    Arrow,
    ArrowTier,
    ExpiryResult,
    FeeAllocation,
    FeeComputation,
    GameConfig,
    PendingFee,
    ShotResult,
    VaultSettlement
} from "./types/SherwoodTypes.sol";

interface IMsgSender {
    function msgSender() external view returns (address);
}

contract SherwoodHook is ImmutableState, Ownable, ISherwoodHook {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;
    using SherwoodGame for SherwoodGame.State;
    using SherwoodWeather for SherwoodWeather.State;

    IPositionManager public immutable POSITION_MANAGER;
    ISherwoodToken public immutable TOKEN;
    ISherwoodVault public immutable VAULT;
    IRewardController public activeRewardController;
    IRewardController public pendingRewardController;
    uint64 public pendingRewardControllerActivationRound;
    uint16 internal constant INITIAL_PROTOCOL_FEE_BPS = 500;
    uint16 internal constant MIN_PROTOCOL_FEE_BPS = 100;

    address[] private trustedRouters;
    mapping(address router => uint256 indexPlusOne) private trustedRouterIndex;
    uint16 public protocolFeeBps;
    PoolId public registeredPoolId;
    bool public poolRegistered;
    SherwoodWeather.State private weather;
    SherwoodGame.State internal game;
    PendingFee internal _pendingFee;

    error ZeroAddress();
    error DependencyHasNoCode();
    error EmptyInitialTrustedRouters();
    error InvalidTrustedRouter(address router);
    error TrustedRouterAlreadyAdded(address router);
    error TrustedRouterNotFound(address router);
    error InvalidProtocolFeeDecrease(uint16 currentFeeBps, uint16 newFeeBps);
    error OnlyToken();
    error PoolAlreadyRegistered();
    error InvalidPoolKey();
    error PoolNotRegistered();
    error InvalidVaultBinding();
    error InvalidRewardControllerBinding();
    error ActiveRewardController();
    error RewardControllerAlreadyPending();
    error InvalidLaunchState();
    error InvalidLiquidityCallback();
    error PendingFeeMismatch();
    error InvalidTrustedRouteContext();
    error NativeReceiveRejected();

    event TrustedRouterAdded(address indexed router);
    event TrustedRouterRemoved(address indexed router);
    event ProtocolFeeDecreased(uint16 previousFeeBps, uint16 newFeeBps);
    event WeatherUpdated(
        uint256 indexed shotId, uint256 scoreBeforeWad, uint256 scoreAfterWad, uint16 maxWindSlots, bool successful
    );
    event PoolRegistered(PoolId indexed poolId);
    event ShotProcessed(
        uint256 indexed shotId,
        address indexed player,
        uint256 rawVolume,
        uint256 gameVolume,
        uint256 volumeProgress,
        uint32 previousBoardCursor,
        uint32 baseTip,
        uint32 finalTip,
        uint256 hitScoreWad,
        uint16 maxWindSlots,
        int16 windSlots,
        ArrowTier tier,
        uint16 radiusSlots,
        bool stuck,
        uint32 configVersion
    );
    event ArrowCreated(
        uint256 indexed arrowId,
        address indexed owner,
        uint32 tip,
        uint16 slot,
        uint64 createdRound,
        uint256 createdAtCursor,
        uint256 expiresAtCursor,
        uint16 radiusSlots,
        uint256 breakThreshold,
        uint256 bountyETH,
        ArrowTier tier,
        uint32 configVersion
    );
    event ArrowHit(
        uint256 indexed shotId,
        uint256 indexed arrowId,
        address indexed shooter,
        address owner,
        ArrowTier tier,
        uint256 bounty
    );
    event ArrowBlocked(uint256 indexed shotId, uint256 blockerCount);
    event ArrowExpired(uint256 indexed arrowId);
    event FeeAccrued(
        bool indexed isBuy, bool indexed isExactInput, uint256 feeAmount, uint256 rawShotVolume, uint256 arrowId
    );
    event FeeSettled(uint256 feeAmount, uint256 protocol, uint256 arrowEscrow, uint256 rewardReserve, uint256 arrowId);
    event RewardBonusAccrued(uint256 indexed shotId, address indexed controller, uint256 bonus);
    event RewardControllerScheduled(
        address indexed currentController, address indexed pendingController, uint64 indexed activationRound
    );
    event RewardControllerActivated(
        address indexed previousController, address indexed newController, uint64 indexed activationRound
    );
    event GameConfigScheduled(uint32 indexed version, uint64 indexed activationRound);
    event GameConfigCancelled(uint32 indexed version, uint64 indexed activationRound);
    event GameConfigActivated(uint32 indexed version, uint64 indexed activationRound);

    constructor(
        IPoolManager poolManager_,
        IPositionManager positionManager_,
        ISherwoodToken token_,
        address owner_,
        address[] memory initialTrustedRouters_,
        ISherwoodVault vault_,
        IRewardController initialRewardController_
    ) ImmutableState(poolManager_) Ownable(owner_) {
        _validateHookAddress(IHooks(address(this)));
        if (
            address(poolManager_) == address(0) || address(positionManager_) == address(0)
                || address(token_) == address(0) || owner_ == address(0) || address(vault_) == address(0)
                || address(initialRewardController_) == address(0)
        ) revert ZeroAddress();
        if (
            address(poolManager_).code.length == 0 || address(positionManager_).code.length == 0
                || address(token_).code.length == 0 || address(vault_).code.length == 0
                || address(initialRewardController_).code.length == 0
        ) revert DependencyHasNoCode();
        if (initialTrustedRouters_.length == 0) revert EmptyInitialTrustedRouters();

        POSITION_MANAGER = positionManager_;
        TOKEN = token_;
        VAULT = vault_;
        activeRewardController = initialRewardController_;
        protocolFeeBps = INITIAL_PROTOCOL_FEE_BPS;
        for (uint256 i; i < initialTrustedRouters_.length; ++i) {
            _addTrustedRouter(initialTrustedRouters_[i]);
        }
        game.initialize();
    }

    function addTrustedRouter(address router) external onlyOwner {
        _addTrustedRouter(router);
    }

    function decreaseProtocolFeeBps(uint16 newFeeBps) external onlyOwner {
        uint16 previousFeeBps = protocolFeeBps;
        if (newFeeBps < MIN_PROTOCOL_FEE_BPS || newFeeBps >= previousFeeBps) {
            revert InvalidProtocolFeeDecrease(previousFeeBps, newFeeBps);
        }
        protocolFeeBps = newFeeBps;
        emit ProtocolFeeDecreased(previousFeeBps, newFeeBps);
    }

    function removeTrustedRouter(address router) external onlyOwner {
        uint256 indexPlusOne = trustedRouterIndex[router];
        if (indexPlusOne == 0) revert TrustedRouterNotFound(router);

        uint256 index = indexPlusOne - 1;
        uint256 lastIndex = trustedRouters.length - 1;
        if (index != lastIndex) {
            address movedRouter = trustedRouters[lastIndex];
            trustedRouters[index] = movedRouter;
            trustedRouterIndex[movedRouter] = index + 1;
        }
        trustedRouters.pop();
        delete trustedRouterIndex[router];
        emit TrustedRouterRemoved(router);
    }

    function isTrustedRouter(address router) public view returns (bool) {
        return trustedRouterIndex[router] != 0;
    }

    function trustedRouterCount() external view returns (uint256) {
        return trustedRouters.length;
    }

    function trustedRouterAt(uint256 index) external view returns (address) {
        return trustedRouters[index];
    }

    function getHookPermissions() public pure returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: true,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    function registerPool(PoolKey calldata key) external returns (PoolId poolId) {
        if (msg.sender != address(TOKEN)) revert OnlyToken();
        if (poolRegistered) revert PoolAlreadyRegistered();
        if (!TOKEN.loadingLiquidity()) revert InvalidLaunchState();
        _validateKey(key);
        if (VAULT.hook() != address(this)) revert InvalidVaultBinding();
        if (activeRewardController.hook() != address(this)) revert InvalidRewardControllerBinding();
        poolId = key.toId();
        registeredPoolId = poolId;
        poolRegistered = true;
        emit PoolRegistered(poolId);
    }

    function scheduleGameConfig(GameConfig calldata config)
        external
        onlyOwner
        returns (uint32 version, uint64 activationRound)
    {
        (version, activationRound) = game.scheduleConfig(config);
        emit GameConfigScheduled(version, activationRound);
    }

    function cancelPendingGameConfig() external onlyOwner {
        (uint32 version, uint64 activationRound) = game.cancelConfig();
        emit GameConfigCancelled(version, activationRound);
    }

    function settleExpiredArrows(uint256[] calldata arrowIds) external {
        ExpiryResult[] memory results = game.settleExpiredArrows(arrowIds);
        VaultSettlement memory settlement;
        for (uint256 i; i < results.length; ++i) {
            settlement.expiryProtocol += results[i].protocol;
            settlement.expiryRewardReserve += results[i].rewardReserve;
        }
        VAULT.applySettlement(settlement);
        for (uint256 i; i < results.length; ++i) {
            ExpiryResult memory result = results[i];
            if (result.settled) emit ArrowExpired(result.arrowId);
        }
    }

    function scheduleRewardController(IRewardController next) external onlyOwner returns (uint64 activationRound) {
        if (address(next) == address(0)) revert ZeroAddress();
        if (address(next).code.length == 0) revert DependencyHasNoCode();
        if (next.hook() != address(this)) revert InvalidRewardControllerBinding();
        if (address(next) == address(activeRewardController)) revert ActiveRewardController();
        if (address(pendingRewardController) != address(0)) revert RewardControllerAlreadyPending();

        activationRound = SherwoodBoard.roundAt(game.volumeProgress) + 1;
        pendingRewardController = next;
        pendingRewardControllerActivationRound = activationRound;
        emit RewardControllerScheduled(address(activeRewardController), address(next), activationRound);
    }

    function arrow(uint256 arrowId) external view returns (Arrow memory) {
        return game.arrows[arrowId];
    }

    function gameConfig(uint32 version) external view returns (GameConfig memory) {
        return game.configs[version];
    }

    function volumeProgress() external view returns (uint256) {
        return game.volumeProgress;
    }

    function boardCursor() external view returns (uint32) {
        return game.boardCursor;
    }

    function weatherState() external view returns (uint256 hitScoreWad, uint64 lastUpdatedAt, uint16 maxWindSlots) {
        uint32 halfLife = game.activeConfig().weatherHalfLifeSeconds;
        hitScoreWad = weather.currentHitScore(block.timestamp, halfLife);
        lastUpdatedAt = weather.lastUpdatedAt;
        maxWindSlots = SherwoodWeather.maxWindSlots(hitScoreWad);
    }

    function activeConfigVersion() external view returns (uint32) {
        return game.activeConfigVersion;
    }

    function pendingGameConfig() external view returns (uint32 version, uint64 activationRound) {
        return (game.pendingConfigVersion, game.pendingActivationRound);
    }

    function beforeInitialize(address sender, PoolKey calldata key, uint160)
        external
        view
        onlyPoolManager
        returns (bytes4)
    {
        _validateLiquidityCallback(sender, key);
        return IHooks.beforeInitialize.selector;
    }

    function beforeAddLiquidity(address sender, PoolKey calldata key, ModifyLiquidityParams calldata, bytes calldata)
        external
        view
        onlyPoolManager
        returns (bytes4)
    {
        _validateLiquidityCallback(sender, key);
        return IHooks.beforeAddLiquidity.selector;
    }

    function beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        _validateSwap(key);
        _settlePendingFee(key.currency0);
        uint256 currentFee = SherwoodFee.beforeFee(params, protocolFeeBps);
        if (currentFee != 0) {
            poolManager.mint(address(this), key.currency0.toId(), currentFee);
            return (IHooks.beforeSwap.selector, toBeforeSwapDelta(SafeCast.toInt128(currentFee), 0), 0);
        }
        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    function afterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) external onlyPoolManager returns (bytes4, int128) {
        _validateSwap(key);
        FeeComputation memory fee = SherwoodFee.compute(params, delta, protocolFeeBps);
        bool chargedBefore = fee.isBuy == fee.isExactInput;
        if (!chargedBefore && fee.feeAmount != 0) {
            poolManager.mint(address(this), key.currency0.toId(), fee.feeAmount);
        }
        (bool eligible, address player) = _eligiblePlayer(sender, fee);
        FeeAllocation memory allocation;
        uint256 arrowId;

        if (eligible) {
            GameConfig storage config = game.activeConfig();
            uint256 scoreBeforeWad = weather.currentHitScore(block.timestamp, config.weatherHalfLifeSeconds);
            uint16 maximum = SherwoodWeather.maxWindSlots(scoreBeforeWad);
            ShotResult memory shot = game.processShot(
                player,
                fee.rawShotVolume,
                PoolId.unwrap(registeredPoolId),
                bytes32(block.prevrandao),
                scoreBeforeWad,
                maximum
            );
            bool successful = shot.hitIds.length != 0;
            uint256 scoreAfterWad = weather.checkpoint(scoreBeforeWad, block.timestamp, successful);
            (allocation, arrowId) = _settleShot(shot, fee.feeAmount);
            emit WeatherUpdated(shot.shotId, scoreBeforeWad, scoreAfterWad, maximum, successful);
            (bool activated, uint32 version, uint64 activationRound) = game.activatePendingConfigIfReady(shot.round);
            if (activated) emit GameConfigActivated(version, activationRound);
        } else {
            allocation = SherwoodFee.allocateFeeOnly(fee.feeAmount);
        }
        _storePendingFee(fee.feeAmount, allocation, arrowId);
        emit FeeAccrued(fee.isBuy, fee.isExactInput, fee.feeAmount, fee.rawShotVolume, arrowId);
        return (IHooks.afterSwap.selector, chargedBefore ? int128(0) : SafeCast.toInt128(fee.feeAmount));
    }

    function _validateHookAddress(IHooks self) internal pure virtual {
        Hooks.validateHookPermissions(self, getHookPermissions());
    }

    function _settlePendingFee(Currency nativeCurrency) private {
        PendingFee memory pending = _pendingFee;
        if (pending.amount == 0) return;
        delete _pendingFee;

        FeeAllocation memory allocation = pending.allocation;
        if (_allocationTotal(allocation) != pending.amount) revert PendingFeeMismatch();
        poolManager.burn(address(this), nativeCurrency.toId(), pending.amount);
        poolManager.take(nativeCurrency, address(this), pending.amount);

        VaultSettlement memory settlement;
        settlement.currentFee = allocation;
        VAULT.applySettlement{ value: pending.amount }(settlement);
        emit FeeSettled(
            pending.amount, allocation.protocol, allocation.arrowEscrow, allocation.rewardReserve, pending.arrowId
        );
    }

    function _eligiblePlayer(address sender, FeeComputation memory fee)
        private
        view
        returns (bool eligible, address player)
    {
        if (!fee.isBuy || fee.rawShotVolume < game.activeConfig().minShotVolume) {
            return (false, address(0));
        }
        if (!isTrustedRouter(sender)) return (false, address(0));
        try IMsgSender(sender).msgSender() returns (address locker) {
            if (locker == address(0)) revert InvalidTrustedRouteContext();
            return (true, locker);
        } catch {
            revert InvalidTrustedRouteContext();
        }
    }

    function _addTrustedRouter(address router) private {
        if (router == address(0) || router.code.length == 0) revert InvalidTrustedRouter(router);
        if (trustedRouterIndex[router] != 0) revert TrustedRouterAlreadyAdded(router);
        trustedRouters.push(router);
        trustedRouterIndex[router] = trustedRouters.length;
        emit TrustedRouterAdded(router);
    }

    function _settleShot(ShotResult memory shot, uint256 feeAmount)
        private
        returns (FeeAllocation memory allocation, uint256 arrowId)
    {
        VaultSettlement memory settlement;
        settlement.claimant = shot.player;
        settlement.bountyPayout = shot.bountyPayout;
        for (uint256 i; i < shot.expiryResults.length; ++i) {
            settlement.expiryProtocol += shot.expiryResults[i].protocol;
            settlement.expiryRewardReserve += shot.expiryResults[i].rewardReserve;
        }

        _activateRewardControllerIfReady(shot.round);
        bool successful = shot.hitIds.length != 0;
        uint256 availableRewardReserve = VAULT.rewardReserve() + settlement.expiryRewardReserve;
        settlement.reserveBonus = activeRewardController.recordShot(shot.round, successful, availableRewardReserve);

        VAULT.applySettlement(settlement);

        allocation = shot.stuck ? SherwoodFee.allocateStored(feeAmount) : SherwoodFee.allocateFeeOnly(feeAmount);
        if (shot.stuck) {
            arrowId = shot.stuckArrowId;
            game.fundArrowBounty(arrowId, allocation.arrowEscrow);
        }

        _emitShotEvents(shot);
        if (successful) {
            emit RewardBonusAccrued(shot.shotId, address(activeRewardController), settlement.reserveBonus);
        }
    }

    function _activateRewardControllerIfReady(uint64 shotRound) private {
        IRewardController pending = pendingRewardController;
        uint64 activationRound = pendingRewardControllerActivationRound;
        if (address(pending) == address(0) || shotRound < activationRound) return;

        IRewardController previous = activeRewardController;
        activeRewardController = pending;
        pendingRewardController = IRewardController(address(0));
        pendingRewardControllerActivationRound = 0;
        emit RewardControllerActivated(address(previous), address(pending), activationRound);
    }

    function _storePendingFee(uint256 amount, FeeAllocation memory allocation, uint256 arrowId) private {
        if (_allocationTotal(allocation) != amount) revert PendingFeeMismatch();
        if (amount == 0) return;
        if (_pendingFee.amount != 0) revert PendingFeeMismatch();
        _pendingFee = PendingFee({ amount: amount, allocation: allocation, arrowId: arrowId });
    }

    function _allocationTotal(FeeAllocation memory allocation) private pure returns (uint256) {
        return allocation.protocol + allocation.arrowEscrow + allocation.rewardReserve;
    }

    function _emitShotEvents(ShotResult memory shot) private {
        emit ShotProcessed(
            shot.shotId,
            shot.player,
            shot.rawVolume,
            shot.gameVolume,
            shot.volumeProgress,
            shot.previousBoardCursor,
            shot.baseTip,
            shot.tip,
            shot.hitScoreWad,
            shot.maxWindSlots,
            shot.windSlots,
            shot.tier,
            shot.radiusSlots,
            shot.stuck,
            shot.configVersion
        );
        for (uint256 i; i < shot.hitIds.length; ++i) {
            Arrow storage target = game.arrows[shot.hitIds[i]];
            emit ArrowHit(shot.shotId, target.id, shot.player, target.owner, target.tier, shot.hitBounties[i]);
        }
        if (shot.blockerCount != 0) emit ArrowBlocked(shot.shotId, shot.blockerCount);
        if (shot.stuck) {
            Arrow storage created = game.arrows[shot.stuckArrowId];
            emit ArrowCreated(
                created.id,
                created.owner,
                created.tip,
                created.slot,
                created.createdRound,
                created.createdAtCursor,
                created.expiresAtCursor,
                created.radiusSlots,
                created.breakThreshold,
                created.bountyETH,
                created.tier,
                created.configVersion
            );
        }
        for (uint256 i; i < shot.expiryResults.length; ++i) {
            ExpiryResult memory expiry = shot.expiryResults[i];
            emit ArrowExpired(expiry.arrowId);
        }
    }

    function _validateLiquidityCallback(address sender, PoolKey calldata key) private view {
        if (sender != address(POSITION_MANAGER) || !TOKEN.loadingLiquidity()) revert InvalidLiquidityCallback();
        _validateKey(key);
    }

    function _validateSwap(PoolKey calldata key) private view {
        if (!poolRegistered || PoolId.unwrap(key.toId()) != PoolId.unwrap(registeredPoolId)) {
            revert PoolNotRegistered();
        }
        _validateKey(key);
        if (TOKEN.launchState() != ISherwoodToken.LaunchState.Launched) revert InvalidLaunchState();
    }

    function _validateKey(PoolKey calldata key) private view {
        if (
            Currency.unwrap(key.currency0) != address(0) || Currency.unwrap(key.currency1) != address(TOKEN)
                || key.fee != 0 || key.tickSpacing != TOKEN.TICK_SPACING() || address(key.hooks) != address(this)
        ) revert InvalidPoolKey();
    }

    receive() external payable {
        if (msg.sender != address(poolManager)) revert NativeReceiveRejected();
    }
}
