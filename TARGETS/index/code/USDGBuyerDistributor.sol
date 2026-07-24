// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
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

interface IRouterRegistry {
    function ownerOf(uint256 featureId) external view returns (address);
}

/// Minimal view of the $INDEX ReflectionToken — the holder registry this distributor pays out to.
interface IIndexToken {
    function holderCount() external view returns (uint256);
    function holderAt(uint256 i) external view returns (address);
    function balanceOf(address a) external view returns (uint256);
}

/// Buys the tokenized-stock basket with USDG through Rialto, then distributes the bought stock
/// pro-rata to $INDEX holders. Set as `treasury.distributor`, so the treasury (reconfigured to buy
/// only USDG on the deep 0.046% ETH/USDG pool) deposits USDG here.
///
/// The load-bearing property: a keeper supplies opaque router calldata, which this contract executes
/// against an EXTERNAL router. That raw-call surface is locked down (see the SAFETY INVARIANTS in
/// `_resolveRouter` + `_rialtoBuy`) so a fully-compromised keeper can only price-grief a buy within
/// its own minOut through the REAL registry-resolved router — never reach the stock pot, the ETH,
/// the treasury, or any unrelated token, and never move funds off pro-rata to holders.
///
/// There is NO owner or keeper fund-extraction path: every USDG exit is a locked buy of a registered
/// stock that then goes pro-rata to holders. `sweepForeign` reverts on USDG and every registered
/// stock. See docs/RIALTO_HELPER_SPEC.md for the full design + the immutable-registry disclosure.
contract USDGBuyerDistributor is Ownable, Pausable, ReentrancyGuard, IUnlockCallback {
    using SafeERC20 for IERC20;

    // ── immutable trust anchors (never injectable) ──────────────────────────────────────────────
    IIndexToken public immutable indexToken;
    IPoolManager public immutable poolManager;
    IERC20 public immutable usdg; // 6-dp sell token
    address public immutable registry; // Rialto router registry
    uint256 public immutable registryTokenId; // = 2 (ownerOf(2) -> live taker-submitted router)

    // ── owner-settable config ───────────────────────────────────────────────────────────────────
    struct Stock { address token; uint24 fee; int24 tickSpacing; address hooks; }
    Stock[] public stocks;
    mapping(address => bool) public isStock;
    mapping(address => bool) public keeper;
    uint256 public maxSpendPerBuy; // USDG (6-dp) cap per order — bounds keeper-compromise blast radius
    uint256 public interval;
    // USDG/ETH fallback hop-A pool params (default the 0.046% pool: 460 / 9 / 0x0)
    uint24 public usdgEthFee = 460;
    int24 public usdgEthTickSpacing = 9;
    address public usdgEthHooks = address(0);

    // ── distribution snapshot state (verbatim StockDistributorV2) ───────────────────────────────
    address[] private _holders;
    uint256[] private _bals;
    address[] private _stock;
    uint256[] private _pot;
    uint256 public eligible;
    uint256 public cursor;
    bool public cycleActive;
    uint256 public nextDistribution;
    uint256 public snapCount;   // holders captured in the pending paginated snapshot
    bool public snapPending;    // a snapshot is being built (between snapshotHolders and startCycle)

    // ── events ──────────────────────────────────────────────────────────────────────────────────
    event StockAdded(address indexed token, uint24 fee, int24 tickSpacing, address hooks);
    event StockRemoved(address indexed token);
    event KeeperSet(address indexed keeper, bool on);
    event MaxSpendPerBuySet(uint256 v);
    event IntervalSet(uint256 v);
    event UsdgEthPoolSet(uint24 fee, int24 tickSpacing, address hooks);
    event ForeignSwept(address indexed token, address indexed to, uint256 amount);
    event RialtoBought(uint256 indexed stockIndex, address indexed router, uint256 usdgSpent, uint256 out);
    event RialtoBuyFailed(uint256 indexed stockIndex, bytes reason);
    event V4FallbackBought(uint256 indexed stockIndex, uint256 usdgIn, uint256 out);
    event CycleStarted(uint256 holders, uint256 eligible, uint256 stocks);
    event HoldersSnapshotted(uint256 snapCount, uint256 holderCount);
    event BatchPaid(uint256 from, uint256 to);
    event Distributed(address indexed stock, uint256 amount, uint256 holders);
    event PayoutSkipped(address indexed stock, address indexed holder, uint256 amount);

    error OnlyKeeper();
    error OnlySelf();
    error OnlyPoolManager();
    error UnsafeRouter(address router);
    error BadAmount();
    error Slippage(uint256 out, uint256 minOut);
    error NotSweepable();
    error TooEarly();
    error CycleInProgress();
    error NoCycle();
    error LengthMismatch();
    error DuplicateStock();
    error SnapshotIncomplete();
    error NoDistributionPot();
    error NoEligibleHolders();

    modifier onlyKeeper() {
        if (!keeper[msg.sender] && msg.sender != owner()) revert OnlyKeeper();
        _;
    }

    constructor(
        IIndexToken indexToken_,
        IPoolManager pm_,
        IERC20 usdg_,
        address registry_,
        uint256 registryTokenId_,
        address owner_,
        uint256 interval_,
        uint256 maxSpendPerBuy_
    ) Ownable(owner_) {
        indexToken = indexToken_;
        poolManager = pm_;
        usdg = usdg_;
        registry = registry_;
        registryTokenId = registryTokenId_;
        interval = interval_;
        maxSpendPerBuy = maxSpendPerBuy_;
    }

    // ── Rialto buys ─────────────────────────────────────────────────────────────────────────────

    struct BuyOrder { uint256 stockIndex; uint256 sellAmount; uint256 minOut; bytes data; }

    /// Keeper batch buy. Each order runs in an isolated try/catch self-call, so one stale/failed/
    /// unavailable Rialto quote is skipped (emits RialtoBuyFailed) while the others still settle in
    /// this tx. Route any skipped stock through buyStocksV4Fallback.
    function buyStocksRialto(BuyOrder[] calldata orders) external nonReentrant whenNotPaused onlyKeeper {
        address router = _resolveRouter(); // INVARIANTS 1-3, once, on-chain
        for (uint256 i; i < orders.length; ++i) {
            try this._rialtoBuy(router, orders[i]) returns (uint256 out) {
                emit RialtoBought(orders[i].stockIndex, router, orders[i].sellAmount, out);
            } catch (bytes memory reason) {
                emit RialtoBuyFailed(orders[i].stockIndex, reason);
            }
        }
    }

    /// Execute ONE order under the full safety invariants. `onlySelf` — no external caller can inject
    /// `router`; it is always the on-chain-resolved value from buyStocksRialto. Runs under the outer
    /// nonReentrant lock, so it is deliberately not itself nonReentrant (that would revert try/catch).
    function _rialtoBuy(address router, BuyOrder calldata o) external returns (uint256 out) {
        if (msg.sender != address(this)) revert OnlySelf();

        Stock storage s = stocks[o.stockIndex]; // INVARIANT 4: token by index (OOB reverts)
        IERC20 stock = IERC20(s.token);

        // INVARIANT 5: amount bounds
        uint256 bal = usdg.balanceOf(address(this));
        if (o.sellAmount == 0 || o.sellAmount > maxSpendPerBuy || o.sellAmount > bal || o.minOut == 0) revert BadAmount();

        uint256 beforeStock = stock.balanceOf(address(this));
        uint256 beforeUsdg = bal;

        // INVARIANT 7: exact approve on USDG ONLY (never a stock), reset to 0 after — unconditional
        usdg.forceApprove(router, o.sellAmount);
        // INVARIANT 6 + 8: value hardcoded 0; require success, bubble reason
        (bool ok, bytes memory ret) = router.call{value: 0}(o.data);
        usdg.forceApprove(router, 0);
        if (!ok) {
            assembly { revert(add(ret, 0x20), mload(ret)) }
        }

        // INVARIANT 9: output = measured balance delta of the EXPECTED stock, not router return data
        out = stock.balanceOf(address(this)) - beforeStock;
        if (out < o.minOut) revert Slippage(out, o.minOut);
        // INVARIANT 10: input spend sanity (allowance already caps this; defensive)
        uint256 spent = beforeUsdg - usdg.balanceOf(address(this));
        if (spent > o.sellAmount) revert BadAmount();
    }

    /// Resolve the live router and enforce INVARIANTS 1-3 before any allowance is granted.
    function _resolveRouter() internal view returns (address router) {
        // INVARIANT 1: target locked to the registry-resolved router (keeper cannot supply it)
        router = IRouterRegistry(registry).ownerOf(registryTokenId);
        // INVARIANT 2: router has code (rejects bricked / migrated / EOA / zero)
        // INVARIANT 3: safe-router reject-list (kills poison-registry -> approve+call-as-transfer)
        if (
            router == address(0) || router.code.length == 0 || router == address(this)
                || router == address(usdg) || router == address(poolManager) || router == address(indexToken)
                || isStock[router]
        ) revert UnsafeRouter(router);
    }

    /// Router the buys would use right now, with the full safety check applied — for keeper preflight.
    function resolvedRouterSafe() external view returns (address) {
        return _resolveRouter();
    }

    /// Raw registry read (no safety check) — informational.
    function router() external view returns (address) {
        return IRouterRegistry(registry).ownerOf(registryTokenId);
    }

    // ── v4 two-hop fallback (USDG -> ETH -> stock), no raw calldata ──────────────────────────────

    /// Liquidity-of-last-resort for stocks with no Rialto quote. All pool keys come from stored
    /// config; the keeper supplies only indices, amounts, and minOuts.
    function buyStocksV4Fallback(uint256[] calldata stockIndices, uint256[] calldata usdgAmounts, uint256[] calldata minOuts)
        external nonReentrant whenNotPaused onlyKeeper
    {
        if (stockIndices.length != usdgAmounts.length || stockIndices.length != minOuts.length) revert LengthMismatch();
        poolManager.unlock(abi.encode(stockIndices, usdgAmounts, minOuts));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert OnlyPoolManager();
        (uint256[] memory idx, uint256[] memory amts, uint256[] memory minOuts) =
            abi.decode(data, (uint256[], uint256[], uint256[]));

        PoolKey memory usdgKey = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(usdg)),
            fee: usdgEthFee,
            tickSpacing: usdgEthTickSpacing,
            hooks: IHooks(usdgEthHooks)
        });

        uint256 totalUsdg;
        for (uint256 i; i < idx.length; ++i) {
            // minOut > 0 required, mirroring the Rialto path — a zero floor on a public v4 pool is
            // fully sandwichable.
            if (amts[i] == 0 || amts[i] > maxSpendPerBuy || minOuts[i] == 0) revert BadAmount();
            Stock storage s = stocks[idx[i]];
            totalUsdg += amts[i];

            // Hop A: USDG (currency1) -> ETH (currency0). exact input of USDG.
            BalanceDelta dA = poolManager.swap(
                usdgKey,
                SwapParams({zeroForOne: false, amountSpecified: -int256(amts[i]), sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1}),
                ""
            );
            uint256 ethMid = uint256(uint128(dA.amount0())); // ETH received

            // Hop B: ETH -> stock. exact input of the ETH from hop A (nets ETH to 0).
            BalanceDelta dB = poolManager.swap(
                PoolKey({currency0: Currency.wrap(address(0)), currency1: Currency.wrap(s.token), fee: s.fee, tickSpacing: s.tickSpacing, hooks: IHooks(s.hooks)}),
                SwapParams({zeroForOne: true, amountSpecified: -int256(ethMid), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
                ""
            );
            uint256 out = uint256(uint128(dB.amount1()));
            if (out < minOuts[i]) revert Slippage(out, minOuts[i]);
            poolManager.take(Currency.wrap(s.token), address(this), out);
            emit V4FallbackBought(idx[i], amts[i], out);
        }

        // settle the USDG we owe (ETH nets to zero across the paired hops)
        poolManager.sync(Currency.wrap(address(usdg)));
        usdg.safeTransfer(address(poolManager), totalUsdg);
        poolManager.settle();
        return "";
    }

    // ── paginated snapshot + distribution ────────────────────────────────────────────────────────

    /// Capture up to `count` more holders into the pending cycle snapshot. Permissionless. The first
    /// cold snapshot of the holder registry is ~2 storage writes/holder and would exceed the chain's
    /// per-tx gas cap past ~700 holders, so a large registry is snapshotted across several txs, then
    /// finalized by startCycle(). The first call (snapPending == false) resets and starts fresh.
    ///
    /// Registry churn during the snapshot is bounded and safe — no double-pay, no brick. The registry
    /// swap-pops on holder removal, so a holder that fully exits mid-snapshot is either already captured
    /// (paid its snapshot balance, which it held) or skipped and rolled to next cycle; a holder that
    /// joins is captured if it lands before the cursor, else rolled over. Each index is read exactly
    /// once, and total payout is always bounded by the frozen pot.
    function snapshotHolders(uint256 count) external nonReentrant {
        if (cycleActive) revert CycleInProgress();
        if (block.timestamp < nextDistribution) revert TooEarly();
        if (!snapPending) {
            // Don't begin a snapshot (permissionless, and O(holders) gas) for an empty cycle — there
            // must be stock to distribute. Stock can only leave via distributeBatch (needs cycleActive)
            // so the pot can't drain between here and startCycle's finalize.
            if (!_hasPot()) revert NoDistributionPot();
            delete _holders;
            delete _bals;
            delete _stock;
            delete _pot;
            eligible = 0;
            snapCount = 0;
            snapPending = true;
        }
        uint256 n = indexToken.holderCount();
        uint256 end = snapCount + count;
        if (end > n) end = n;
        uint256 elig = eligible;
        for (uint256 i = snapCount; i < end; ++i) {
            address h = indexToken.holderAt(i);
            uint256 b = indexToken.balanceOf(h);
            _holders.push(h);
            _bals.push(b);
            elig += b;
        }
        eligible = elig;
        snapCount = end;
        emit HoldersSnapshotted(snapCount, n);
    }

    /// How many holders still need snapshotting before startCycle can finalize (keeper convenience).
    function snapshotRemaining() external view returns (uint256) {
        uint256 n = indexToken.holderCount();
        uint256 done = snapPending ? snapCount : 0;
        return n > done ? n - done : 0;
    }

    function startCycle() external nonReentrant {
        if (cycleActive) revert CycleInProgress();
        if (block.timestamp < nextDistribution) revert TooEarly();

        if (snapPending) {
            // paginated path: the snapshot must cover every current holder (a grown registry needs
            // more snapshotHolders() calls first; a shrunk one is fine — the missing tail rolls over).
            if (snapCount < indexToken.holderCount()) revert SnapshotIncomplete();
            snapPending = false;
        } else {
            // single-shot path (small registry / tests): snapshot every holder inline.
            delete _holders;
            delete _bals;
            delete _stock;
            delete _pot;
            uint256 n = indexToken.holderCount();
            uint256 elig;
            for (uint256 i; i < n; ++i) {
                address h = indexToken.holderAt(i);
                uint256 b = indexToken.balanceOf(h);
                _holders.push(h);
                _bals.push(b);
                elig += b;
            }
            eligible = elig;
        }

        // No empty cycle: there must be eligible supply AND a nonzero pot before we advance
        // nextDistribution and open a cycle (a caller-agnostic guard; the keeper also checks off-chain).
        if (eligible == 0) revert NoEligibleHolders();
        uint256 m = stocks.length;
        uint256 totalPot;
        for (uint256 k; k < m; ++k) {
            address tok = stocks[k].token;
            uint256 p = _safeBalanceOf(tok); // a token whose balanceOf reverts/bombs => pot 0, never bricks the snapshot
            _stock.push(tok);
            _pot.push(p);
            totalPot += p;
        }
        if (totalPot == 0) revert NoDistributionPot();

        nextDistribution = block.timestamp + interval;
        cursor = 0;
        cycleActive = true;
        emit CycleStarted(_holders.length, eligible, m);
    }

    function distributeBatch(uint256 count) external nonReentrant {
        if (!cycleActive) revert NoCycle();
        uint256 n = _holders.length;
        uint256 end = cursor + count;
        if (end > n) end = n;

        uint256 elig = eligible;
        uint256 m = _stock.length;
        for (uint256 i = cursor; i < end; ++i) {
            uint256 b = _bals[i];
            if (b == 0) continue;
            address h = _holders[i];
            for (uint256 k; k < m; ++k) {
                uint256 amt = (_pot[k] * b) / elig; // dust stays for next cycle
                if (amt != 0) _trySend(_stock[k], h, amt);
            }
        }
        emit BatchPaid(cursor, end);
        cursor = end;

        if (end == n) {
            cycleActive = false;
            for (uint256 k; k < m; ++k) emit Distributed(_stock[k], _pot[k], n);
        }
    }

    /// Non-reverting stock transfer. A holder that cannot receive a (regulated / allowlisted) stock
    /// is SKIPPED, never allowed to revert the batch and brick the cycle. The skipped share stays in
    /// the pot and rolls into the next cycle's snapshot.
    ///
    /// Done in assembly (the SafeTransferLib pattern), NOT `token.call(...)` returning `bytes memory`,
    /// for two reasons — both bricks a malformed/upgraded regulated stock token could otherwise cause:
    ///   1. High-level `.call` copies the FULL returndata into memory before any check, so a token
    ///      returning megabytes would OOG this call under the 63/64 rule (a returndata bomb). We cap
    ///      the copy at 32 bytes, so the caller's cost is O(1) in the return size.
    ///   2. `abi.decode(ret,(bool))` itself reverts on a return shorter than 32 bytes or a non-clean
    ///      bool; here a malformed return is simply treated as unpaid.
    /// Paid iff the call succeeded AND the token returned nothing (USDT-style) or a >=32-byte value
    /// whose first word is nonzero (a truthy bool). Anything else => skip, never brick.
    ///
    /// Residual (accepted): a maliciously-UPGRADED stock token could still brick a cycle by burning
    /// all forwarded gas. We deliberately do NOT cap forwarded gas with a stipend — a fixed stipend
    /// would silently skip EVERY holder if the issuer ever legitimately raised transfer cost. The
    /// token issuer (Robinhood) is trusted and can pause / adminBurn regardless, so gas-exhaustion is
    /// out of scope; this guard covers every NON-malicious behavior (revert, false, odd return shape).
    function _trySend(address token, address to, uint256 amt) private {
        bytes memory payload = abi.encodeCall(IERC20.transfer, (to, amt));
        bool paid;
        assembly {
            // retLength = 32: copy at most one word of returndata (bomb-proof); value = 0.
            let ok := call(gas(), token, 0, add(payload, 0x20), mload(payload), 0x00, 0x20)
            let rds := returndatasize()
            // paid = ok AND ( rds == 0 OR ( rds >= 32 AND first word != 0 ) )
            paid := and(ok, or(iszero(rds), and(iszero(lt(rds, 32)), iszero(iszero(mload(0x00))))))
        }
        if (!paid) emit PayoutSkipped(token, to, amt);
    }

    /// balanceOf that cannot brick startCycle: a token whose balanceOf reverts, returns malformed data,
    /// or returndata-bombs yields 0 (its pot is treated as empty and skipped this cycle) instead of
    /// reverting the whole snapshot and stranding every stock. Same 32-byte returndata cap as _trySend;
    /// gas-exhaustion by a maliciously-upgraded token remains the accepted residual, and the owner can
    /// removeStock a persistently-broken token.
    function _safeBalanceOf(address token) private view returns (uint256 bal) {
        bytes memory payload = abi.encodeCall(IERC20.balanceOf, (address(this)));
        assembly {
            let ok := staticcall(gas(), token, add(payload, 0x20), mload(payload), 0x00, 0x20)
            if and(ok, iszero(lt(returndatasize(), 32))) { bal := mload(0x00) }
        }
    }

    /// True if any registered stock has a nonzero balance here — i.e. there is something to distribute.
    function _hasPot() private view returns (bool) {
        uint256 m = stocks.length;
        for (uint256 k; k < m; ++k) {
            if (_safeBalanceOf(stocks[k].token) != 0) return true;
        }
        return false;
    }

    // ── owner config (no fund-extraction path) ──────────────────────────────────────────────────

    function addStock(address token, uint24 fee, int24 tickSpacing, address hooks) external onlyOwner {
        // USDG is the sell token, never a distributed stock; address(0) is nonsense. A token already
        // present in stocks[] would be snapshotted twice in startCycle and over-subscribe the pot
        // (the single physical balance paid out 2x), so bar duplicates. Re-adding a *removed* stock
        // is fine — it is no longer in stocks[] — even though isStock stays true for the sweep bar.
        if (token == address(0) || token == address(usdg)) revert BadAmount();
        uint256 m = stocks.length;
        for (uint256 i; i < m; ++i) {
            if (stocks[i].token == token) revert DuplicateStock();
        }
        stocks.push(Stock(token, fee, tickSpacing, hooks));
        isStock[token] = true;
        emit StockAdded(token, fee, tickSpacing, hooks);
    }

    function removeStock(uint256 i) external onlyOwner {
        address token = stocks[i].token;
        stocks[i] = stocks[stocks.length - 1];
        stocks.pop();
        // isStock[token] is deliberately NOT cleared. It only gates (a) sweepForeign, which MUST stay
        // permanently barred from any token ever registered as a stock — else removeStock()+
        // sweepForeign() would drain a de-listed stock's still-held pot — and (b) the router
        // reject-list, where a stale-true entry is strictly safer. Once a stock, never sweepable.
        emit StockRemoved(token);
    }

    function setKeeper(address k, bool on) external onlyOwner { keeper[k] = on; emit KeeperSet(k, on); }
    function setPaused(bool p) external onlyOwner { if (p) _pause(); else _unpause(); }
    function setMaxSpendPerBuy(uint256 v) external onlyOwner { maxSpendPerBuy = v; emit MaxSpendPerBuySet(v); }
    function setInterval(uint256 v) external onlyOwner { interval = v; emit IntervalSet(v); }

    function setUsdgEthPool(uint24 fee, int24 tickSpacing, address hooks) external onlyOwner {
        usdgEthFee = fee;
        usdgEthTickSpacing = tickSpacing;
        usdgEthHooks = hooks;
        emit UsdgEthPoolSet(fee, tickSpacing, hooks);
    }

    /// Rescue accidentally-sent junk tokens ONLY. Reverts on USDG and any registered stock, so the
    /// protocol's own funds can never be swept.
    function sweepForeign(address token, address to) external onlyOwner {
        if (token == address(usdg) || isStock[token]) revert NotSweepable();
        uint256 bal = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransfer(to, bal);
        emit ForeignSwept(token, to, bal);
    }

    // ── views ───────────────────────────────────────────────────────────────────────────────────
    function canStart() external view returns (bool) { return !cycleActive && block.timestamp >= nextDistribution; }
    function remaining() external view returns (uint256) { return cycleActive ? _holders.length - cursor : 0; }
    function stocksLength() external view returns (uint256) { return stocks.length; }
    function stockTokenAt(uint256 i) external view returns (address) { return stocks[i].token; }

    // No receive()/fallback: the v4 fallback nets ETH to zero inside the unlock (nothing is ever
    // taken as native ETH), so the contract never needs to hold ETH. A stray ETH transfer therefore
    // reverts, which protects senders rather than locking their ETH here with no rescue path.
}
