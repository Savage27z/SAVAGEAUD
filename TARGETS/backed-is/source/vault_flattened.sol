// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";

/// Minimal view of $BACKED used for redemption.
interface IBackedToken {
    function totalSupply() external view returns (uint256);
    function burnFrom(address account, uint256 amount) external;
}

/// Rialto Router Registry — resolves the live settlement router for a feature id.
/// On Robinhood Chain: registry 0x71a120CbBf3Ce7cD910a3c50fF77aFc62735687E, featureId 2 = taker-submitted.
interface IRialtoRegistry {
    function ownerOf(uint256 featureId) external view returns (address);
}

/// ┌─────────────────────────────────────────────────────────────────────────────────────────────┐
/// │  StockVault — the reserve that makes $BACKED impossible to zero.                              │
/// └─────────────────────────────────────────────────────────────────────────────────────────────┘
///
/// Accumulates the native-ETH 3% tax that BackedFeeHook forwards here, and on keeper call spends it
/// buying tokenized real stocks (TSLA/ETH, NVDA/ETH, … v4 pools) that STAY in this vault as backing.
/// Unlike The Index, nothing is ever pushed out to holders — value accrues to the vault, so every
/// $BACKED token is a claim on a growing basket of real equities.
///
/// The floor: `redeem(amount)` burns your tokens and pays your pro-rata slice of the WHOLE vault —
/// every stock AND the pending (not-yet-invested) ETH — in-kind, minus a redemption fee that stays
/// behind and lifts the backing of everyone who stays. No oracle, no counterparty, no owner switch.
///
/// TRUST MODEL — deliberately no rug surface:
///   • There is NO owner/keeper path to withdraw stocks or ETH. The ONLY ETH exit is buying stocks;
///     the ONLY stock/ETH exit is a holder's own redeem(). The owner cannot drain the reserve.
///   • The keeper only supplies `minOuts` (slippage floors) for buys; it can grief its own buy
///     within that floor but can never reach the reserve or move funds off pro-rata.
///   • redemptionFeeBps is capped, so the owner cannot set a confiscatory exit fee.
contract StockVault is Ownable, ReentrancyGuard, IUnlockCallback {
    using SafeERC20 for IERC20;

    IPoolManager public immutable poolManager;
    IBackedToken public immutable token;

    // Rialto RFQ execution (primary buy route; v4 is the fallback). Immutable trust anchors: the keeper
    // can never inject the router — it is always resolved on-chain from this registry. registry == 0
    // disables the Rialto path entirely (v4-only deployment).
    address public immutable rialtoRegistry;
    uint256 public immutable rialtoFeatureId; // 2 = standard taker-submitted swap flows

    struct Stock {
        address token;
        uint24 fee;
        int24 tickSpacing;
        address hooks;
    }

    Stock[] public stocks; // active BUY list (buyStocks spends an equal ETH slice across these)
    mapping(address => bool) public keeper;

    // Redemption set: append-only union of EVERY token ever registered. redeem()/reserves() pay out
    // over THIS, not `stocks` — so delisting a stock via removeStock can never strand its held balance
    // (the balance stays fully redeemable). A token fully redeemed to 0 just contributes nothing.
    address[] private _redeemable;
    mapping(address => bool) public isRedeemable;

    uint256 internal constant BPS = 10_000;
    uint256 public constant MAX_REDEMPTION_FEE_BPS = 1_000; // owner-settable fee can never exceed 10%
    uint256 public redemptionFeeBps = 500; // 5%, retained in the vault → accretive to remaining holders

    // Per-stock ETH cap on a single buy. 0 = uncapped. Set it to bound a compromised keeper's blast
    // radius to (maxSpendPerBuy × stocks) per tx; the rest of the pending ETH rolls to the next cycle.
    uint256 public maxSpendPerBuy;

    event StockAdded(address indexed token, uint24 fee, int24 tickSpacing, address hooks);
    event StockRemoved(address indexed token);
    event RedeemablePruned(address indexed token);
    event KeeperSet(address indexed keeper, bool on);
    event RedemptionFeeSet(uint256 bps);
    event MaxSpendPerBuySet(uint256 v);
    event StocksBought(uint256 ethSpent, uint256 stockCount);
    event RialtoBought(uint256 indexed stockIndex, address indexed router, uint256 ethSpent, uint256 out);
    event RialtoBuyFailed(uint256 indexed stockIndex, bytes reason);
    event Redeemed(address indexed holder, uint256 amountBurned, uint256 ethPaid);
    event RedeemSkipped(address indexed stock, address indexed holder, uint256 amount);

    error OnlyKeeper();
    error OnlyPoolManager();
    error NoStocks();
    error NothingToSpend();
    error LengthMismatch();
    error Slippage(uint256 i, uint256 out, uint256 minOut);
    error ZeroAddress();
    error DuplicateStock();
    error BadAmount();
    error FeeTooHigh();
    error EthTransferFailed();
    error OnlySelf();
    error UnsafeRouter(address router);

    modifier onlyKeeper() {
        if (!keeper[msg.sender] && msg.sender != owner()) revert OnlyKeeper();
        _;
    }

    constructor(IPoolManager pm, IBackedToken token_, address owner_, address rialtoRegistry_, uint256 rialtoFeatureId_)
        Ownable(owner_)
    {
        if (address(pm) == address(0) || address(token_) == address(0)) revert ZeroAddress();
        poolManager = pm;
        token = token_;
        rialtoRegistry = rialtoRegistry_; // 0 = Rialto disabled (v4-only)
        rialtoFeatureId = rialtoFeatureId_;
    }

    // ── redemption: the hard floor ────────────────────────────────────────────────────────────────

    /// Burn `amount` $BACKED and receive your pro-rata slice of the entire vault (pending ETH + every
    /// stock), minus the redemption fee that stays behind. Requires an allowance to this vault.
    ///
    /// A regulated stock that refuses to transfer to the caller (allowlist / KYC gate) is SKIPPED, not
    /// reverted — one blocked leg can never brick a redemption. The skipped slice stays in the vault
    /// (forfeited to remaining holders); the frontend's previewRedeem warns before you sign.
    function redeem(uint256 amount) external nonReentrant {
        _redeem(amount, msg.sender);
    }

    /// Same as redeem(), but sends the underlying to `to`. Lets a contract/multisig holder that can't
    /// receive ETH (the ETH leg reverts on a failed send) still redeem, by paying out to an EOA.
    function redeemTo(uint256 amount, address to) external nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        _redeem(amount, to);
    }

    function _redeem(uint256 amount, address to) private {
        if (amount == 0) revert BadAmount();
        uint256 ts = token.totalSupply(); // share basis, captured before the burn
        if (ts == 0) revert BadAmount();

        uint256 feeBps = redemptionFeeBps;

        // Effects: burn first (pulls allowance from the caller), so the pro-rata math and every payout
        // below is against a supply the caller no longer counts toward.
        token.burnFrom(msg.sender, amount);

        // Pending-ETH slice (backing exists from the very first tax, before any stock is bought).
        uint256 ethNet = (address(this).balance * amount * (BPS - feeBps)) / (ts * BPS);
        if (ethNet != 0) {
            (bool ok,) = payable(to).call{value: ethNet}("");
            if (!ok) revert EthTransferFailed();
        }

        // Stock slices, in-kind — over the redemption set, so delisted-but-held stock still pays out.
        uint256 n = _redeemable.length;
        for (uint256 k; k < n; ++k) {
            address stk = _redeemable[k];
            uint256 bal = _safeBalanceOf(stk);
            uint256 net = (bal * amount * (BPS - feeBps)) / (ts * BPS);
            if (net != 0) _trySend(stk, to, net);
        }

        emit Redeemed(msg.sender, amount, ethNet);
    }

    /// What `redeem(amount)` would pay out right now: pending-ETH slice + net stock amount per stock.
    /// Pure view for the UI and for arbitrageurs pricing the floor.
    function previewRedeem(uint256 amount)
        external
        view
        returns (uint256 ethOut, address[] memory tokens, uint256[] memory amounts)
    {
        uint256 ts = token.totalSupply();
        uint256 n = _redeemable.length;
        tokens = new address[](n);
        amounts = new uint256[](n);
        if (ts == 0) return (0, tokens, amounts);
        uint256 feeBps = redemptionFeeBps;

        ethOut = (address(this).balance * amount * (BPS - feeBps)) / (ts * BPS);
        for (uint256 k; k < n; ++k) {
            address stk = _redeemable[k];
            tokens[k] = stk;
            uint256 bal = _safeBalanceOf(stk);
            amounts[k] = (bal * amount * (BPS - feeBps)) / (ts * BPS);
        }
    }

    /// Non-reverting stock transfer (SafeTransferLib-style, returndata-bomb-proof). A stock that
    /// reverts / returns false / returns a malformed value is treated as unpaid and skipped — never
    /// allowed to brick the redemption. Copied in spirit from The Index's _trySend.
    function _trySend(address tok, address to, uint256 amt) private {
        bytes memory payload = abi.encodeCall(IERC20.transfer, (to, amt));
        bool paid;
        assembly {
            let ok := call(gas(), tok, 0, add(payload, 0x20), mload(payload), 0x00, 0x20)
            let rds := returndatasize()
            paid := and(ok, or(iszero(rds), and(iszero(lt(rds, 32)), iszero(iszero(mload(0x00))))))
        }
        if (!paid) emit RedeemSkipped(tok, to, amt);
    }

    /// balanceOf that cannot brick redemption: a token whose balanceOf reverts, returns malformed data,
    /// or returndata-bombs yields 0 (its leg pays nothing this redemption) instead of reverting the whole
    /// call. Same 32-byte returndata cap as _trySend. Copied from The Index's _safeBalanceOf.
    function _safeBalanceOf(address tok) private view returns (uint256 bal) {
        bytes memory payload = abi.encodeCall(IERC20.balanceOf, (address(this)));
        assembly {
            let ok := staticcall(gas(), tok, add(payload, 0x20), mload(payload), 0x00, 0x20)
            if and(ok, iszero(lt(returndatasize(), 32))) { bal := mload(0x00) }
        }
    }

    // ── buying: turn accumulated ETH tax into stock backing ───────────────────────────────────────

    /// Spend an equal slice of the held ETH buying each registered stock on its native-ETH v4 pool.
    /// Bought stock stays HERE (the backing), it is not distributed. Keeper-gated because the caller
    /// chooses `minOuts` (slippage protection). No amount discretion beyond that: the slice is
    /// deterministically balance/n.
    function buyStocks(uint256[] calldata minOuts) external nonReentrant onlyKeeper {
        uint256 n = stocks.length;
        if (n == 0) revert NoStocks();
        if (minOuts.length != n) revert LengthMismatch();

        uint256 per = address(this).balance / n;
        uint256 cap = maxSpendPerBuy;
        if (cap != 0 && per > cap) per = cap; // bound keeper-compromise blast radius; remainder rolls over
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
                SwapParams({zeroForOne: true, amountSpecified: -int256(per), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
                ""
            );
            uint256 out = uint256(uint128(delta.amount1()));
            if (out < minOuts[i]) revert Slippage(i, out, minOuts[i]);
            poolManager.settle{value: per}();
            poolManager.take(Currency.wrap(s.token), address(this), out); // <-- stays in the vault
        }
        return "";
    }

    // ── Rialto RFQ buys (primary route; the v4 buyStocks above is the fallback) ────────────────────

    /// One keeper order: buy stock `stockIndex` by selling `ethAmount` of native ETH through the Rialto
    /// router using the API-supplied `data`. `minOut` is the slippage floor on the stock received.
    struct RialtoBuy {
        uint256 stockIndex;
        uint256 ethAmount;
        uint256 minOut;
        bytes data;
    }

    /// Keeper batch buy via Rialto RFQ. Each order runs in an isolated try/catch self-call, so one
    /// stale/unavailable quote is skipped (emits RialtoBuyFailed) while the others still settle. Route
    /// any skipped stock through the v4 `buyStocks` fallback.
    ///
    /// Native-ETH sells (allowance / taker-submitted mode) need NO token approval and NO Permit2
    /// signature — the router is paid via msg.value. Combined with on-chain router resolution and the
    /// measured-delta check, a fully-compromised keeper can only price-grief a buy within its own
    /// `minOut`, spending at most `ethAmount` (≤ maxSpendPerBuy) — never reach the reserve.
    function buyStocksRialto(RialtoBuy[] calldata orders) external nonReentrant onlyKeeper {
        address router = _resolveRouter(); // resolved on-chain, once; the keeper cannot inject it
        for (uint256 i; i < orders.length; ++i) {
            try this._rialtoBuy(router, orders[i]) returns (uint256 out) {
                emit RialtoBought(orders[i].stockIndex, router, orders[i].ethAmount, out);
            } catch (bytes memory reason) {
                emit RialtoBuyFailed(orders[i].stockIndex, reason);
            }
        }
    }

    /// Execute ONE order under the safety invariants. `onlySelf` — no external caller can inject
    /// `router`; it is always the on-chain-resolved value. Runs under buyStocksRialto's nonReentrant
    /// lock, so it is deliberately not itself nonReentrant (that would revert the try/catch).
    function _rialtoBuy(address router, RialtoBuy calldata o) external returns (uint256 out) {
        if (msg.sender != address(this)) revert OnlySelf();

        IERC20 stock = IERC20(stocks[o.stockIndex].token); // token by index (OOB reverts → order skipped)

        uint256 cap = maxSpendPerBuy;
        if (o.ethAmount == 0 || o.minOut == 0 || o.ethAmount > address(this).balance || (cap != 0 && o.ethAmount > cap))
        {
            revert BadAmount();
        }

        uint256 beforeStock = stock.balanceOf(address(this));
        uint256 beforeEth = address(this).balance;

        // native ETH sell: pay via value, no approval. Require success; bubble the router's revert reason.
        (bool ok, bytes memory ret) = router.call{value: o.ethAmount}(o.data);
        if (!ok) {
            assembly {
                revert(add(ret, 0x20), mload(ret))
            }
        }

        // output = measured balance delta of the EXPECTED stock, never the router's return data
        out = stock.balanceOf(address(this)) - beforeStock;
        if (out < o.minOut) revert Slippage(o.stockIndex, out, o.minOut);
        // ETH can only leave via msg.value; defensive check we never spent more than intended
        if (beforeEth - address(this).balance > o.ethAmount) revert BadAmount();
    }

    /// Resolve the live Rialto router and enforce the reject-list before any ETH is sent.
    function _resolveRouter() internal view returns (address router) {
        router = IRialtoRegistry(rialtoRegistry).ownerOf(rialtoFeatureId); // keeper cannot supply it
        if (
            router == address(0) || router.code.length == 0 || router == address(this) || router == address(token)
                || router == address(poolManager) || isRedeemable[router]
        ) revert UnsafeRouter(router);
    }

    /// The router the Rialto buys would use right now, with the safety check applied — keeper preflight.
    function resolvedRouterSafe() external view returns (address) {
        return _resolveRouter();
    }

    // ── owner config (no fund-extraction path) ────────────────────────────────────────────────────

    function addStock(address stockToken, uint24 fee, int24 tickSpacing, address hooks) external onlyOwner {
        if (stockToken == address(0)) revert ZeroAddress();
        uint256 n = stocks.length;
        for (uint256 i; i < n; ++i) {
            if (stocks[i].token == stockToken) revert DuplicateStock();
        }
        stocks.push(Stock(stockToken, fee, tickSpacing, hooks));
        if (!isRedeemable[stockToken]) {
            isRedeemable[stockToken] = true;
            _redeemable.push(stockToken); // permanent redemption membership; survives removeStock
        }
        emit StockAdded(stockToken, fee, tickSpacing, hooks);
    }

    /// Delist a stock from future BUYS only. Its already-accumulated balance stays in the vault and
    /// remains fully redeemable (redeem() iterates the redemption set, not `stocks`) — delisting can
    /// never strand or confiscate holders' backing.
    function removeStock(uint256 i) external onlyOwner {
        address stockToken = stocks[i].token;
        stocks[i] = stocks[stocks.length - 1];
        stocks.pop();
        emit StockRemoved(stockToken);
    }

    /// Evict a token from the redemption set — ONLY when it holds nothing here (a fully-redeemed or a
    /// permanently-broken token whose balanceOf reads 0 via the safe read). Guarded by that zero check
    /// so the owner can never prune a token that still holds real backing, i.e. can never strand funds.
    /// Keeps the redeem loop bounded and lets a bricked token be removed (defence-in-depth beside
    /// _safeBalanceOf, which already prevents a broken token from reverting redemption).
    function pruneRedeemable(address stockToken) external onlyOwner {
        if (!isRedeemable[stockToken]) revert BadAmount();
        if (_safeBalanceOf(stockToken) != 0) revert BadAmount(); // still holds backing — not prunable
        uint256 n = _redeemable.length;
        for (uint256 i; i < n; ++i) {
            if (_redeemable[i] == stockToken) {
                _redeemable[i] = _redeemable[n - 1];
                _redeemable.pop();
                break;
            }
        }
        isRedeemable[stockToken] = false;
        emit RedeemablePruned(stockToken);
    }

    function setKeeper(address k, bool on) external onlyOwner {
        keeper[k] = on;
        emit KeeperSet(k, on);
    }

    function setRedemptionFeeBps(uint256 bps) external onlyOwner {
        if (bps > MAX_REDEMPTION_FEE_BPS) revert FeeTooHigh();
        redemptionFeeBps = bps;
        emit RedemptionFeeSet(bps);
    }

    function setMaxSpendPerBuy(uint256 v) external onlyOwner {
        maxSpendPerBuy = v;
        emit MaxSpendPerBuySet(v);
    }

    // ── views ─────────────────────────────────────────────────────────────────────────────────────

    function stocksLength() external view returns (uint256) {
        return stocks.length;
    }

    function stockTokenAt(uint256 i) external view returns (address) {
        return stocks[i].token;
    }

    function redeemableLength() external view returns (uint256) {
        return _redeemable.length;
    }

    function redeemableAt(uint256 i) external view returns (address) {
        return _redeemable[i];
    }

    /// (redeemable token addresses, vault-held balances, pending ETH) — everything the UI needs to
    /// price NAV. Iterates the redemption set, so a delisted-but-still-held stock is still shown.
    function reserves() external view returns (address[] memory tokens, uint256[] memory balances, uint256 pendingEth) {
        uint256 n = _redeemable.length;
        tokens = new address[](n);
        balances = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            tokens[i] = _redeemable[i];
            balances[i] = _safeBalanceOf(_redeemable[i]);
        }
        pendingEth = address(this).balance;
    }

    receive() external payable {} // native-ETH tax arrives here from the hook's take()
}