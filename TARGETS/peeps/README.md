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
| 1 | LP Fee Vault | **`onERC721Received` auto-registers arbitrary NFTs** — anyone can `safeTransferFrom` a random ERC721 to the vault with crafted `data` bytes, overwriting `tokenPosition[launchToken]` mapping. Corrupts `collectForToken()` lookups, causing fee collection to target the wrong NFT. Real positions tracked by `collect(tokenId)` are unaffected, but the launchToken → tokenId resolution is permanently corrupted for that token | Medium | Low | 🟡 |
| 2 | Factory | **Migrator/router not set at construction** — `migrator` and `router` start as `address(0)`. Tokens created before these are set can't graduate or trade through the router. Front-end likely sets them immediately after deploy, but there's a window | Low | Low | 🟢 |
| 3 | Factory | **Global ETH cap can be bypassed via multiple curves** — `recordEthDelta` tracks total ETH across all curves against `globalEthCap`. But the cap is only checked on `buy()`, not on furnace burn or graduation re-entry. If furnace burn pushes ETH into a curve post-cap, accounting is maintained but cap semantics are fuzzy | Low | Low | 🟢 |
| 4 | BondingCurve | **Unburned furnace fees after graduation are locked** — `executeFurnaceBurn()` requires phase Trading or ReadyToGraduate. After graduation, `graduate()` calls `_burnFurnaceAccrual(0)` which burns whatever it can at that moment. Any furnace fees accrued AFTER graduation (from post-graduation trades on the curve... but curve is graduated so no more trades happen) can never be burned. Actually this is moot — no trades happen after graduation | Low | Very Low | 🟢 |
| 5 | BondingCurve | **Sell reverses graduation** — `sell()` allows trading in `ReadyToGraduate` phase. If someone sells enough to drop below the ETH cap, `_syncPhaseAfterSell()` reverts the phase back to `Trading`. A user could intentionally sell to de-escalate graduation, preventing `graduate()` from being called | Low | Low | 🟢 |
| 6 | Factory | **Owner can change router/migrator after deployment** — All curves depend on the router for trading and the migrator for graduation. If owner swaps router to a malicious contract, all funds on all curves are at risk | **High** | Low | 🟡 |

## Notes from Deep Second Pass

Focused re-read with mapping integrity and economic analysis:

- **Finding #1 (mapping corruption):** The LP Fee Vault's `onERC721Received` auto-registers positions from arbitrary callers. An attacker sends a random ERC721 with `data = abi.encode(legitimate_token_address)`, overwriting `tokenPosition[launchToken]`. After this, `collectForToken(launchToken)` looks up the wrong NFT. The real LP position (sent by the migrator) is still accessible via `collect(tokenId)` — only the address-based lookup is broken. The attacker can't steal fees, just redirect lookups to their own NFT (which has no fees to collect, causing reverts). A griefing attack, not a theft vector.

- **Finding #6 (router trust):** The entire Peeps system funnels through a single `router` address. Only the router can call `buy()`/`sell()`. If the owner sets a malicious router, every curve can be drained. This is the single most powerful trust point in the system. The router implementation wasn't in scope for this audit — it's a separate contract.

- **Curve math verified:** `PeepsCurveMath.buyTokensOut()` and `sellEthOut()` correctly implement the constant-product formula with ceiling division on retained reserves. The non-decreasing `k` invariant holds. No integer overflow possible with OZ v5 `mulDiv` (512-bit intermediate).

## Verdict

**🟢 Clean.** Peeps is well-architected with solid math, correct fee accounting, and strong invariants (ownerless tokens, fixed supply, non-decreasing CP invariant). The two notable findings — the LP Fee Vault mapping collision (#1) and router centralization (#6) — are design fragilities, not exploits.

The mapping collision in `onERC721Received` is the most actionable finding: it lets an attacker permanently corrupt the launchToken → tokenId resolution for any graduated token. The real LP fees are still collectable via the `collect(tokenId)` function, so no ETH is lost, but the address-based convenience path is broken. A fix would gate `onERC721Received` to only accept positions from the migrator or position manager.
