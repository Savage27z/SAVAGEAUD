# VETRO Security Disclosure — Operational Findings (2026-08-30)

**To:** Vetro Protocol team (vetro-protocol, contact@vetro.org)
**From:** Independent security researcher
**Scope:** Deployed contracts on Ethereum mainnet (`vetro-protocol/vetro-contracts`)
**Severity:** No fund-loss exploit found. Three operational/robustness findings.
**Status:** All claims verified on-chain (block 25,864,311) before this disclosure.

---

## F1 — VETBTC automated yield loop is dead (Medium, operational)

The VETBTC Treasury has **no KEEPER_ROLE holder**. The designed chain is:

    keeper → YieldManager.harvestAndDistribute → Treasury.harvest → Gateway.deposit → YieldDistributor.distribute

In practice:
- Keeper EOA `0x7b6027ba861a99ffbfafb19b44934ce9b042fbef` holds KEEPER_ROLE on the VUSD
  Treasury (verified `hasRole` = True) but **NOT** on the VETBTC Treasury (`hasRole` = False).
- `YieldManager.harvestAndDistribute(USDT, 0)` simulated as the keeper:
  - `YM_VETBTC` → **reverts** (`AccessControlUnauthorizedAccount`)
  - `YM_VUSD` → **OK**
- Instead, the VETBTC YieldDistributor receives **22 `distribute()` calls directly from
  the keeper EOA** (all `status: ok`), e.g. tx `0x6bafd3b44a9eb062948622619c8960ec8e6f13638555b40d061e65c5ca65e449`
  (block 25,841,340) — receipt shows vetBTC `Transfer` + `YieldDistributed`.
  The keeper holds DISTRIBUTOR_ROLE on both YieldDistributors directly, so the
  YieldManager is bypassed.

**Impact:** vetBTC staker yield is manually funded by the keeper's own vetBTC, not from
harvested treasury excess. If the keeper stops, yield stops with no alarm. The
designed harvest→mint→distribute loop never runs for vetBTC.

## F2 — Vault share-price reporting is frozen (Low–Medium, operational)

All six `WhitelistedYieldVault`s have **no keeper/maintainer**:
- `isKeeper` / `isMaintainer` = **False** for the keeper EOA AND the Safe
  (`0x6649Ddb5c7e52348b73c8bBdD2A1cbA630b7AaEA`) on every vault.
- `reportEarning(0,0,0)` as keeper → **reverts on all 6**; `reportLoss(1)` → reverts
  (`reportLoss(0)` is a zero no-op that skips the role check).

`totalDebt` is therefore stale vs strategy `tvl()` (live numbers):

| Vault | totalDebt | strategy tvl | gap |
|-------|-----------|--------------|-----|
| USDT  | 127,297,212,249 | 127,303,905,471 | **+6.69 USDT** |
| USDC  | 344,198,675,379 | 344,229,362,206 | **+30.69 USDT** |
| frxUSD| 77.3029e18 | 77.3065e18 | **+3.54 frxUSD** |
| WBTC  | 24,250,202 | 24,250,223 | **+21 wei** |
| cbBTC | 5,880,714 | 5,895,562 | **+0.000148 cbBTC** |

**Impact:** `Treasury.reserve()` / `withdrawable()` read stale book value — the
protocol **undervalues its collateral**. Conservative (not exploitable), but the
intended report-based yield accrual never fires.

## F3 — Book value vs deliverable liquidity (Low, latent)

`Treasury.withdrawable()` = token balance + `vault.convertToAssets(shares)` (book value).
Almost all collateral sits in strategies:
- USDT vault: **17.2 USDT liquid** (17,198,382 wei) of **127,314 USDT** book
- WBTC vault: **50 wei liquid** of 24,250 wei book

Morpho Vault V2 receipt token `0x23f5e9c35820f4bab695ac1f19c203cc3f8e1e11` holds strategy
shares worth 127,303,913,135 USDT and reports **`maxWithdraw(strategy)=0`** and
**`maxRedeem(strategy)=0`**. The strategy code works around this with
`convertToAssets` (comment confirms). Simulated withdrawals as Treasury —
withdraw(1), withdraw(1,000), withdraw(100,000), withdraw(maxWithdraw=127,314,410,630) —
**all OK today**. If Morpho liquidity ever dries up (withdrawal caps, pause, shutdown)
or a Lagoon strategy gets funded (async-redeem only), redemptions would revert while
`previewRedeem`/`maxWithdraw` still show full book value.

## Verified clean

- No reentrancy (nonReentrant on harvest→deposit→distribute)
- No rounding exploit in mint/redeem previews
- No fee-on-transfer bypass (delta check)
- No AMO supply underflow (gateway-only burn)
- No instant-redeem bypass
- Withdrawal path actually delivers today

## Suggested fixes

1. Grant KEEPER_ROLE on VETBTC Treasury to the keeper EOA (or a dedicated keeper),
   or grant it to the Safe and run the YieldManager path for vetBTC.
2. Set vault keepers/maintainers (Safe or keeper) so `reportEarning` can run.
3. Consider a withdrawal-cap/liquidity check on the redemption path so
   `previewRedeem` reflects deliverable liquidity, not book value.
