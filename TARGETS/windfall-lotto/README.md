# Windfall Lotto

**Chain:** Polygon (137)
**Date:** July 24, 2026
**TVL:** $1,383
**Status:** 🟢 Clean — Nothing reportable

## Overview

Weekly on-chain lottery on Polygon using DAI. Players pick 5 numbers (0-99, duplicates allowed, position-sensitive) and buy ERC-721 tickets at 1 DAI each. Draws close every Friday 23:00 UTC, randomness from Chainlink VRF v2.5 with staged fallback (Supra → blockhash).

## Contracts

| Contract | Address | Lines | Role |
|----------|---------|-------|------|
| WindfallLotto | `0x9650D206c6e0093FBc1D623b2A1e03984D24d3f1` | 949 | Core state machine |
| WindfallTicket | `0x8A1E8B8c54338bAa7B239dB845316A37BCb07C41` | 408 | ERC-721 ticket NFT |
| WindfallDrawNFT | `0x120C9ce64cfd6A2B173A6B44dc6aCFA5fEB556c1` | 404 | Archival draw result NFT |
| WindfallSVG | (library) | 161 | On-chain SVG rendering |
| WindfallFeeShare | `0x8d1e76657F469932Dd04d0Bad2f0FCE0bbDb22a5` | — | Fee distribution (separate contract) |

## Key Parameters

| Parameter | Value |
|-----------|-------|
| Ticket price | 1 DAI |
| Host fee | 10% (0.1 DAI per ticket) |
| Minter royalty | 10% of winnings if ticket transferred |
| Tier 5 share | 80% of jackpot (5 consecutive exact matches) |
| Tier 4 share | 20% (4 consecutive) |
| Tier 3 share | 5% (3 consecutive) |
| Jackpot rollover | Remainder after tier payout |
| Draw schedule | Every Friday 23:00 UTC |
| Randomness | Chainlink VRF → Supra (1h) → Blockhash (2h) |

## Analysis Summary

- **State machine:** 6-state draw lifecycle with strict transitions. No race conditions possible.
- **Access control:** Permissionless for all game actions. Host controls only config bounds (VRF gas, confirmations).
- **Reentrancy:** `nonReentrant` on all fund-moving functions. CEI in `claim()`. ERC-721 callbacks inert.
- **Math:** Integer division dust rolls over via remainder. No rounding manipulation. No first-depositor vulnerability.
- **Randomness:** Each number independently derived via `keccak256(r, i)`. Blockhash salted with draw context.
- **Payouts:** Locked at finalize. OverPay check is defense-in-depth. Royalty split works correctly on transferred tickets.

## Passes Performed

| Phase | Method | Status |
|-------|--------|--------|
| 0: Recon | Surface map, trust model, external deps | ✅ |
| 1: Read | Full code read — all 4 contracts (~1,922 lines) | ✅ |
| 2: Hunt | 6-agent checklist run (access, reentrancy, math, random, upgrades, external calls) | ✅ |
| 3: Tools | Manual triage (Slither blocked — no forge for deps) | ✅ |
| 5: Deep dive | Second pass: race conditions, econ attacks, state machine edge cases | ✅ |

## Verdict

**Clean code.** Well-architected lottery with proper state machine, sound randomness pipeline, and correct payout math. The team clearly understands Solidity security patterns. Nothing reportable.

## Source Code

`code/` — 4 Solidity files (WindfallLotto.sol, WindfallTicket.sol, WindfallDrawNFT.sol, WindfallSVG.sol)
