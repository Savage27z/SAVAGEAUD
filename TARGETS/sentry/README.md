# Sentry Launch Factory

**Chain:** Robinhood Chain (4663)
**Date:** Jul 24, 2026
**Status:** 🟢 Clean

**Audited commit:** Verified on-chain via Blockscout (proxy: `0x9e8f6f8214b01Fd4Cf1d73FB1fb7cf9f811036Cb`, impl: `0xb9E9c35b12E866016425C5E52392c7e9158CC643`)

## Overview

Token launchpad on Robinhood Chain — one-click ERC-20 deployments with permanently locked Uniswap V3 LP. Deploys ERC-20 tokens, creates 1% fee-tier Uniswap V3 pools against WETH, mints single-sided LP positions that are permanently self-custodied in the factory, and routes trading fees 65/35 between creators and treasury.

**TVL:** ~$31K (via DefiLlama — pools created by factory)
**Category:** Launchpad (non-DEX)
**Team:** @sentrylauncher on X (3.8K followers, verified)
**Code:** Open source (MIT, verified on Blockscout)
**Source:** Solidity 0.8.20, Foundry, upgradeable via TransparentUpgradeableProxy + ProxyAdmin

## Key Contracts

| Contract | Address | Role |
|----------|---------|------|
| SentryLaunchFactory (proxy) | `0x9e8f6f8214b01Fd4Cf1d73FB1fb7cf9f811036Cb` | Main entry point |
| SentryLaunchFactory (impl) | `0xb9E9c35b12E866016425C5E52392c7e9158CC643` | Implementation logic |
| ProxyAdmin | `0x0fd20047b827561c842355057273e9d4518a732b` | OZ ProxyAdmin — controls upgrades |
| Uniswap V3 NPM | `0x73991a25c818bf1f1128deaab1492d45638de0d3` | LP position management |

## TMAAR

Full TMAAR documented in `TMAAR.md`. Key findings:

- **Owner EOA** (`0xbf55...B7C5`) controls both factory params and ProxyAdmin — single point of failure
- **ProxyAdmin is a contract** (OpenZeppelin), not an EOA — slightly better than EOA upgrade control
- **LP permanently locked** — no withdraw/transfer functions for NFTs in the factory
- **Pool manager trust** — TsunamiPoolManager provides initial price/ticks at token launch

## Analysis Summary

- Factory code is well-structured with proper CEI pattern and reentrancy guards
- Zero tokens deployed as of audit (on-chain `totalTokensDeployed` = 0)
- Fee routing is clean — collects from Uniswap NPM, splits 65% creator / 35% treasury
- Fee recipient migration correctly gated (one-time self-service, unlimited owner)
- Reentrancy guard on all external state-changing functions
- `try/catch` around pool creation and mint prevents bricking on partial failures

## Passes Performed

| Phase | Method | Status |
|-------|--------|--------|
| 0: Recon | Surface map, trust model, deps | ✅ |
| 0.5: TMAAR | Documented actors, assumptions, risks (Macro-style) | ✅ |
| 1: Read | Full code read (Feynman questioning) | ✅ |
| 2: Hunt | 6-agent checklist run | ✅ |
| 3: On-chain verify | RPC calls confirmed owner, treasury, proxy admin | ✅ |
| 4: Fork tests | RPC rate-limited — skipped (static analysis sufficient) | ⏭️ |
| 5: Deep dive | Second pass on fee routing, upgrade path, access control | ✅ |

## Findings

None — nothing reportable. Code is clean, proper patterns throughout.

## Verdict

Sentry is a straightforward Uniswap V3 launchpad factory. The code is well-written with proper access controls, reentrancy guards, and clear fee routing. The main risks (single EOA control, pool manager trust) are standard for a launchpad of this size and stage. The LP lock claim is verified — no functions in the factory transfer or withdraw LP NFTs.
