# Run Money (ClubPool)

**Chain:** Base (8453)
**Chain Explorer:** https://basescan.org/address/0x1089db83561d4c9b68350e1c292279817ac6c8da
**Date:** September 9, 2026
**Status:** 🔴 Findings (2 confirmed — both fork-proven against the real deployed contract)

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
- The value subtracted when un-marking compliance matches what was originally added — **false,
  this is F02**, and unlike F01 it requires no attacker at all

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
- The yield-redistribution mechanism (the actual product) has TWO real logic bugs in the same
  ~30 lines of `recordActivity()`: bonus-share weight is a live, freely-mutable balance sampled
  once with no lockup or time-weighting (F01, needs a deliberately-timed attacker); and the
  non-compliant branch subtracts the wrong value entirely, corrupting shared accounting from
  completely ordinary usage with no attacker required (F02, arguably more dangerous since it's
  higher-likelihood and can brick claims for every compliant athlete in an epoch at once)
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
| 4: Fork tests | Foundry fork PoC for F01 and F02 | ✅ — both confirmed against the real deployed contract on a Base fork |
| 5: Deep dive | Second pass, different angle (gap-hunter: Trust Gap seam) | ✅ — F01 IS the Trust Gap finding (access-control-correct `recordActivity`, economically exploitable weight) |

## Findings

| # | Finding | Severity | Impact | Likelihood | Status |
|---|---------|----------|--------|------------|--------|
| F01 | Unprotected stake snapshot in `recordActivity`/`claimBonus` lets any athlete inflate their bonus-pool share via a temporary stake | Medium | Medium | High | **Confirmed** — fork PoC: attacker earned ~100x victim's bonus |
| F02 | `recordActivity`'s non-compliant branch subtracts an athlete's CURRENT stake instead of their frozen snapshot, corrupting the shared pool total from ordinary usage — no attacker needed | High | High | High | **Confirmed** — fork PoC, 2 variants: bricks other athletes' `claimBonus`, or permanently locks compliance status |

Full writeups: [findings/F01-flash-stake-bonus-inflation.md](findings/F01-flash-stake-bonus-inflation.md), [findings/F02-stale-stake-underflow.md](findings/F02-stale-stake-underflow.md)

## Team Status (as of 2026-09-09)
Likely dormant, not abandoned-with-no-funds-at-risk. Evidence:
- Twitter (`@runmoney_app`) silent since June 2026; last substantive post (Jun 11) disclosed a
  "misconfigured database migration that deleted key information to verify activities using the
  Strava API" — a real backend incident, not just inactivity
- `runmoney.app`'s own live TVL widget currently shows **$0.00 / ETH Price: $0.00**, despite the
  contract genuinely holding ~$2,088 USDC + 0.35 ETH — frontend/indexer appears broken or offline
- **But** `currentEpochStartTime` shows epoch 93 started just 6 days before this review
  (2026-09-03) — `endEpoch()` is permissionless so this alone doesn't prove team activity, but
  93 consecutive weekly rollovers with no gaps is at minimum still mechanically functioning
- Real disclosure channel found: `info@runmoney.app` (mailto, from site footer). No bug-bounty
  page, no GitHub issues to check (`github.com/Run-Money` 404s)
- Reputationally real: testimonials from Stani Kulechov (Aave founder) and Lefteris Karapetsas
  (Rotki) on the homepage — not an anonymous/scam project, more likely small-team burnout or
  funding lapse after the Strava-integration incident

**Implication for F01:** real user funds are still sitting in a contract with a confirmed bug,
behind a frontend that can't even show users their own balance right now. Worth attempting
disclosure via email even without high confidence of a response — RULES.md #4 (never disclose
publicly while open) still applies regardless of whether the team responds.

## Verdict
Not clean. Two real, **fork-confirmed** logic bugs, both in `recordActivity()`'s ~30 lines of
snapshot handling. F01 needs a deliberately-timed attacker (Medium). F02 needs nobody at all —
it fires from a completely ordinary sequence (stake more, later have a bad week) and can brick
`claimBonus` for every compliant athlete in an epoch at once, or permanently lock someone's
compliance status regardless of reality (High). Staked principal itself is never at risk
(always Aave-withdrawable) — both are yield-redistribution integrity/availability bugs, not
fund-drains. The contract has been live long enough (93 weekly epochs) that it's worth checking
whether either has already fired in practice. Ready for RULES.md #5-compliant private
disclosure whenever 𝖲𝖠𝖵𝖠𝖦𝖤 wants to send it — team contact is `runmoney.app` /
`x.com/runmoney_app` / `info@runmoney.app`, no public bug-bounty page found yet. Worth
disclosing F01 and F02 together in one report since they share the same root code.
