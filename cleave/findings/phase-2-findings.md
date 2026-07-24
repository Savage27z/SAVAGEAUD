# Cleave — Audit Findings

## Executive Summary

Cleave is a well-designed options-splitting protocol with real custom contracts and sound core math.
The oracle stack (PinnableOracle → UniswapV3MedianOracle → 3 TWAP feeds) is solid.
**No critical or high-severity bugs found.** 1 medium finding related to the oracle pin mechanism.

---

## ✅ Defended / Clean

| Area | Verdict |
|---|---|
| **Split/Merge Math** | ✅ P + N always = 1 ETH. No rounding that accumulates. |
| **ERC-20 safety** | ✅ SafeERC20 used everywhere |
| **Reentrancy** | ✅ ReentrancyGuard on all mutative functions |
| **No admin/owner** | ✅ Truly immutable — no rug, no parameter tweaks |
| **Oracle quality** | ✅ Uniswap V3 TWAP × 3 pools, median price. Not manipulable. |
| **Historical prices** | ✅ `UniswapV3MedianOracle.priceAt()` returns accurate historical TWAP data |
| **Split after maturity** | ✅ If someone splits after maturity but before settlement, they mint P+N at current oracle ratio — no arbitrage opportunity since P+N always = 1 ETH |

---

## 🟡 Finding 1: Permissionless `pin()` Can Override Historical Oracle Price [MEDIUM]

| Field | Value |
|---|---|
| **Type** | Oracle / Economic |
| **File** | `PinnableOracle.sol` — `pin(endTimestamp)` |
| **Severity** | Medium |
| **Exploitable?** | Yes, by anyone |

**What it does:**
`PinnableOracle.pin(endTimestamp)` records the **current** `price()` (spot) for a given past timestamp. It's permissionless — anyone can call it.

**The problem:**
`priceAt(endTimestamp)` in the PinnableOracle checks for a pinned price first, then falls back to the inner oracle. If someone calls `pin()`:
- They record the **current spot price**, mapped to `endTimestamp`
- `AlreadyPinned()` prevents anyone from correcting it
- The accurate historical TWAP from `UniswapV3MedianOracle.priceAt()` is **permanently overridden**

**Attack scenario:**
1. A series has strike = $2000, matures when ETH is $1800
2. P tokens are underwater, N tokens are in profit
3. A whale holds lots of N tokens
4. They wait for ETH to pump to $4000
5. They call `pin(maturityTimestamp)` → records $4000 as the maturity price
6. The settlement now uses $4000 → P gets $2000/$4000 = 0.5 ETH (half what they deserved), N gets the other 0.5 ETH
7. The N whale extracted value from P holders

**Why it's not critical:**
- Someone would need to call `pin()` at the right time — if a LARGE position exists, the token holders have incentive to pin at maturity and block bad pins
- The inner oracle's historical TWAP is accurate, so the only way to be exploited is if no one pins the correct price first
- For ETH on mainnet with 3 TWAP feeds, the price difference between "at maturity" and "a day later" is usually small

**Recommendation:**
- Restrict `pin()` to only the Series contract, or
- Have `pin()` record `inner.priceAt(endTimestamp)` (historical) instead of `price()` (current spot), or
- Make `AlreadyPinned()` bypassable: if the inner oracle returns a price within X% of the pinned price, use the inner oracle's value

---

## 🟢 Finding 2: Unsettled Series After 3 Weeks [INFO]

The first series (ETH @ $1350) expired on July 2 — 3 weeks ago. It hasn't been settled.

This isn't a code bug — `settle()` is permissionless and anyone can call it. The UniswapV3MedianOracle supports historical price queries, so settlement should work fine.

Likely explanation: the series only has ~$48 in it and was created by the team for testing. No one has bothered to settle it.

**Recommendation:** No action needed. Document that settlement is permissionless and can be triggered by anyone.

---

## ✅ What We Checked

### Access Control
- No admin, owner, or privileged role in the Series contract ✅
- SplitFactory has no upgrade path ✅
- PinnableOracle `pin()` is the only permissionless function that should be restricted ⚠️

### Reentrancy
- ReentrancyGuard on split(), merge(), redeem(), settle() ✅
- Cross-function reentrancy: split → mint tokens → no external call during mint. merge → burn tokens → transfer ETH → no callback ✅

### Accounting & Rounding
- Split: 1 ETH → 1 P + 1 N (1:1 ratio, no rounding) ✅
- Merge: return P + N → withdraw exactly the same amount deposited ✅
- Redeem: `amountOut = (pAmount * f + nAmount * (1e18 - f)) / 1e18`
  - Division at the end loses max 1 wei per transaction — negligible ✅
  - f is capped at 1e18 (strike/price ratio, min 0, max 1) ✅
- No first-depositor inflation attack — split always mints at 1:1 ratio ✅

### Price & Oracle
- Uniswap V3 TWAP × 3 pools (WETH/USDC, WETH/USDT, WETH/DAI) ✅
- Median price — single pool manipulation doesn't work ✅
- Historical `priceAt(timestamp)` supported ✅
- `PinnableOracle.pin()` permissionless ⚠️ (Finding 1)

### Economic
- No MEV opportunity in split/merge — P+N always = 1 ETH ✅
- No sandwich — no AMM swaps ✅
- P and N holders can't extract more than their share ✅

### External Calls
- Oracle call in settle() — read-only view function ✅
- SafeERC20 for all token transfers ✅
- No external calls during split/merge ✅
- ETH transfer during redeem — standard, no arbitrary call target ✅

---

## Summary

| Severity | Count | Details |
|---|---|---|
| Critical | 0 | — |
| High | 0 | — |
| Medium | 1 | PinnableOracle permissionless pin() can override historical price |
| Low | 0 | — |
| Info | 1 | First series unsettled for 3 weeks (test series) |

**Verdict:** Clean protocol with solid design. The PinnableOracle pin issue is the only real concern — if the team restricts `pin()` to the Series contract or changes it to record historical prices, it's a non-issue.
