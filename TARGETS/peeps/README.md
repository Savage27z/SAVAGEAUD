# Peeps ($PEEPS) — Token Launchpad with Native Token

**Chain:** Robinhood Chain (4663)
**Date:** Jul 24, 2026
**Status:** 🟢 Clean

**Audited contracts:** PeepsCurveFactory, PeepsBondingCurve, PeepsLaunchToken, PeepsLPFeeVault, PeepsCurveMath — all verified on Blockscout

## Overview

Peeps is a bonding-curve token launchpad on Robinhood Chain with a native ecosystem token ($PEEPS). Every token launched through Peeps gets a bonding curve (virtual-reserve CPAMM), auto-graduation to Uniswap V3 at an ETH cap, and a locked LP position. Trading fees (1.5% total) are split: 1% creator, 0.4% protocol, 0.1% furnace (auto-burn). Graduated LP fees are split 40% creator / 60% protocol (20% marketing, 20% buyback, 60% treasury).

**TVL:** $26.8K (active bonding curves + locked LP vault)
**Category:** Launchpad (with native token)
**Twitter:** @peepsdotwtf
**GitHub:** Toomicky
**Age:** ~8 days (DeFiLlama start: Jul 16, 2026)

## Contracts

| Contract | Address | Role |
|----------|---------|------|
| PeepsCurveFactory | `0x138C1C551bAd0F1c43084ddbC79F5E78225Eb9dD` | Deploys tokens + curves, manages fees/params |
| PeepsBondingCurve | CREATE2 (per token) | Virtual-reserve CPAMM, fee accrual, graduation |
| PeepsLaunchToken | CREATE2 (per token) | Ownerless ERC20, 1B fixed supply |
| PeepsLPFeeVault | `0xCdD3dBb6e7e2613443d27Ffc3FB041202BBD5259` | Collects V3 LP fees, splits creator/protocol |

## Passes Performed

| Phase | Layer | Status |
|-------|-------|--------|
| Pre-audit | What Changed (Macro library check) | ✅ Checked Macro for similar bonding curve audits |
| 0: Recon | Surface map | ✅ All contracts verified on Blockscout |
| 0.5: TMAAR | Trust model | ✅ Actors, assumptions, risks documented |
| 1: Read | Feynman — all core contracts | ✅ Factory + Curve + Token + LP Vault + Math lib |
| 2: Hunt | Open-Kritt multi-agent (6 perspectives) | ✅ Access control, curve math, reentrancy, MEV, fee accounting, mapping attacks |
| 3: Tools | Slither | ⏭️ No compileable project |
| 3b: Triage | BountyForge 4-gate | ✅ Every finding through Reality → Impact → Dedup → Quality |
| 4: Fork | On-chain verification | ✅ RPC calls confirmed contracts exist |
| **5: Deep Second Pass** | **Focused re-read** | ✅ **Mapping corruption in LP vault, furnace burn edge case, graduation fee routing** |

## Analysis Summary

- **Curve math is sound** — `PeepsCurveMath` uses ceil-division for retained reserves (seller-favorable rounding). Constant product invariant is non-decreasing. ✅
- **No reentrancy** — All external functions use `nonReentrant` ✅
- **Supply truly fixed** — `PeepsLaunchToken` has no owner, no mint/burn, no hooks. Supply = 1B per token forever. ✅
- **Fee model is pull-based** — Fees accrue in-contract, claimed separately. No push risks. ✅
- **Graduation is irreversible** — Once `ReadyToGraduate`, anyone can call `graduate()`. Phase → Graduated. ✅

## Findings

| # | Contract | Issue | Impact | Likelihood | Risk |
|---|----------|-------|--------|------------|------|
| 1 | LP Fee Vault | **`onERC721Received` auto-registers arbitrary NFTs** — anyone can `safeTransferFrom` a random ERC721 to the vault with crafted `data` bytes, overwriting `tokenPosition[launchToken]` mapping. The real fees are still collectable via `collect(tokenId)` (direct path), only the address-based `collectForToken()` convenience path is broken. An attacker could also send a VALID Uniswap V3 position, causing `collectForToken` to collect fees from the wrong pool — those fees get routed to protocol addresses, not lost, but the real position's fees go uncollected | Medium | Low | 🟡 |
| 2 | Factory | **Router and migrator are one-time-set** — `setPeepsRouter()` and `setMigrator()` revert if already set. This means the owner can't swap to a malicious contract after initialization. BUT the initial values must be set correctly — the deployer has one shot. Once set, the system is locked | Medium | Low | 🟡 |
| 3 | Factory | **Global ETH cap can DOS all curves** — `recordEthDelta` tracks total ETH across curves against `globalEthCap`. If all curves collectively reach the cap, ALL new buys on EVERY curve revert until someone sells to reduce the total. A single popular curve could DOS the entire platform | Low | Low | 🟢 |
| 4 | Factory | **`perTokenEthCap < GRADUATION_ETH` footgun** — the per-token ETH cap is checked in `buy()`. If it's set below a curve's `GRADUATION_ETH`, that curve can never graduate. Pure config risk, but no bounds check prevents it | Low | Medium | 🟢 |
| 5 | BondingCurve | **Sell can reverse graduation phase** — `_syncPhaseAfterSell()` reverts `ReadyToGraduate` back to `Trading` if a sell drops real ETH below the cap. A motivated actor could repeatedly buy-to-cap then sell-to-reverse, locking a token in perpetual "almost graduated" limbo | Low | Low | 🟢 |
| 6 | BondingCurve | **Furnace burn in ReadyToGraduate uses full accrual (no cap)** — unlike Trading phase where `ethBudget` is capped at `remaining = GRADUATION_ETH - _realEthReserves`, ReadyToGraduate uses the full accrued furnace fees. Can cause a significant buy from the curve just before graduation, reducing token supply for the LP | Low | Very Low | 🟢 |
| 7 | Natspec | **Documentation mismatch on fee splits** — natspec says "Creator 1.00%, protocol 0.40%, furnace 0.10% (1.50% total)" but actual constants are CREATOR_FEE_BPS=40 (0.4%), PROTOCOL_FEE_BPS=85 (0.85%), FURNACE_FEE_BPS=0, TRADE_FEE_BPS=125 (1.25%) | None | N/A | 🟢 |

## Notes from Deep Second Pass

Focused re-read with mapping integrity, centralization, and config-footgun analysis:

- **Finding #2 completely re-assessed**: Originally flagged router/migrator as changeable centralization risk. Re-read revealed `setPeepsRouter()` and `setMigrator()` are gated by `if (router != address(0)) revert AlreadyInitialized()` — **one-time-set only**. The owner can NEVER change the router or migrator after initialization. This is a strong security property. Downgraded from High/Low to Medium/Low — the risk is now about bootstrapping (the initial address must be correct), not runtime centralization.

- **Finding #1 mapping corruption refined**: The attacker's NFT doesn't just corrupt the lookup — if the attacker sends a VALID Uniswap V3 position, `collectForToken()` would collect fees from the WRONG pool and route them to protocol addresses. The real position's fees sit uncollected until someone calls `collect(realTokenId)` directly. Still griefing, not theft.

- **New finding #4 (perTokenEthCap footgun)**: The per-token cap check in `buy()` (`if (newRealEth > IPeepsCurveFactory(factory).perTokenEthCap())`) is independent of the graduation cap. If the factory owner sets `perTokenEthCap < GRADUATION_ETH` for any curve, that curve can never graduate — every buy will hit the per-token cap before reaching the graduation threshold.

- **New finding #7 (natspec mismatch)**: Doc says 1%/0.4%/0.1% split but code uses 0.4%/0.85%/0%. The furnace burn (0.1% stated) is actually 0% — `FURNACE_FEE_BPS = 0` constant. Code is authoritative, but the documentation is misleading for auditors reading the natspec.

- **Global ETH cap and furnace burn**: In Trading phase, furnace burn is capped at `remaining` (ETH left to graduation). In ReadyToGraduate, no cap applies. The furnace burn doesn't call `recordEthDelta` in ReadyToGraduate phase, so global accounting is accurate.

- **Math re-verified**: `PeepsCurveMath` uses OZ v5 `mulDiv` with 512-bit intermediate. Ceil division on retained reserves guarantees non-decreasing `k`. Verified the invariant holds for both buy and sell paths.

## Verdict

**🟢 Clean.** Peeps is well-architected with solid math, correct fee accounting, and strong invariants (ownerless tokens, fixed supply, non-decreasing CP invariant, router/migrator one-time-set). The deep second pass re-assessed the centralization finding — the router/migrator can only be set ONCE, making bootstrapping the sole trust point rather than an ongoing risk.

The two notable findings — the LP Fee Vault mapping collision (#1, griefing only) and bootstrapping trust (#2, one-time-set) — are design fragilities, not exploits. The mapping collision lets an attacker corrupt the `collectForToken()` lookup by sending arbitrary NFTs to the vault, but the direct `collect(tokenId)` path is unaffected. No fund loss path exists.
