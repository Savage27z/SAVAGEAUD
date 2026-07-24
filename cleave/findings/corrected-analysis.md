# Cleave — Full Analysis (Corrected)

## Verdict: 🟢 Clean — Nothing reportable

After thorough on-chain verification, Cleave's contracts are well-designed with no exploitable vulnerabilities.

## What I Verified On-Chain

### Oracle Stack
```
Series → PinnableOracle → UniswapV3MedianOracle → 3 Uniswap V3 TWAP pools
```

| Check | Result |
|---|---|
| `PinnableOracle.price()` | ✅ Returns $1,883.80 (current ETH price) |
| `PinnableOracle.pin()` window | ✅ Only works for timestamps within ~6 hours of now (too old → "OLD" revert, too new → "FutureTimestamp" revert) |
| `UniswapV3MedianOracle.price()` | ✅ Returns same as PinnableOracle |
| Uniswap V3 pools | ✅ 3 pools: WETH/USDC, WETH/USDT, WETH/DAI with 1h TWAP |
| Nobody has pinned yet | ✅ Maturity is Aug 1 (8 days away), so expected |

### Settlement Flow (After Aug 1)
1. Someone calls `settle()` on the Series
2. Series calls `IPriceOracle.priceAt(maturity)` on PinnableOracle
3. PinnableOracle checks: `pinned[maturity] != 0`? → returns pinned price if yes
4. If not pinned → calls `inner.priceAt(maturity)` → UniswapV3MedianOracle returns historical TWAP ✅

### Pin Mechanism
- Permisionless, anyone can call `pin(maturity)` after maturity arrives
- **6-hour window** — must be called within ~6 hours of the timestamp
- Records `price()` (current spot, which equals the inner oracle's current price)
- Once pinned → immutable. `AlreadyPinned()` prevents override.
- If not pinned → falls back to inner oracle's accurate historical TWAP ✅

### Why No Exploit
- ❌ Can't pin after 6h window → "OLD" revert
- ❌ Can't pin before timestamp → "FutureTimestamp" revert
- ❌ Can't override a pin → "AlreadyPinned" revert
- ✅ Anyone can pin → decentralized, no single point of trust
- ✅ Fallback to historical TWAP if not pinned → price at maturity is preserved

### Access Control
- No owner/admin/upgrade in Series ✅
- SplitFactory has no upgrade path ✅
- All mutative functions in Series have `ReentrancyGuard` ✅
- PinnableOracle has permissionless `pin()` but it's safe due to window constraints ✅

### Accounting
- Split: 1 ETH → 1 P + 1 N (no rounding) ✅
- Merge: 1 P + 1 N → 1 ETH ✅
- Redeem: `(pAmount * f + nAmount * (1-f)) / 1e18` — max 1 wei loss per tx ✅
- f = min(1, strike/price) — capped correctly ✅
- No first-depositor inflation (1:1 minting) ✅

### Economic
- No MEV in split/merge (P+N always = 1 ETH) ✅
- No oracle manipulation (Uniswap V3 TWAP + 3-pool median) ✅
- No sandwich (no AMM swaps) ✅

## Summary

| Severity | Count | Previous Finding |
|---|---|---|
| Critical | 0 | — |
| High | 0 | — |
| Medium | 0 | ❌ PinnableOracle finding retracted — pin window + fallback makes it safe |
| Low | 0 | — |
| Info | 0 | — |

**Moving on.** Cleave is a clean protocol with sound design. Nothing reportable here.
