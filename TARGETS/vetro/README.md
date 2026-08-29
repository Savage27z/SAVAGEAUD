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

## Findings (deep pass)

### F1 — VETBTC automated yield loop is dead (operator misconfiguration) — 🟡 Medium ops
The VETBTC Treasury has **no KEEPER_ROLE holder** (keeper EOA: False, Safe: False,
YieldManager: False). `YieldManager.harvestAndDistribute` reverts for everyone
(verified via simulation). Yet the VETBTC YieldDistributor receives `distribute()`
calls **directly from the keeper EOA** (`0x7b6027...`, tx `0x6baf...` selector
`0x91c05b0b` = distribute(uint256)) — the keeper is **manually funding vetBTC staker
yield out-of-band**, bypassing the intended harvest→mint→distribute chain.
Impact: vetBTC yield distribution depends on manual keeper action; treasury excess
for vetBTC is never harvested through the designed path. The VUSD stack works
correctly (keeper CAN trigger YM_VUSD.harvestAndDistribute — verified OK).

### F2 — Vault share-price reporting is frozen (no keeper/maintainer on vaults) — 🟡 Low-Medium ops
All six WhitelistedYieldVaults have **zero keeper/maintainer set** (`isKeeper`/`isMaintainer`
False for keeper EOA AND Safe; `report()`, `reportEarning()`, `reportLoss()` all revert
as a random caller). The vaults' `totalDebt` is therefore **stale**: on-chain gap vs
strategy `tvl()` — USDT 6.4 USDT, USDC 29.2 USDT, frxUSD 3.37e18, WBTC 20 wei. The
Treasury's `reserve()`/`withdrawable()` read this stale book value, so the protocol
**undervalues its collateral** and the intended report-based yield accrual never fires.
Not exploitable today (undervaluation is conservative), but the accounting rails are
not operating as designed.

### F3 — Book value vs deliverable liquidity on the redemption path — 🟡 Low (latent)
`Treasury.withdrawable()` = token balance + `vault.convertToAssets(shares)` — book
value. The vault holds almost everything in strategies (USDT vaultLiquid 17K wei of
127K; WBTC 50 wei of 24,250). Withdrawal only works if the Morpho market / Lagoon
can actually deliver. Today the sims pass, but the team's own `MockYieldVaultRealistic`
models the exact failure ("convertToAssets(shares) exceeds what withdraw() can
deliver") — if Morpho liquidity dries up (withdrawal caps, curate pause) or a Lagoon
strategy is funded (async-redeem only), user redemptions would revert while
`previewRedeem`/`maxWithdraw` show full book value. ATOMA-class seam.

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
