# Ravenhood Protocol — Deflationary Treasury Protocol

**Chain:** Robinhood Chain (4663)
**Date:** Jul 24, 2026
**Status:** 🟢 Clean

**Audited contracts:** Ravenhood (RVH token), RavenhoodVault, RVHStakingPool — all verified on Blockscout

## Overview

Deflationary treasury protocol on Robinhood Chain. 95% of the 100M RVH supply was seeded as a single-sided, permanently locked Uniswap V3 LP position. LP fee revenue is collected by the Vault and sent to the owner for buyback/burn (handled off-chain). A separate staking pool lets users stake RVH for 12-month emissions with a 30-day lock and 5% early exit tax.

**Category:** Volume Boosting / Deflationary Treasury (non-DEX)
**TVL:** $0 (StakingPool) — treasury $56K (LP position + DAO wallet)
**Cumulative Fees:** $6.2K
**Twitter:** @RVHProtocol

## Contracts

| Contract | Address | Role |
|----------|---------|------|
| Ravenhood (RVH) | `0x96765066f6a040a21EB027167D2315B707c82633` | ERC-20, 100M supply, ownership renounced |
| RavenhoodVault | `0x5e1485137E025bf7774F52DE4E33fa6E498f6ede` | Locked Uniswap V3 LP position (NFT #17757), fee collection & liquidity burn |
| RVHStakingPool | `0xAc558b558E228DE033Cd97C580618C4403CB05a6` | MasterChef-style staking with 30-day lock & 5% early exit tax |

## TMAAR

Full TMAAR in `TMAAR.md`. Key actors:
- **Vault Owner** (`0xf652...b533`) — controls liquidity burn, different from DAO wallet
- **DAO Wallet** (`0x097...cdc`) — controls StakingPool, holds initial supply, is Vault DEPLOYER
- **RVH Token** — ownership renounced, supply permanently fixed

## Passes Performed

| Phase | Layer | Status |
|-------|-------|--------|
| Pre-audit | What Changed (Macro library check) | ✅ Checked Macro for similar treasury/burn patterns |
| 0: Recon | Surface map | ✅ Contracts verified, on-chain state confirmed |
| 0.5: TMAAR | Trust model | ✅ Actors, assumptions, risks documented |
| 1: Read | Feynman — all 3 contracts | ✅ RVH token (12 LOC) + Vault (58 LOC) + StakingPool (406 LOC) |
| 2: Hunt | Open-Kritt multi-agent (6 perspectives) | ✅ Access, reentrancy, math, MEV, tokenomics, centralization |
| 3: Tools | Slither | ⏭️ Skipped (no compileable Foundry project) |
| 3b: Triage | BountyForge 4-gate | ✅ Reality → Impact → Dedup → Quality |
| 4: Fork | On-chain verification | ✅ RPC calls confirmed owner, supply, nftId, staking state |
| **5: Deep Second Pass** | **Focused re-read** | ✅ **Centralization analysis, Vault fee routes, burn mechanism economic bounds, owner separation** |

## Analysis Summary

- **No reentrancy** — StakingPool uses `nonReentrant` on all externals; Vault has no reentrancy risk;
- **No upgrade risk** — all contracts are non-proxy, immutable ✅
- **RVH supply permanently fixed** — ownership renounced, no mint function ✅
- **LP is truly locked** — Vault has no withdraw/unlock function, confirmed on-chain ✅
- **StakingPool uses correct MasterChef accumulator** — standard pattern with precision factor ✅

## Findings

The following are design observations and fragility points — **none are exploitable vulnerabilities**:

| # | Contract | Issue | Impact | Likelihood | Risk |
|---|----------|-------|--------|------------|------|
| 1 | Vault | `claimBurn()` uses `amount0Min: 0, amount1Min: 0` — no slippage protection on liquidity burn; owner can be MEV-sandwiched for worse pricing | Medium | Low | 🟢 |
| 2 | Vault | `claimFees()` is permissionless — anyone can trigger fee collection at any time; fees always go to owner so no fund loss, but timing control is ceded | Low | High | 🟢 |
| 3 | StakingPool | `emergencyRewardWithdraw()` lets owner (single EOA) drain unclaimed rewards — documented but real centralization risk | High | Low | 🟡 |
| 4 | StakingPool | No stakers (~0 RVH staked on-chain) — rewards accumulating but unclaimed; owner could drain via #3 above | Low | High | 🟢 |
| 5 | Protocol | **No on-chain buyback mechanism** — despite "deflationary burn engine" description, Vault only collects fees to owner; actual buyback is off-chain with no on-chain enforcement | Medium | Medium | 🟡 |
| 6 | Protocol | **Vault owner ≠ DAO wallet** — two separate trust anchors; Vault owner can burn LP liquidity independently of DAO governance | Medium | Low | 🟡 |
| 7 | RVH Token | Ownership renounced — no recovery path for any token issues (positive for decentralization, negative for recoverability) | Low | Low | 🟢 |
| 8 | StakingPool | Precision rounding dust — standard MasterChef pattern, dust accumulates in contract | Low | High | 🟢 |

## Notes from Deep Second Pass

Focused re-read with centralization and economic analysis angles:

- **Centralization analysis**: The Vault owner (`0xf652...b533`) is distinct from the DAO wallet (`0x097...cdc`). Vault owner can call `claimBurn()` to extract LP liquidity. There's no timelock or governance. The DAO wallet (EOA) controls the StakingPool including all reward withdrawals.

- **No on-chain buyback**: The "deflationary burn engine" tagline isn't reflected in the Vault code. `claimFees()` sends LP fees to the owner without any requirement to use them for buybacks. The actual buyback loop depends entirely on the owner performing it off-chain. Anyone looking at the contracts expecting an automated buyback would be misled.

- **Burn mechanism economics**: `claimBurn()` removes 0.5% of remaining liquidity per call (asymptotic — 200 calls removes ~63%). With `amount0Min = 0`, the owner accepts any price. At the current TVL (~$56K in the LP position), each burn removes ~$280 worth of liquidity.

## Verdict

**🟢 Clean.** Ravenhood is a simple, well-structured protocol with clean contracts that follow standard patterns (solmate ERC20, MasterChef staking, Uniswap V3 LP locker). No exploitable vulnerabilities found.

The main observations are architectural: the Vault owner is a different address from the DAO wallet (two trust anchors), there's no on-chain buyback automation despite the "burn engine" branding, and the StakingPool owner can drain unclaimed rewards at will. At current scale ($0 staked, $56K treasury) none of these are actionable, but they're worth noting as the protocol grows.

The three contracts are sound — reentrancy-safe, no upgrade paths, supply permanently fixed, LP truly locked.
