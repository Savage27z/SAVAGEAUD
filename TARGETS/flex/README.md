# Flex — Fixed-Rate Trove Lending — Audit Report (2026-08-31)

**Verdict: 🟡 Informational — no direct theft path found, but TWO operational findings worth reporting (depositor liquidity)**

| | |
|---|---|
| Target | Flex (flexmeow.com) — Liquity-style fixed-rate trove lending, Vyper 0.4.3 |
| Chain | Ethereum mainnet |
| Registry | `0x9117440a7d03238905d1c8908157bd7a547c77c8` (endorsement, "Daddy" admin) |
| Active markets | ysyBOLD `0xadf4e022...` (~$200K debt) · yvcrvUSD-2 `0x7582b474...` (~$100K debt) |
| Retired/empty markets | d82db989 (yvUSD v1), 484e3c28 (SIUSD v1), 8ee72c38 (yvUSD v2) |
| Collateral | Yield-bearing vault shares: ysyBOLD, yvcrvUSD-2, yvUSD, SIUSD |
| Borrow token | USDC (6 dec) |
| Audits | None found (DefiLlama 0; no GitHub/docs surfaced) |
| Activity | Live — ysyBOLD market tx Aug 30, yvcrvUSD-2 Aug 31 |

## Architecture (all verified on-chain)

- **Registry** (Vyper 0.4.3): append-only endorsed market list; `Daddy` = protocol owner.
- **TroveManager** (per market, Vyper 0.4.3, 1,648 lines): Liquity-style troves with
  **borrower-chosen annual interest rates** (0.1%–250%), upfront fees (prepaid interest
  at the system's average rate), zombie-trove mechanism, redemption walk from lowest
  rate, dynamic-fee liquidations, bad-debt socialization to the Lender.
- **Lender** (per market, Solidity 0.8.23, Yearn V3 TokenizedStrategy): the USDC pool.
  PPS = `idle USDC + TroveManager.total_debt − unclaimed fees` over supply.
- **DutchDesk + Auction** (Vyper 0.4.3, Yearn-derived): Dutch auctions selling redeemed
  collateral for USDC; proceeds to receiver, surplus to Lender.
- **Oracle** (per market): vault-share PPS (`convertToAssets`) × Curve EMA stable price,
  bounded: BOLD/USDC ∈ [0.99, 1.01] (floor removable by Daddy via `depeg_mode`);
  crvUSD/USDC ≤ 1.01. Price scale 1e24 (36+6−18).
- **Keeper**: permissionless Yearn-style reporter (anyone can trigger bad-debt PPS drops).
- **Daddy** (Vyper 0.4.3): single-owner contract with a **generalized execute function**.

## Findings

### F1 (Medium-High, LIVE) — Lender withdrawals burn shares now, pay later via auction; with idle = 0 in both active markets, depositors cannot exit today
- **Verified live:** ysyBOLD Lender idle USDC = **0.00** (totalAssets $200,036.90 =
  total_debt $200,075.28); yvcrvUSD-2 Lender idle = **0.00** ($100,003.43). Both markets
  are 100% deployed.
- **Withdraw flow (TokenizedStrategy._withdraw):** idle < assets → `freeFunds(shortfall)`
  → TroveManager.redeem → kicks redemption auction (proceeds go to the RECEIVER, not the
  strategy) → strategy balance still 0 → `assets` lowered to 0 → **shares burned in
  full** → transfer 0. The depositor's payout = future auction proceeds (up to the freed
  debt), with uncertain timing and price. Default `maxLoss` = 100% → no revert even on
  total shortfall.
- **Auction activity:** 0 `AuctionKick` + 0 `AuctionTake` on the ysyBOLD market's
  auction in the last ~2.7 days. The escape hatch is cold.
- **Impact:** depositors' only exit is a taker-dependent Dutch auction of illiquid
  Yearn-vault-share collateral; `re_kick` is permissionless (revivable) but nothing
  creates buyers. Worst case: shares gone, payout never. This is a real, current
  depositor-liquidity freeze.
- *Recommendation: idle floor / reserve ratio, a user-triggerable redemption path with
  make-whole, or revert-on-shortfall (maxLoss enforcement) so shares aren't burned
  against an unguaranteed claim.*

### F2 (Medium) — Withdrawal share-burn vs async payout asymmetry (no make-whole)
Shares are burned at the CURRENT PPS; the payout is the FUTURE auction price. If the
auction fills below PPS (price decay, oracle lag, BOLD depeg with `depeg_mode`), the
loss is borne entirely by the withdrawing depositor while `totalAssets` was already
reduced in full — remaining depositors keep full PPS. Same root as F1; report together.

### F3 (Info) — Daddy centralization (oracle floor + registry control)
`Daddy` is a single-owner contract with a generalized `execute`; owner controls
`depeg_mode` (removes the BOLD/USDC 0.99 floor → collateral ratios collapse →
liquidations) and market endorsement. Two-step transfer but **no timelock/multisig**.
If the owner key is compromised, the oracle floor can be dropped at will.

### F4 (Info) — Oracle note: the unbounded leg is vault PPS
BOLD/crvUSD legs are bounded (±1%), but the vault `convertToAssets` leg is unbounded.
The collateral vaults are Yearn TokenizedStrategy (tracked `_totalAssets` —
donation-resistant), EXCEPT the ysyBOLD "LV2SPStakerStrategy" whose `_harvestAndReport`
returns `asset.balanceOf(this)` — a donation + harvest inflates PPS. Borrow-profit math
doesn't beat the donation cost (borrow ≤ ~90% of inflated value < donation + collateral),
so not exploitable today — but the strategy's balance-based reporting is the soft spot
if the vault or its accountant ever holds less than reported.

### F5 (Info) — v1→v2 hardening diff (retired markets)
v1 (yvUSD market d82db989 active until Aug 8; SIUSD 484e3c28 until Jun 13) had **no
`@nonreentrant` and no `repay_cooldown`**; v2 added both + callbacks. The retired
markets hold 0 collateral now — the fix pattern confirms the class was found.

## Verified clean (no finding)

- Reentrancy: all mutating functions `@nonreentrant` (v2); CEI ordering; Auction has
  nonreentrancy pragma; callbacks after state updates.
- Oracle: bounded stable legs; no one-block manipulation (Curve EMA + caps); vault PPS
  tracked (donation-resistant) for the Lender and most collateral.
- Lender PPS: `(idle + total_debt − fees)/supply` — no inflation vector found; keeper
  permissionless so bad debt can always be reported.
- Cooldowns (repay_cooldown blocks atomic borrow+repay), min_debt, deterministic trove
  IDs, sorted-trove re-insert integrity.
- No direct theft / share-inflation / accounting-drain path found.

**Bottom line:** the core lending logic is carefully built (the v2 hardening shows
intent), but the **depositor exit path is broken in practice** — both markets sit at
100% deployment with zero idle, and withdrawals convert to unguaranteed future auction
claims. That's the reportable item: tell the team about F1/F2. F3 is the standard
centralization note.
