# Run Money (ClubPool)

**Chain:** Base (8453)
**Chain Explorer:** https://basescan.org/address/0x1089db83561d4c9b68350e1c292279817ac6c8da
**Date:** September 9, 2026
**Status:** 🔴 Findings (1 confirmed — fork-proven against the real deployed contract)

**Audited commit:** verified source as deployed, compiler `v0.8.26+commit.8a97fa7a`, pulled via
Etherscan V2 unified API (`chainid=8453`) directly from the chain explorer — no separate GitHub
repo available (`github.com/Run-Money` 404s)
**Final commit:** — (no fix round yet)
**Repo:** verified source only (Basescan) — `src/ClubPool.sol` + OZ/Aave interface deps

## Overview
"No-loss savings game" combining DeFi with fitness accountability. Athletes mint a
non-transferrable membership NFT (pay an ETH fee, wrapped to WETH and supplied to Aave V3),
then stake USDC (also supplied to Aave V3). An off-chain "reporter" role attests weekly running
compliance (via Strava, per the project's own description) on-chain. Each 7-day epoch, the
Aave-accrued yield on both USDC and WETH is split among that epoch's compliant athletes,
proportional to their staked amount. Live for ~93 weekly epochs as of this review — an
established, continuously-operating small protocol, not a brand-new one.

## Key Contracts

| Contract | Address | Role |
|----------|---------|------|
| ClubPool | `0x1089Db83561d4c9B68350E1c292279817AC6c8DA` | Entire protocol — single contract, no proxy, no factory |

External dependencies (not in scope, trusted): Aave V3 Pool + aUSDC/aWETH on Base, WETH9.

## TMAAR
See [TMAAR.md](TMAAR.md).

### Actors & Trust Levels (summary)
| Actor | Trust Level | Notes |
|-------|-------------|-------|
| Owner | High | Fee/reporter control, forced-unstake-to-athlete, membership burn, fee withdrawal |
| Reporter | High | Sole on-chain source of compliance truth — off-chain oracle by design |
| Athletes | None (but see F01) | Can attack the bonus split against other athletes |

### Key Assumptions
- Reporter is honest about real-world activity (accepted, off-chain, no dispute path)
- An athlete's stake at compliance-marking time fairly represents their epoch participation —
  **false, this is F01**

### Accepted Risks
- Single trusted reporter role, no on-chain verification possible (inherent to the product)
- Single-EOA owner, broad admin power (standard early-stage risk)

## Exclusions
- Aave V3 Pool / aToken contracts — external dependency, not reviewed
- WETH9 — standard, not reviewed
- Off-chain reporter backend / Strava integration — not on-chain, out of scope
- Frontend (runmoney.app) — not reviewed

## Analysis Summary
- Single, small (345-line), readable contract — full read completed in one pass
- Staked principal is never at risk — always Aave-custodied and withdrawable via `unstake()`
- The yield-redistribution mechanism (the actual product) has a real logic bug: bonus-share
  weight is a live, freely-mutable balance sampled once with no lockup or time-weighting (F01)
- Two admin-trust observations (O1, O2) noted but not elevated to findings per RULES.md #6
- Verified live on-chain: 93 epochs elapsed, 7-day epoch length, ~$2,088 USDC + 0.35 ETH
  currently staked — real, ongoing money, so F01 has been theoretically exploitable across many
  past epochs, not just hypothetically going forward

## Passes Performed

| Phase | Method | Status |
|-------|--------|--------|
| 0: Recon | Surface map, trust model, deps, live on-chain state pulled via direct `eth_call` | ✅ |
| 0.5: TMAAR | Documented actors, assumptions, risks | ✅ |
| 1: Read | Full code read (Feynman questioning) — entire contract, single pass | ✅ |
| 2: Hunt | Access control / reentrancy / math / oracle-trust checklist run | ✅ |
| 3: Tools | Slither | ⏭️ skipped this session — small enough for a confident manual read, flag for follow-up |
| 4: Fork tests | Foundry fork PoC for F01 | ✅ — confirmed against the real deployed contract on a Base fork |
| 5: Deep dive | Second pass, different angle (gap-hunter: Trust Gap seam) | ✅ — F01 IS the Trust Gap finding (access-control-correct `recordActivity`, economically exploitable weight) |

## Findings

| # | Finding | Severity | Impact | Likelihood | Status |
|---|---------|----------|--------|------------|--------|
| F01 | Unprotected stake snapshot in `recordActivity`/`claimBonus` lets any athlete inflate their bonus-pool share via a temporary stake | Medium | Medium | High | **Confirmed** — fork PoC: attacker earned ~100x victim's bonus |

Full writeup: [findings/F01-flash-stake-bonus-inflation.md](findings/F01-flash-stake-bonus-inflation.md)

## Verdict
Not clean. F01 is a real, **fork-confirmed** logic bug in the core value-distribution mechanism
— no front-running or flash-loan sophistication required, exploitable by any athlete against
every other athlete's bonus share, and the contract has been live long enough (93 weekly
epochs) that it's worth checking whether it's already been exploited, not just fixing going
forward. Staked principal itself is never at risk (always Aave-withdrawable) — this is a
yield-redistribution integrity bug, not a fund-drain. Ready for RULES.md #5-compliant private
disclosure whenever 𝖲𝖠𝖵𝖠𝖦𝖤 wants to send it — team contact is `runmoney.app` /
`x.com/runmoney_app`, no public bug-bounty page found yet.
