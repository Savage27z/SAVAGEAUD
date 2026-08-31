// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

//
//                         ,(
//                        ((
//                         \\
//                     .---\\---.
//                    /    ``    \
//                   |            |
//                   |            |
//                    \          /
//                     '.______.'
//
//              O R C H A R D  ·  $SEED
//             Plant ETH. Harvest $AAPL.
//
//                https://orchard.gold
//            https://x.com/orcharddotgold
//

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {ISwapper} from "./interfaces/ISwapper.sol";
import {IUniswapV2Router} from "./interfaces/IUniswapV2Router.sol";

contract SeedSwapper is ISwapper, IUnlockCallback {
    using SafeERC20 for IERC20;

    error NotPoolManager();
    error InsufficientOutput();
    error InvalidPoolKey();
    error EthPathDisabled();
    error ZeroAddress();

    enum Route {
        UsdgToAapl,
        AaplToUsdg
    }

    IPoolManager public immutable manager;
    IERC20 public immutable seed;
    IERC20 public immutable usdg;
    IERC20 public immutable aapl;
    IUniswapV2Router public immutable v2Router;
    address public immutable weth;

    bool public immutable usdgIsZeroB;
    uint24 public immutable feeB;
    int24 public immutable tickSpacingB;
    IHooks public immutable hooksB;

    constructor(
        IPoolManager manager_,
        IERC20 seed_,
        IERC20 usdg_,
        IERC20 aapl_,
        PoolKey memory keyB,
        IUniswapV2Router v2Router_,
        address weth_
    ) {
        if (
            address(manager_) == address(0) || address(seed_) == address(0) || address(usdg_) == address(0)
                || address(aapl_) == address(0)
        ) revert ZeroAddress();
        if (address(v2Router_) != address(0) && weth_ == address(0)) revert ZeroAddress();
        manager = manager_;
        seed = seed_;
        usdg = usdg_;
        aapl = aapl_;
        v2Router = v2Router_;
        weth = weth_;

        (address b0, address b1) = (Currency.unwrap(keyB.currency0), Currency.unwrap(keyB.currency1));
        if (b0 == address(usdg_) && b1 == address(aapl_)) usdgIsZeroB = true;
        else if (b0 == address(aapl_) && b1 == address(usdg_)) usdgIsZeroB = false;
        else revert InvalidPoolKey();
        feeB = keyB.fee;
        tickSpacingB = keyB.tickSpacing;
        hooksB = keyB.hooks;
    }

    function poolKeyB() public view returns (PoolKey memory) {
        (Currency c0, Currency c1) = usdgIsZeroB
            ? (Currency.wrap(address(usdg)), Currency.wrap(address(aapl)))
            : (Currency.wrap(address(aapl)), Currency.wrap(address(usdg)));
        return PoolKey({currency0: c0, currency1: c1, fee: feeB, tickSpacing: tickSpacingB, hooks: hooksB});
    }

    function swapAaplForSeed(uint256 aaplIn, uint256 minOut) external returns (uint256 bought) {
        if (address(v2Router) == address(0)) revert EthPathDisabled();
        aapl.safeTransferFrom(msg.sender, address(this), aaplIn);
        uint256 usdgOut = _unlock(Route.AaplToUsdg, aaplIn, 0, address(this));

        address[] memory path = new address[](3);
        path[0] = address(usdg);
        path[1] = weth;
        path[2] = address(seed);
        usdg.forceApprove(address(v2Router), usdgOut);
        uint256 balanceBefore = seed.balanceOf(msg.sender);
        v2Router.swapExactTokensForTokensSupportingFeeOnTransferTokens(usdgOut, 0, path, msg.sender, block.timestamp);
        bought = seed.balanceOf(msg.sender) - balanceBefore;
        if (bought < minOut) revert InsufficientOutput();
    }

    function swapAaplForEth(uint256 aaplIn, uint256 minOut) external returns (uint256 ethOut) {
        if (address(v2Router) == address(0)) revert EthPathDisabled();
        aapl.safeTransferFrom(msg.sender, address(this), aaplIn);
        uint256 usdgOut = _unlock(Route.AaplToUsdg, aaplIn, 0, address(this));

        address[] memory path = new address[](2);
        path[0] = address(usdg);
        path[1] = weth;
        usdg.forceApprove(address(v2Router), usdgOut);
        uint256 balanceBefore = msg.sender.balance;
        v2Router.swapExactTokensForETH(usdgOut, minOut, path, msg.sender, block.timestamp);
        ethOut = msg.sender.balance - balanceBefore;
        if (ethOut < minOut) revert InsufficientOutput();
    }

    function swapSeedForEth(uint256 seedIn, uint256 minOut) external returns (uint256 ethOut) {
        if (address(v2Router) == address(0)) revert EthPathDisabled();
        uint256 seedBefore = seed.balanceOf(address(this));
        seed.safeTransferFrom(msg.sender, address(this), seedIn);
        uint256 pulled = seed.balanceOf(address(this)) - seedBefore;

        address[] memory path = new address[](2);
        path[0] = address(seed);
        path[1] = weth;
        seed.forceApprove(address(v2Router), pulled);
        uint256 balanceBefore = msg.sender.balance;
        v2Router.swapExactTokensForETHSupportingFeeOnTransferTokens(pulled, 0, path, msg.sender, block.timestamp);
        ethOut = msg.sender.balance - balanceBefore;
        if (ethOut < minOut) revert InsufficientOutput();
    }

    function swapSeedForAapl(uint256 seedIn, uint256 minOut) external returns (uint256 bought) {
        if (address(v2Router) == address(0)) revert EthPathDisabled();
        uint256 seedBefore = seed.balanceOf(address(this));
        seed.safeTransferFrom(msg.sender, address(this), seedIn);
        uint256 pulled = seed.balanceOf(address(this)) - seedBefore;

        address[] memory path = new address[](3);
        path[0] = address(seed);
        path[1] = weth;
        path[2] = address(usdg);
        seed.forceApprove(address(v2Router), pulled);
        uint256 usdgBefore = usdg.balanceOf(address(this));
        v2Router.swapExactTokensForTokensSupportingFeeOnTransferTokens(pulled, 0, path, address(this), block.timestamp);
        uint256 usdgOut = usdg.balanceOf(address(this)) - usdgBefore;

        bought = _unlock(Route.UsdgToAapl, usdgOut, minOut, msg.sender);
    }

    function swapEthForAapl(uint256 minOut) external payable returns (uint256 bought) {
        bought = _unlock(Route.UsdgToAapl, _ethToUsdg(), minOut, msg.sender);
    }

    function swapEthForSeed(uint256 minOut) external payable returns (uint256 bought) {
        if (address(v2Router) == address(0)) revert EthPathDisabled();
        address[] memory path = new address[](2);
        path[0] = weth;
        path[1] = address(seed);
        uint256 balanceBefore = seed.balanceOf(msg.sender);
        v2Router.swapExactETHForTokensSupportingFeeOnTransferTokens{
            value: msg.value
        }(0, path, msg.sender, block.timestamp);
        bought = seed.balanceOf(msg.sender) - balanceBefore;
        if (bought < minOut) revert InsufficientOutput();
    }

    function _ethToUsdg() private returns (uint256 usdgIn) {
        if (address(v2Router) == address(0)) revert EthPathDisabled();
        address[] memory path = new address[](2);
        path[0] = weth;
        path[1] = address(usdg);
        uint256 usdgBefore = usdg.balanceOf(address(this));
        v2Router.swapExactETHForTokens{value: msg.value}(0, path, address(this), block.timestamp);
        usdgIn = usdg.balanceOf(address(this)) - usdgBefore;
    }

    function _unlock(Route route, uint256 amountIn, uint256 minOut, address recipient)
        private
        returns (uint256 bought)
    {
        bought = abi.decode(manager.unlock(abi.encode(route, amountIn, minOut, recipient)), (uint256));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(manager)) revert NotPoolManager();
        (Route route, uint256 amountIn, uint256 minOut, address recipient) =
            abi.decode(data, (Route, uint256, uint256, address));

        IERC20 tokenIn;
        IERC20 tokenOut;
        bool zeroForOne;
        if (route == Route.UsdgToAapl) {
            (tokenIn, tokenOut, zeroForOne) = (usdg, aapl, usdgIsZeroB);
        } else {
            (tokenIn, tokenOut, zeroForOne) = (aapl, usdg, !usdgIsZeroB);
        }
        uint256 bought = _exactIn(poolKeyB(), zeroForOne, amountIn);
        if (bought < minOut) revert InsufficientOutput();

        manager.sync(Currency.wrap(address(tokenIn)));
        tokenIn.safeTransfer(address(manager), amountIn);
        manager.settle();
        manager.take(Currency.wrap(address(tokenOut)), recipient, bought);
        return abi.encode(bought);
    }

    function _exactIn(PoolKey memory key, bool zeroForOne, uint256 amountIn) private returns (uint256 amountOut) {
        BalanceDelta delta = manager.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                // forge-lint: disable-next-line(unsafe-typecast)
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            ""
        );
        amountOut = uint256(uint128(zeroForOne ? delta.amount1() : delta.amount0()));
    }
}
