# backed.is — Findings (Phase 1 source read, 2026-09-03)

**Verdict: 🟢 No direct theft/rug path found. Design holds up under source review —
matches thestackaudit's structural T2.** The code is unusually defensive (CEI
redemption, burn-before-payout, skip-don't-brick legs, assembly-safe token reads,
capped fee, no owner/keeper withdrawal path, router resolved on-chain, measured-delta
output checks). Observations below are informational/trust, Macro-style
Impact × Likelihood.

**Contracts reviewed (all verified, solc 0.8.26):** BackedToken (fixed 1B, burn-only),
StockVault (21KB core), BackedRouter (stateless V4 router), BackedFeeHook (3% ETH-leg
tax → vault; verbatim The Index IndexFeeHook pattern).

**Live state verified:** owner `0x9ca5B125…` (EOA); redemptionFeeBps=500 (5%);
maxSpendPerBuy=0.5 ETH (set ✓); rialtoRegistry `0x71a120…` feature 2; 7 stocks =
7 redeemable (NVDA/AAPL/MSFT-style tokenized stocks); BACKED supply ≈ 944.1M (real
redemptions ongoing); vault pending ETH ≈ 0.0109 ETH; pool fee 1% + hook 3%.

---

## F1 (🟡 Info-Medium) — owner addStock() retroactively reshapes the redemption basket; single EOA, no timelock
`addStock` (owner-only) inserts any ERC20 into the buy list AND permanently into the
redemption set. Every current and future holder's `redeem()` pays out a pro-rata slice
of whatever basket exists then — including any token the owner adds later:
- a fee-on-transfer / rebasing / blacklistable token corrupts per-leg accounting
  (balance read ≠ amount received on transfer);
- a honeypot/non-transferable token makes that leg perpetually `RedeemSkipped` —
  redeemers forfeit that slice;
- pool params pointing at a non-existent or fee-hook pool brick `buyStocks`
  (DoS on backing accrual; ETH stays pending, so no theft).
Owner = single hot EOA `0x9ca5B125…` (no multisig/timelock). Currently the 7 listed
tokens look like standard Rialto tokenized stocks — this is a trust/key-risk, not a
live bug.
*Mitigation suggestion: timelock/multisig on owner; validate stock token standard
(no fee-on-transfer, standard decimals) before addStock; consider a redeemable-set
freeze window.*

## F2 (🟡 Info) — redemption fee up to 10% settable instantly, no timelock
`setRedemptionFeeBps` (≤1000) is owner-only, effective immediately. Currently 5%.
A compromised/rug-pull-bound owner could raise to 10% moments before a whale redeem —
a 10% value haircut, not theft. Bounded by MAX_REDEMPTION_FEE_BPS. Structural trust
note (stackaudit flagged the same single-EOA point).

## F3 (🟢 Info) — maxSpendPerBuy defaults to 0 = UNCAPPED
Constructor leaves it 0; only `setMaxSpendPerBuy` (owner) bounds a keeper buy. **On-chain
it is currently set to 0.5 ETH** ✓ — but if the owner ever resets it to 0 (the setter
allows it), a compromised keeper's per-tx blast radius = the entire pending ETH (spread
across stocks, minOuts self-chosen). Config fragility, not live.

## F4 (🟢 Info) — keeper can set minOut = 0 (accept any fill)
`buyStocks(minOuts)` / `buyStocksRialto(minOut)` allow 0 slippage floors. Honest-keeper
assumption; a compromised keeper can waste up to (cap × stocks) per tx on bad fills —
never move reserve off pro-rata (no withdrawal path; ETH only exits via buys; stocks
only exit via redeem).

## F5 (🟢 Info) — hook taxes only native-ETH-paired pools
BackedFeeHook charges 3% only when currency0 = ETH. A BACKED pool against any other
asset (USDG etc.) passes untaxed → vault accrual silently stops if liquidity migrates.
Guard by design, worth knowing.

## F6 (🟢 Info) — redemption is O(n) over the append-only redeemable basket
Each redeem loops every redeemable token with an external balanceOf + transfer (n=7
today). pruneRedeemable only removes zero-balance tokens, so the basket only grows
unless a leg is fully drained. Long-term gas creep for redeemers. Owner-controlled.

## Notes (verified, non-issues)
- Rounding always truncates against the redeemer on every leg — dust accrues to
  remaining holders. No first/last-redeemer skew.
- Donations (ETH or stock direct-transfers to the vault) just increase everyone's
  pro-rata backing — no per-user exploit (P3 clean).
- No two-sources-of-truth seam found: all balances read live via safe staticcall;
  redeemable list is the only payout basis and can't strand delisted stock (P2 clean).
- Authz: owner/keeper roles clean; no default-state-satisfiable predicate found
  (P1 clean).
- `redeemTo(to=arbitrary)`: self-harm only (burner chooses destination).
- Reentrancy: single ReentrancyGuard covers redeem + buys; unlockCallback is
  PM-only; ETH leg failure reverts (documented redeemTo escape hatch).
- Rialto router: resolved from registry on-chain; keeper can't inject; output =
  measured stock delta (not router return data); ETH spend re-checked; reject-list
  covers self/token/PM/redeemable. A malicious *registry* is the residual trust
  (external).

## What we did NOT verify
- Rialto registry/router contracts themselves (external, out of the 4-contract set;
  registry `0x71a120…` ownerOf(feature 2) → router — read, not audited).
- The 7 stock tokens' own contracts (assumed standard tokenized equities).
- Off-chain: keeper bot behavior, frontend, web (stackaudit: thin headers).
