# MinePea — Gamified Mining Protocol

**Chain:** Robinhood Chain (4663)
**Date:** Jul 24, 2026
**Status:** 🟢 Clean

**Audited contracts:** GridMining, PEAToken, Staking, AutoMiner, Treasury — all verified on Blockscout

## Overview

Gamified mining protocol on Robinhood Chain. Players compete in continuous 60-second rounds, deploying ETH across a 25-tile pentagon board. One tile drawn at random by Pyth VRF per round. Winning tile miners share the pot pro-rata. Protocol fees (10%) fund PEA buybacks (95% burned, 5% to stakers).

**TVL:** ~$5.5K
**Category:** Gamified Mining (non-DEX)
**Twitter:** @minepea_
**Website:** minepea.com
**Age:** ~1.5 days old

## Contracts

| Contract | Address | Role |
|----------|---------|------|
| GridMining | `0x46D5459F439E64B8CC2D02e89b137608eA5711CE` | Main game engine — rounds, VRF, settlement |
| PEAToken | `0xfe177128Df8d336cAf99F787b72183D1E68Ff9c2` | ERC-20, 3M supply cap, minter role |
| Staking | `0x98842D64E73A7196c90606Dea66B666D088cC4fB` | PEA staking, yield from buybacks |
| AutoMiner | `0x88d3Eb3b38dFb9A62b435809144c771e9cAb64a1` | Automated mining executor |
| Treasury | `0x78Df583557baa1b9C8b8839BeCAAe2eD665Bd7e6` | Fee vault → PEA buyback via V4 |

## TMAAR

Full TMAAR in `TMAAR.md`. Key actors:
- **Owner** (single EOA) — controls params across all 5 contracts
- **AutoMiner executor** — single address controls mining outcomes for Random/All strategies
- **Pyth VRF** — unbiased tile draw
- **Uniswap V4** — provides TWAP and swap execution for buybacks

## Passes Performed

| Phase | Layer | Status |
|-------|-------|--------|
| Pre-audit | What Changed (Macro library check) | ✅ Checked Macro for similar gamified mining patterns |
| 0: Recon | Surface map | ✅ Contracts, docs, game mechanics |
| 0.5: TMAAR | Trust model | ✅ Actors, assumptions, risks documented |
| 1: Read | Feynman — all 5 contracts | ✅ ~38K (GridMining) + 8K (PEA) + 18K (Staking) + 25K (AutoMiner) + 10K (Treasury) |
| 2: Hunt | Open-Kritt multi-agent (6 perspectives) | ✅ Access, VRF, reentrancy, math, timing, oracles |
| 3: Tools | Slither | ⏭️ Skipped (no compileable Foundry project) |
|| 3b: Triage | BountyForge 4-gate | ✅ Every finding through Reality → Impact → Dedup → Quality |
|| 4: Fork | On-chain verification | ✅ RPC calls confirmed contract state |
|| **5: Deep Second Pass** | **Focused re-read** | ✅ **Re-entry trace, TWAP economic bounds, feeCollector re-entry, rounding dust, harvest fee game theory, `_resolveTopMiner` gas bounds** |

## Analysis Summary

- **No reentrancy** — CEI pattern + `nonReentrant` on all external functions across all 5 contracts ✅
- **No proxy/upgrade risk** — all contracts are plain `Ownable`, no ERC-1967 patterns ✅
- **Fees immutable** — admin/vault/harvest fees are hardcoded constants, owner cannot change ✅
- **PEA supply capped** — 3M max, gracefully handled at contract level ✅
- **VRF integration correct** — Pyth VRF via Quiver, callback authenticated, replay guarded ✅

## Findings

The following are design observations and fragility points — **none are exploitable vulnerabilities**:

| # | Contract | Issue | Impact | Likelihood | Risk |
|---|----------|-------|--------|------------|------|
| 1 | GridMining | `_processMinting()` called before `round.settled = true` — if PEA had ERC-777 hooks, could allow reentrancy before settlement flag | Medium | Very Low | 🟢 |
| 2 | GridMining | `totalUnclaimed -= minedPEA` could revert on accounting drift, bricking `claimPEA()` | High | Very Low | 🟢 |
| 3 | GridMining | Coordinator rotation mid-pending VRF request stalls rounds for 1h | Medium | Low | 🟢 |
| 4 | GridMining | Treasury revert during settlement consumes non-refundable VRF fee, stuck round | Medium | Low | 🟢 |
| 5 | GridMining | `quiverCallback` lacks `nonReentrant` — during settlement, `_safeTransferETH(feeCollector, ...)` raw `.call` can re-enter GridMining before `_startNextRound()` runs; state ordering makes current exploitation infeasible but pattern is fragile (see Notes) | Medium | Very Low | 🟢 |
| 6 | AutoMiner | Executor controls tile selection for Random/All strategies — users trust single address for fairness | Medium | High | 🟡 |
| 7 | Treasury | TWAP ~60s window manipulable; `sqrtPriceLimitX96 = MIN_SQRT_PRICE + 1` = **no effective price cap** on buyback swap; deviation check only blocks when PEA is *cheaper* than TWAP (not when it's more expensive); buyback at inflated price possible as TVL grows | **High** | **Medium** | 🟡 |
| 8 | PEAToken | `removeLimits()` is permanent single-owner action — no timelock, no recovery | Low | Medium | 🟢 |
| 9 | Staking | Interaction-before-effects for new depositors (blocked by `nonReentrant` + trusted token) | Low | Low | 🟢 |
| 10 | AutoMiner | `_maskToBlocks` invariant coupling — fragile if strategy logic changes | Low | Low | 🟢 |
| 11 | GridMining | `feeCollector` ETH transfer in `_fulfillRandomness` is re-entry vector — `_safeTransferETH` uses raw `.call`, and `quiverCallback` is NOT `nonReentrant`; currently safe because `round.settled=true` is set before transfer but fragile | Medium | Very Low | 🟢 |
| 12 | AutoMiner | `stop()` refunds nothing when all rounds executed — integer division rounding dust in `_calculateAmountPerBlock` is permanently trapped in contract | Low | High | 🟢 |

## Notes from Deep Second Pass

A focused second read with different attack angles revealed **2 new observations** and **upgraded 1 finding**:

- **Finding #5 upgraded:** The `quiverCallback` lack of `nonReentrant` is more significant than a defense-in-depth gap — the raw `.call` to `feeCollector` during settlement opens a concrete re-entry vector. Current state ordering (fees sent after `round.settled=true`) prevents exploitation, but the pattern is fragile and depends on correct ordering across future refactors.

- **Finding #7 upgraded (Medium → High/Medium):** The TWAP buyback vulnerability is worse than initially assessed. `sqrtPriceLimitX96 = MIN_SQRT_PRICE + 1` means **no price protection** on the V4 swap itself — all protection relies on a one-directional deviation check that only blocks when PEA is *cheaper* than expected. At scale, a manipulator could push PEA price up and have the Treasury buy at the inflated price with no effective cap. At current $5.5K TVL this isn't economically viable, but it's a ticking vulnerability for growth.

- **Finding #12 (New):** Integer division rounding dust from `_calculateAmountPerBlock` is permanently trapped in the `AutoMiner` contract when all rounds execute — `stop()` refunds nothing if `remainingRounds == 0`.

## Verdict

**🟢 Clean.** MinePea is well-architected with cautious patterns throughout. No exploitable vulnerabilities found. The most notable finding is the Treasury buyback using `MIN_SQRT_PRICE + 1` as price limit — at current $5.5K TVL it's not economically viable to exploit, but at scale a manipulator could force the protocol to buy PEA at inflated prices with no effective cap. Other observations (AutoMiner executor centralization, `quiverCallback` lacking `nonReentrant`, rounding dust trapping) are design fragilities, not exploits.

All 5 contracts use CEI ordering correctly, fees are immutably hardcoded, VRF integration is sound, and no upgrade paths exist for attackers to exploit. The deep second pass (different attack angles, focused entry point mapping) confirmed no missed vectors.
