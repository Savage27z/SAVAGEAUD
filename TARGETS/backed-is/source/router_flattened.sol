// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// Public buy/sell router for the BACKED/ETH Uniswap v4 pool — the standard Uniswap UI won't route an
/// un-allowlisted hook, so backed.is calls this directly. Immutable pool key baked in at construction.
/// Stateless (holds no funds between calls); the 3% hook tax is charged inside the swap as usual.
contract BackedRouter is IUnlockCallback {
    using SafeERC20 for IERC20;

    IPoolManager public immutable pm;
    address public immutable token; // BACKED = currency1
    uint24 public immutable fee;
    int24 public immutable tickSpacing;
    address public immutable hooks;

    error Slippage(uint256 out, uint256 minOut);
    error OnlyPM();

    constructor(IPoolManager _pm, address _token, uint24 _fee, int24 _tickSpacing, address _hooks) {
        pm = _pm;
        token = _token;
        fee = _fee;
        tickSpacing = _tickSpacing;
        hooks = _hooks;
    }

    function poolKey() public view returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(token),
            fee: fee,
            tickSpacing: tickSpacing,
            hooks: IHooks(hooks)
        });
    }

    /// Buy BACKED with native ETH (send it as msg.value). BACKED goes to msg.sender.
    function buy(uint256 minOut) external payable returns (uint256 out) {
        out = abi.decode(pm.unlock(abi.encode(true, msg.sender, int256(msg.value), minOut)), (uint256));
    }

    /// Sell `amountIn` BACKED for ETH (approve this router first). ETH goes to msg.sender.
    function sell(uint256 amountIn, uint256 minOut) external returns (uint256 out) {
        IERC20(token).safeTransferFrom(msg.sender, address(this), amountIn);
        out = abi.decode(pm.unlock(abi.encode(false, msg.sender, int256(amountIn), minOut)), (uint256));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(pm)) revert OnlyPM();
        (bool isBuy, address user, int256 amountIn, uint256 minOut) = abi.decode(data, (bool, address, int256, uint256));
        PoolKey memory key = poolKey();
        uint160 limit = isBuy ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;

        BalanceDelta delta = pm.swap(key, SwapParams({zeroForOne: isBuy, amountSpecified: -amountIn, sqrtPriceLimitX96: limit}), "");
        uint256 out;
        if (isBuy) {
            pm.settle{value: uint256(uint128(-delta.amount0()))}(); // pay ETH in (from msg.value)
            out = uint256(uint128(delta.amount1()));
            if (out < minOut) revert Slippage(out, minOut);
            pm.take(key.currency1, user, out); // BACKED to user
        } else {
            pm.sync(key.currency1);
            IERC20(token).safeTransfer(address(pm), uint256(uint128(-delta.amount1()))); // pay BACKED in
            pm.settle();
            out = uint256(uint128(delta.amount0()));
            if (out < minOut) revert Slippage(out, minOut);
            pm.take(key.currency0, user, out); // ETH to user
        }
        return abi.encode(out);
    }

    receive() external payable {}
}