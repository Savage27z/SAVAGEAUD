# VETRO — Audit Summary

**Target:** VETRO — CDP / pegged-asset issuance (VUSD, vetBTC) on Ethereum mainnet
**Date:** 2026-08-29
**Auditor workflow:** TMAAR → deployed-code verification → multi-pass hunt
**Deployed commit:** main @ 3c063a0394 (repo pushed 2026-08-18), Sourcify exact_match confirmed
**Audited commit (QS, Feb-Mar 2026):** b0507cb — Hemi-chain VUSD only

## Verdict: 🟡 Clean of critical/high — observations documented

## Scope covered

- **Deployed vs audited drift verified**: 1,436 insertions / 774 deletions + 4 new files
  (YieldManager, ChainlinkFeedAdapter, DerivedPriceFeedAdapter, FixedPriceFeedAdapter)
- **On-chain verification**: all 15 contracts live on Ethereum, Sourcify exact_match,
  repo main == deployed bytecode (hash-verified)
- **QS fixes re-checked in deployed code**:
  - HV-1 (orphaned yield) → FIXED: `distribute()` computes `_remaining = (periodFinish - lastUpdateTime) * rewardRate` ✅
  - HV-2 (stale conversion in StakingVault) → FIXED: `_pullYield()` before preview in `_requestRedeem`/`_requestWithdraw` ✅
  - HV-3 (AMO supply invariant) → FIXED: burn is gateway-gated, `burnFromAMO` enforces amoSupply ✅
  - HV-4 (oracle tolerance) → reworked with peg-band (see O1)
- **Roles verified on-chain**: SAFE multisig is owner; YieldManager has UMM (both treasuries) + DISTRIBUTOR (both YDs); keeper EOA 0x7b6027... has KEEPER_ROLE + instant-redeem whitelist on VUSD

## Live state (2026-08-29)

- VUSD totalSupply 543.8K, reserve 548.8K, amoSupply 10, mintLimit 100M
- vetBTC supply 588.6K (0.588 BTC), reserve 588.5K
- VUSD StakingVault: 72.9K sVUSD supply, 74.2K assets, 7d cooldown, 7.96K in cooldown
- VETBTC StakingVault: 39.3K sVETBTC, 1d cooldown
- YieldDistributor: active drip both stacks (rate/finish set)
- Whitelisted: VUSD [USDT, USDC, frxUSD]; VETBTC [WBTC, cbBTC, hemiBTC]
- Fees: mintFee/redeemFee all 0; pegBand 3bps (USDT/USDC), 0 (others)
- Vaults: Yearn V3-style (WhitelistedYieldVault + 2 strategies each), only Treasury whitelisted

## Findings

### O1 — Peg-band pricing asymmetry (HV-4 rework) — 🟡 Informational
`Gateway._calculatePeggedTokenOutput/_calculateTokenOutput` par-price within `pegBand`
(floor=1−band, ceiling=1+band), adjust by oracle outside. `_effectivePegBand` zeroes a
band ≥ tolerance (post-fix, bd0fcfb64e). Direction check: mint uses floor only, redeem
uses ceiling only → protocol extracts the depeg premium in both directions within
tolerance. Live pegBand 3bps / tolerance 100bps. Sound, but the accepted band is
asymmetric by design (documented HV-4 family).

### O2 — FixedPriceFeedAdapter for WBTC = permanent price blindness — 🟡 Informational
WBTC oracle is the new FixedPriceFeedAdapter (returns 1.0 WBTC/BTC forever, `updatedAt =
block.timestamp` always). The Treasury's staleness check and tolerance check can NEVER
trigger for WBTC. If WBTC depegs from BTC (custody event), the reserve silently
overstates collateral and mint/redeem continue at par. Code comment documents intent
("WBTC is 1:1 by construction") — but the deployed system has zero monitoring signal.

### O3 — First-depositor captures orphaned yield after vault empties — 🟡 Low
`StakingVault._pullYield()` skips when `totalSupply()==0`. If all shares are redeemed,
yield keeps dripping into the YieldDistributor. The first new depositor mints at 1:1
(supply 0 → totalAssets 0), then the NEXT interaction pulls ALL accumulated pending
yield into the vault, inflating their share price to capture the full orphaned pool.
The dev comment acknowledges the skip ("prevent orphan yield... diluting users canceling
withdrawals") but the consequence is a first-depositor windfall of any yield accrued
while empty. Not reachable today (72.9K supply), but a real economic seam in the
empty→refill transition.

### O4 — Cross-token oracle coupling: one stale feed DoSs whole-system harvest — 🟡 Low
`Treasury.reserve()` (used by `harvest` → `YieldManager.harvestAndDistribute`) iterates
ALL whitelisted tokens and reverts if ANY oracle is stale or out of tolerance. A single
feed (e.g. frxUSD/USD 24h heartbeat, stalePeriod 25h; or HEMIBTC/BTC 18-dec feed) going
stale freezes excess harvesting and yield distribution for the entire stack — even when
the other tokens are perfectly healthy. Fail-closed by design, but the coupling means
one weak feed = whole-system yield stall.

### O5 — Gateway withdrawal delay = 120 seconds — 🟡 Informational
Deployed `withdrawalDelay` is 2 minutes (config `2*60`), delay ENABLED. The QS
bank-run mitigation (HV-7 acknowledged) is effectively absent on the VUSD→collateral
redemption path — a depeg would let holders exit at par within 2 minutes. StakingVault
cooldown (7d) is the real protection; Gateway delay is cosmetic.

### O6 — Keeper EOA centralization — 🟡 Informational
KEEPER_ROLE on both treasuries is a single EOA (0x7b6027... on VUSD, verified). Keeper
can pull/push vault funds, toggle deposit/withdraw active, swap non-whitelisted tokens,
and trigger harvest/distribute timing. Single-key control of yield timing + pause toggles.
Standard keeper model; worth noting for the trust model.

## What was NOT found (negative results)

- No reentrancy across the harvest→deposit→distribute chain (nonReentrant on all paths)
- No rounding exploit in mint/redeem previews (Ceil on inputs, Floor on outputs, verified)
- No fee-on-transfer bypass (`_executeDeposit` delta check)
- No AMO supply underflow (gateway-only burn + amoSupply invariant enforced)
- No stale-price bypass in the derived feed (uses min of both feeds' updatedAt)
- No instant-redeem bypass via locked+wallet split (Case 2 requires whitelist for excess)
- Vault proxies only allow Treasury (whitelist verified); no donation/first-depositor
  vector on the yield vaults (deposit is whitelist-gated)
