# VETRO — Audit Summary (Deep Pass)

**Target:** VETRO — CDP / pegged-asset issuance (VUSD, vetBTC) on Ethereum mainnet
**Date:** 2026-08-29
**Passes:** TMAAR → deployed-code verification → multi-pass hunt → **deep pass (vaults/strategies/roles)**

## Verdict: 🟡 Clean of critical/high — 2 operational findings + observations

## Deep-pass scope (what the first pass missed)

- **WhitelistedYieldVault (Yearn V3-style)**: all 6 collateral vaults share impl `0xf98f32...`,
  ERC-1967 proxies, only the Treasury is whitelisted for deposit/withdraw
- **Strategies identified per vault** (Vesper framework):
  - USDT → MorphoVaultV2 (`0xdf9a...`), LagoonV06 (`0x4089...`, debt=0)
  - USDC → MorphoVaultV2 (`0x3ec3...`, 344K debt) + 2 idle ERC4626Vaults + idle Lagoon
  - frxUSD → MorphoVaultV2 (`0x3ec3...`, 77K debt)
  - WBTC → ERC4626Vault (`0x61ce...`, 24,250 debt)
  - cbBTC → MorphoVaultV2 (`0x3ec3...`, 5.8K debt), hemiBTC → idle
- **Withdrawal path simulated on-chain** (eth_call as Treasury):
  - Morpho vault `withdraw(1)` → OK (maxWithdraw=0 is a Morpho quirk the strategy
    works around with convertToAssets — NOT a hard revert; verified)
  - WhitelistedYieldVault `withdraw(1000)` → OK
- **Roles re-verified**: Safe = owner/governor everywhere; keeper EOA `0x7b6027...`
  has KEEPER+MAINTAINER (VUSD Treasury), DISTRIBUTOR (both YDs), but **NO roles on
  VETBTC Treasury**; YieldManager has UMM (both) + DISTRIBUTOR (both)

## Findings (deep pass) — RE-VERIFIED 2026-08-30 (all claims checked on-chain)

### F1 — VETBTC automated yield loop is dead (operator misconfiguration) — 🟡 Medium ops
**VERIFIED.** Role matrix (eth_call on `hasRole`, latest block 25,864,311):
- Keeper EOA `0x7b6027ba861a99ffbfafb19b44934ce9b042fbef` (EOA, no code):
  VUSD Treasury KEEPER=**True** MAINTAINER=**True**; VETBTC Treasury KEEPER=**False**
- Safe `0x6649Ddb5...`: VETBTC Treasury KEEPER=False (ADMIN=True — Safe is the real
  admin; OPERATIONS.md table claiming `0xE173b056...` as on-chain admin is STALE,
  that address is an EOA with zero code and only KEEPER on VUSD)
- YieldManagers: VETBTC Treasury KEEPER=False for both
- `YieldManager.harvestAndDistribute(USDT,0)` simulated as keeper EOA:
  **YM_VETBTC → reverts** (no KEEPER on VETBTC Treasury → `AccessControlUnauthorizedAccount`);
  **YM_VUSD → OK** (keeper holds KEEPER there). Correct selector `0x32062d30`
  (round-1 zero-arg selector was wrong — this supersedes it).
- Yet VETBTC YieldDistributor receives **22 `distribute()` calls directly from the
  keeper EOA** (all `status: ok`), latest tx `0x6bafd3b44a9eb062...` block 25,841,340 —
  receipt shows vetBTC `Transfer` + `YieldDistributed` (`0x43d542a8...`). The keeper
  holds DISTRIBUTOR_ROLE on both YDs directly, so they can bypass the YieldManager.
Impact: vetBTC yield is manually funded out-of-band by the keeper (their own vetBTC),
not harvested treasury excess; the designed harvest→mint→distribute chain is dead on
the vetBTC side. VUSD stack works correctly (verified OK).

### F2 — Vault share-price reporting is frozen (no keeper/maintainer on vaults) — 🟡 Low-Medium ops
**VERIFIED.** All six WhitelistedYieldVaults: `isKeeper`/`isMaintainer` = **False**
for keeper EOA AND Safe (checked both the OZ `hasRole`-style and the vault's own
`isKeeper`/`isMaintainer`). `reportEarning(0,0,0)` as keeper EOA → **reverts on all 6**;
`reportLoss(1)` → reverts (note: `reportLoss(0)` returns OK — zero is a no-op that
skips the role check; nonzero reverts). `totalDebt` is stale vs strategy `tvl()`:
- USDT: totalDebt 127,297,212,249 vs tvl 127,303,905,471 → gap **6.69 USDT**
- USDC: 344,198,675,379 vs 344,229,362,206 → gap **30.69 USDT**
- frxUSD: 77.3029e18 vs 77.3065e18 → gap **3.54 frxUSD**
- WBTC: 24,250,202 vs 24,250,223 → gap **21 wei**
- cbBTC: 5,880,714 vs 5,895,562 → gap **0.000148 cbBTC** (14,848 units)
The Treasury's `reserve()`/`withdrawable()` read this stale book value, so the
protocol **undervalues its collateral** (conservative, not exploitable) and the
intended report-based yield accrual never fires on any vault.

### F3 — Book value vs deliverable liquidity on the redemption path — 🟡 Low (latent)
**VERIFIED with corrected units.** `Treasury.withdrawable()` = token balance +
`vault.convertToAssets(shares)` = book value. USDT vault: liquid token balance
**17.2 USDT** (17,198,382 wei) of book **127,314 USDT**; WBTC vault: **50 wei**
liquid of 24,250 wei book. Morpho Vault V2 receipt token `0x23f5e9c35820f4bab695ac1f19c203cc3f8e1e11`
holds strategy shares worth 127,303,913,135 USDT and reports **`maxWithdraw(strategy)=0`
AND `maxRedeem(strategy)=0`** — the strategy's code comment ("Morpho Vault V2 return 0
for maxWithdraw() so using convertToAssets() instead") is confirmed accurate.
Withdrawal simulation (eth_call as Treasury, correct `withdraw(uint256,address,address)`):
withdraw(1), withdraw(1,000), withdraw(100,000), and withdraw(maxWithdraw=127,314,410,630)
**all OK today** — the strategy's convertToAssets workaround covers the Morpho quirk,
so this is NOT a live revert. It is a latent ATOMA-class seam: if Morpho liquidity
dries up (withdrawal caps, curate pause, vault shutdown) or a Lagoon strategy is
funded (async-redeem only), user redemptions would revert while
`previewRedeem`/`maxWithdraw` still show full book value. The team's own
`MockYieldVaultRealistic` models exactly this failure.

### F4 — Cross-token oracle coupling DoS on harvest — 🟡 Low (from first pass, retained)
`Treasury.reserve()` (→ `harvest` → `YieldManager.harvestAndDistribute`) reverts if
ANY whitelisted token's oracle is stale or out of tolerance. One bad feed (frxUSD/USD
24h heartbeat; HEMIBTC/BTC 18-dec feed) freezes yield distribution for the entire stack.

## First-pass observations retained (Informational)

- O1 peg-band pricing asymmetry (HV-4 rework) — par within band, oracle-adjusted outside; sound
- O2 WBTC FixedPriceFeedAdapter = permanent price blindness + never-stale (by design, documented)
- O3 empty-vault first-depositor captures orphaned pending yield (low likelihood)
- O5 Gateway withdrawalDelay = 120s (bank-run mitigation cosmetic; StakingVault 7d cooldown is real)
- O6 Keeper EOA single-key control of yield timing + pause toggles (VUSD stack)

## Negative results (verified clean)

- No reentrancy across harvest→deposit→distribute (nonReentrant everywhere)
- No rounding exploit in mint/redeem previews (Ceil inputs / Floor outputs)
- No fee-on-transfer bypass (delta check in `_executeDeposit`)
- No AMO supply underflow (gateway-only burn + invariant)
- No stale-price bypass in derived feed (min of both feeds' updatedAt)
- No instant-redeem bypass via locked+wallet split (Case 2 whitelist-gated)
- Withdrawal path actually delivers (simulated on-chain) — maxWithdraw=0 not exploitable
- Vault proxies only allow Treasury; no donation/first-depositor vector on yield vaults

## Bottom line
The deployed code is genuinely well-hardened and the QS fixes are correctly applied.
The deep pass found the real issues are **operational**: the vetBTC keeper role was
never granted (F1), and the vault reporting roles were never set (F2). Neither is a
fund-loss exploit, but both mean parts of the system are running on manual rails —
the kind of thing a team would want to know, and exactly what the audit-gap framing
(never-audited YieldManager + adapters + upgrades) was hunting for.
