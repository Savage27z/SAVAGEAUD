# TMAAR — backed.is StockVault / BackedToken (Robinhood Chain)

Phase 0.5. Facts from on-chain + thestackaudit full scan (2026-07-25) + verified source.

## Actors & Trust Levels

| Actor | Trust Level | What They Can Do | What Happens If Compromised |
|-------|-------------|------------------|------------------------------|
| **Vault owner (single EOA `0x9ca5B125…`)** | Medium-High | setKeeper(k,on); setRedemptionFeeBps(≤10% cap); setMaxSpendPerBuy; addStock/removeStock/pruneRedeemable (bounded: removeStock moves no tokens; pruneRedeemable reverts unless balance 0) | Can't drain reserve principal (no withdraw/sweep/rescue). Can change redemption fee up to 10%, swap keeper, add/remove basket stocks, alter per-buy spend cap. No timelock/multisig → key loss/compromise = fee grief + keeper/basket manipulation, NOT principal theft (per structural scan — VERIFY in code) |
| **Keeper** (owner-set, off/on) | Medium | buyStocks / buyStocksRialto: spend vault ETH to buy tokenized stocks (bounded per buy by maxSpendPerBuy) | Can waste reserve ETH on bad buys (slippage/minOut checks?), buy wrong assets, grief. Can they steal? (verify minOuts/recipient binding) |
| **Holders** | None | redeem/redeemTo pro-rata in-kind, burn $BACKED; trade on V4 pool (3% tax each way feeds vault) | — |
| **Rialto registry/router** | High (external) | Settlement router for stock buys (featureId 2 = taker-submitted), resolved via registry ownerOf | If registry/router malicious or resolvable wrongly, keeper buys could be routed to attacker or fail |
| **V4 PoolManager / hook** | High (external) | Holds BACKED/ETH pool; unlockCallback path for buys | Standard V4 trust; callback reentrancy surface |
| **Stock tokens** (NVDA/AAPL/MSFT etc., tokenized via Rialto?) | Medium | Vault holds them; redeemable list vs stocks list | Fake/impairable stock token = redemption basket corruption (addStock trust) |

## Key Assumptions

1. **Owner powers are bounded as documented** — no path from owner/keeper to reserve principal; redemption fee capped at 10% (currently 5%).
   - *What if it fails?* — fee grief or worse → HIGH finding.
2. **Redemption is fair across holders**: pro-rata in-kind split is rounding-neutral or rounds against the redeemer, and dust handling (_trySend) can't be exploited to steal or strand backing.
   - *What if it fails?* — first/last-redeemer skew; dust accumulation; a redeemer extracts more than pro-rata.
3. **Reserve per token is always ≥ redeemable claim** (backing can't be stranded or double-counted).
   - *What if it fails?* — pruneRedeemable/removeStock paths could strand backing (stackaudit says prune reverts unless balance zero — verify).
4. **Buy paths can't be front-run/griefed to steal vault ETH** (minOuts, recipient binding, callback safety, Rialto router resolution).
   - *What if it fails?* — keeper buy front-run, callback reentrancy, router hijack.
5. **Stock tokens are honest ERC20s** (fixed decimals, no fee-on-transfer/rebase/blacklist) — redemption math across the basket assumes standard behavior.
   - *What if it fails?* — donation/fee-on-transfer corrupts per-token reserve accounting.
6. **BACKED/ETH V4 pool tax mechanism routes 3% each way to the vault correctly** (hook correctness).
   - *What if it fails?* — tax bypass or misrouting (router contract).

## Accepted Risks (documented/structural)
1. Single hot EOA owner (no multisig/timelock) — accepted by design; powers bounded.
2. Keeper honesty for reserve efficiency (bounded per buy).
3. Token trades at premium to backing (market risk, not protocol).
4. Redemption fee exists (≤10%, currently 5%) — value leak by design.

## Attack Surface Summary
- **Primary targets:** _redeem pro-rata math + _trySend dust handling; pruneRedeemable/removeStock edge cases; buyStocks callback path; Rialto router resolution; fee-cap enforcement; donation/balance-arrival corruption of redemption accounting.
- **Most powerful attacker:** compromised owner EOA (bounded) or a malformed stock token.
- **Can the protocol survive owner-key failure?** Mostly yes (no principal access) — IF code matches structural scan.
- **Wave-pattern mapping:** P2 (vault balances vs pool state vs redeemable bookkeeping — two sources of truth), P3 (direct-transfer donations affecting redemption), P1 (keeper flag/fee setter default-state checks).
