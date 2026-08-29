// SPDX-License-Identifier: MIT
//https://deadeye.garden/
pragma solidity 0.8.29;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { IHooks } from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import { Currency, CurrencyLibrary } from "@uniswap/v4-core/src/types/Currency.sol";
import { PoolId, PoolIdLibrary } from "@uniswap/v4-core/src/types/PoolId.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { TickMath } from "@uniswap/v4-core/src/libraries/TickMath.sol";
import { IPositionManager } from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import { IPoolInitializer_v4 } from "@uniswap/v4-periphery/src/interfaces/IPoolInitializer_v4.sol";
import { Actions } from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import { LiquidityAmounts } from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import { IAllowanceTransfer } from "@uniswap/permit2/src/interfaces/IAllowanceTransfer.sol";
import { ISherwoodHook } from "./interfaces/ISherwoodHook.sol";
import { ISherwoodToken } from "./interfaces/ISherwoodToken.sol";
import { SherwoodLaunchMath } from "./libraries/SherwoodLaunchMath.sol";

contract SherwoodToken is ERC20, Ownable, ISherwoodToken {
    using PoolIdLibrary for PoolKey;

    uint256 public constant INITIAL_SUPPLY = 1_000_000_000 ether;
    uint256 public constant LOAD_LIQUIDITY_ETH = 2 wei;
    address public constant DEAD_POSITION_OWNER = 0x000000000000000000000000000000000000dEaD;

    IPositionManager public immutable POSITION_MANAGER;
    IAllowanceTransfer public immutable PERMIT2;
    IPoolManager public immutable POOL_MANAGER;
    int24 public immutable TICK_SPACING;
    uint160 public immutable STARTING_SQRT_PRICE_X96;
    int24 public immutable STARTING_TICK;
    int24 public immutable TICK_LOWER;
    int24 public immutable TICK_UPPER;

    LaunchState public launchState;
    bool public loadingLiquidity;
    address public hookAddress;
    PoolId public registeredPoolId;
    PoolKey private _poolKey;

    error ZeroAddress();
    error DependencyHasNoCode();
    error InvalidLaunchState();
    error WrongEthAmount();
    error InvalidRegisteredPool();
    error TradingNotStarted();

    event LiquidityLoaded(address indexed hook, PoolId indexed poolId, uint128 liquidity);
    event Launched(uint256 timestamp);

    constructor(
        address owner_,
        string memory name_,
        string memory symbol_,
        IPositionManager positionManager_,
        IAllowanceTransfer permit2_,
        IPoolManager poolManager_,
        int24 tickSpacing_,
        uint256 targetFdvETH_
    ) ERC20(name_, symbol_) Ownable(owner_) {
        if (
            owner_ == address(0) || address(positionManager_) == address(0) || address(permit2_) == address(0)
                || address(poolManager_) == address(0)
        ) revert ZeroAddress();
        if (
            address(positionManager_).code.length == 0 || address(permit2_).code.length == 0
                || address(poolManager_).code.length == 0
        ) revert DependencyHasNoCode();

        POSITION_MANAGER = positionManager_;
        PERMIT2 = permit2_;
        POOL_MANAGER = poolManager_;
        TICK_SPACING = tickSpacing_;
        (STARTING_SQRT_PRICE_X96, STARTING_TICK, TICK_LOWER, TICK_UPPER) =
            SherwoodLaunchMath.derive(INITIAL_SUPPLY, targetFdvETH_, tickSpacing_);
        _mint(address(this), INITIAL_SUPPLY);
    }

    function getPoolKey() external view returns (PoolKey memory) {
        return _poolKey;
    }

    function loadLiquidity(address hook) external payable onlyOwner {
        if (launchState != LaunchState.Deployed) revert InvalidLaunchState();
        if (hook == address(0)) revert ZeroAddress();
        if (hook.code.length == 0) revert DependencyHasNoCode();
        if (msg.value != LOAD_LIQUIDITY_ETH) revert WrongEthAmount();

        loadingLiquidity = true;
        hookAddress = hook;
        PoolKey memory key = PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO,
            currency1: Currency.wrap(address(this)),
            fee: 0,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(hook)
        });
        _poolKey = key;

        uint128 liquidity = LiquidityAmounts.getLiquidityForAmount1(
            TickMath.getSqrtPriceAtTick(TICK_LOWER), TickMath.getSqrtPriceAtTick(TICK_UPPER), INITIAL_SUPPLY
        );

        _approve(address(this), address(PERMIT2), INITIAL_SUPPLY);
        PERMIT2.approve(address(this), address(POSITION_MANAGER), uint160(INITIAL_SUPPLY), type(uint48).max);

        bytes memory actions = abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(
            key,
            TICK_LOWER,
            TICK_UPPER,
            liquidity,
            uint128(LOAD_LIQUIDITY_ETH),
            uint128(INITIAL_SUPPLY),
            DEAD_POSITION_OWNER,
            bytes("")
        );
        params[1] = abi.encode(key.currency0, key.currency1);

        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(IPoolInitializer_v4.initializePool, (key, STARTING_SQRT_PRICE_X96));
        calls[1] =
            abi.encodeCall(IPositionManager.modifyLiquidities, (abi.encode(actions, params), block.timestamp + 60));
        POSITION_MANAGER.multicall{ value: LOAD_LIQUIDITY_ETH }(calls);

        PoolId expected = key.toId();
        PoolId registered = ISherwoodHook(hook).registerPool(key);
        if (PoolId.unwrap(registered) != PoolId.unwrap(expected)) revert InvalidRegisteredPool();

        registeredPoolId = registered;
        loadingLiquidity = false;
        launchState = LaunchState.LiquidityLoaded;
        emit LiquidityLoaded(hook, registered, liquidity);
    }

    function launch() external onlyOwner {
        if (launchState != LaunchState.LiquidityLoaded || hookAddress == address(0)) revert InvalidLaunchState();
        if (PoolId.unwrap(registeredPoolId) != PoolId.unwrap(_poolKey.toId())) revert InvalidRegisteredPool();
        launchState = LaunchState.Launched;
        emit Launched(block.timestamp);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && launchState != LaunchState.Launched) {
            bool positionManagerSettlement = loadingLiquidity && from == address(this)
                && _msgSender() == address(PERMIT2) && to == address(POOL_MANAGER);
            if (!positionManagerSettlement) revert TradingNotStarted();
        }
        super._update(from, to, value);
    }
}
