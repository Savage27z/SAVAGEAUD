// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";

/// Accumulates the native-ETH taxes IndexFeeHook sends here, and on keeper call splits
/// the pot equally across the registered tokenized stocks, buying each through its
/// Uniswap v4 native-ETH pool (e.g. TSLA/ETH). Bought stock goes straight to the
/// StockDistributor.
/// ponytail: ETH-quoted v4 pools only — the only live stock liquidity today; add a USDG leg when needed.
contract StockTreasury is Ownable, IUnlockCallback {
    IPoolManager public immutable poolManager;

    address public distributor;
    mapping(address => bool) public keeper; // trusted callers who supply minOuts

    struct Stock {
        address token;
        uint24 fee;
        int24 tickSpacing;
        address hooks;
    }

    Stock[] public stocks;

    event StockAdded(address indexed token, uint24 fee, int24 tickSpacing, address hooks);
    event StockRemoved(address indexed token);
    event StocksBought(uint256 ethSpent, uint256 stockCount);

    error OnlyKeeper();
    error OnlyPoolManager();
    error NoStocks();
    error NothingToSpend();
    error LengthMismatch();
    error Slippage(uint256 i, uint256 out, uint256 minOut);

    constructor(IPoolManager _pm, address owner_) Ownable(owner_) {
        poolManager = _pm;
    }

    function setDistributor(address d) external onlyOwner { distributor = d; }
    function setKeeper(address k, bool on) external onlyOwner { keeper[k] = on; }

    function addStock(address token, uint24 fee, int24 tickSpacing, address hooks) external onlyOwner {
        stocks.push(Stock(token, fee, tickSpacing, hooks));
        emit StockAdded(token, fee, tickSpacing, hooks);
    }

    function removeStock(uint256 i) external onlyOwner {
        emit StockRemoved(stocks[i].token);
        stocks[i] = stocks[stocks.length - 1];
        stocks.pop();
    }

    function stocksLength() external view returns (uint256) { return stocks.length; }
    function stockTokenAt(uint256 i) external view returns (address) { return stocks[i].token; }

    /// Buy each registered stock with an equal slice of the held ETH.
    /// Keeper-gated because the caller chooses minOuts (slippage protection).
    function buyStocks(uint256[] calldata minOuts) external {
        if (!keeper[msg.sender] && msg.sender != owner()) revert OnlyKeeper();
        uint256 n = stocks.length;
        if (n == 0) revert NoStocks();
        if (minOuts.length != n) revert LengthMismatch();

        uint256 per = address(this).balance / n;
        if (per == 0) revert NothingToSpend();

        poolManager.unlock(abi.encode(per, minOuts));
        emit StocksBought(per * n, n);
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert OnlyPoolManager();
        (uint256 per, uint256[] memory minOuts) = abi.decode(data, (uint256, uint256[]));

        for (uint256 i; i < stocks.length; ++i) {
            Stock memory s = stocks[i];
            PoolKey memory key = PoolKey({
                currency0: Currency.wrap(address(0)), // native ETH always sorts first
                currency1: Currency.wrap(s.token),
                fee: s.fee,
                tickSpacing: s.tickSpacing,
                hooks: IHooks(s.hooks)
            });
            BalanceDelta delta = poolManager.swap(
                key,
                SwapParams({
                    zeroForOne: true,
                    amountSpecified: -int256(per), // exact input
                    sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
                }),
                ""
            );
            uint256 out = uint256(uint128(delta.amount1()));
            if (out < minOuts[i]) revert Slippage(i, out, minOuts[i]);
            poolManager.settle{value: per}();
            poolManager.take(Currency.wrap(s.token), distributor, out);
        }
        return "";
    }

    receive() external payable {} // taxes arrive as native ETH from the hook
}
