# SLVR — Grid Lottery

**Chain:** Robinhood Chain (4663)
**Date:** July 22, 2026
**Status:** 🟢 Clean — Nothing reportable

## Overview
Grid mining/gambling protocol on Robinhood Chain. Players deploy ETH on a 5×5 grid (25 squares) in 90-second rounds (60s betting, 30s reveal). Winners split the pot pro-rata on the winning square. Randomness via drand beacon with reveal safety buffer.

## Key Contracts
| Contract | Address | Role |
|----------|---------|------|
| SlvrGridLottery | `0x284Eb4016305Fa7FbC162Fb68F27227271001c7f` | Main game contract |
| SlvrHub | `0x55FC0daaB486E46fBF1d60787420c0311d9Dd57f` | Emission governor |
| SlvrJackpot | `0x24B723e2Da172961F60Cd6a4699654c89D4aC6cd` | Jackpot pool |
| SlvrAutoCommitV2 | `0x527DD0e2B5D0Af71245A7C4C347480b805440443` | Auto-grid commit |
| SlvrToken | `0x791229E3EbD6CFdC3D8157f48722684173C29aD9` | $SLVR token |

## Analysis Summary
- **Randomness:** drand-based with safety buffer (6s default). Unknowable during betting.
- **Winner selection:** Fenwick tree weighted random for single-miner rounds, pro-rata otherwise.
- **Jackpot:** 1/625 odds, separate upgradeable contract.
- **Fee model:** 10% protocol fee split jackpot/stakers. 8% team + 4% growth on SLVR emission.
- **Resilience:** Carry pools for failed distributions, try/catch patterns, permissionless re-request.

## Key Defenses
- Reveal safety buffer prevents beacon prediction during betting
- `requestResolve` locks betting for the round
- Fenwick tree cross-checked against simple total on resolve
- 5-min timeout for re-requesting missed randomness

## Open Questions
- None — code is production-quality

## Verdict
Well-architected by an experienced team. Every edge case has a defense.
