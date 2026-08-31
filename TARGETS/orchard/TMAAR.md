# TMAAR — Orchard ($SEED) · Robinhood Chain

**Audit date:** 2026-08-30 · **Chain:** Robinhood Chain (4663) · **Age:** ~5 weeks (genesis 1784734757 ≈ Jul 22)
**TVL:** ~$31K DefiLlama · **Audits found:** none (DefiLlama, docs, Google)

## Contracts (all source-verified on Blockscout, Solidity 0.8.30)

| Contract | Address | Role |
|---|---|---|
| Orchard (game) | `0xEbB8b167c0992cFdc497A995a8Cf7167acAA0A1A` | 25-plot casino game, pot + accruals |
| SeedStaking | `0xd5d5f5Dff96E53fc6337b4aCf549d61b12882F2b` | SEED staking vault, AAPL rewards |
| Arb2935Randomness | `0x312a59ca4e000ebe88080cb34fef9984462e5bfc` | commit-reveal, ArbSys block numbers |
| SeedSwapper | `0x338e55edb9e250e4cbbe02729bdf3435e767e134` | ETH→USDG (V2) →AAPL (V4) + reverse |
| AAPL token | `0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9` | Robinhood Apple stock token (BeaconProxy) |
| SEED token | `0x5eED45d9cD4c21280db5b190D9c263f086401b9D` | game token, 1B supply, no fees |

## Actors & Trust

| Actor | Address | Powers | Trust |
|---|---|---|---|
| Owner | `0x6f53b6aa3c8baf3b01e137da788300d417996d6d` (EOA) | setSwapper/setRandomness/setStaking/setKeeper, all fee params, collectTreasury/Admin, buybackSeed, renounce disabled | **Single key. Can swap randomness/swapper to rug.** |
| Keeper | `0x27f75999506ca61c7795c07ce92d11ac340e4c3a` (EOA) | flushStaking only | Low |
| Players | anyone | plant, plantMany, claim, crank | — |
| Swapper | SeedSwapper | swaps via V2 (ETH↔USDG) + V4 (USDG↔AAPL) | Trusted, owner-replaceable |
| Randomness | Arb2935Randomness | commit/seedFor/expired | Trusted, owner-replaceable |
| ArbSys 0x64 / HISTORY 0x0000F908...2935 | chain precompiles | block numbers + block hashes | Chain-level |

## Game Mechanics (75s rounds)

- **Plant:** ETH → swap to AAPL → stake on 1 of 25 plots. 1% admin fee on buy. `plant` reverts past 60s; `plantMany` skips to next round instead.
- **Round:** 75s. Sowing window [0,60). Seal at first crank past 60s → commit = arbBlock + 30. Reveal when block hash available (~3-4s later at ~10 blk/s).
- **Reveal:** winning plot = seed % 25. Winners split `winningStake + netLossPool` (loss pool − 10% rake). Rake split: stakers 50%, jackpot 50% (of rake), treasury rest. Empty winning plot → whole round crop-vaulted to jackpot.
- **Jackpot:** roll `keccak(seed,"JACKPOT") % jackpotOdds == 0` (odds=1000). Payout = whole jackpotAccrued to that round's winners.
- **Claim:** winners get `shares + juice` where juice = accumulated 10% claim-fee pool (juiceIndex since entryIndex). 10% juice fee on gross claim.
- **Staking:** SEED staked; Orchard flushes rake share to SeedStaking.notifyReward; rewards accrue by index.

## Accepted Risks (by design)

- Owner EOA can replace swapper/randomness → full control (standard for young game)
- Keeper flush timing
- Crop-vaulting: empty winning plot takes entire round to jackpot
- 10% juice fee + 1% admin + 10% rake = heavy house edge

## Key On-Chain Facts (2026-08-30)

- Owner + keeper are EOAs (no code)
- 112 seals/reveals scanned: **seal always at open+60-62s, reveal always at open+63-69s — NEVER inside sowing window**
- Seal→reveal block delta: min 33, max 97 blocks (30-block delay honored)
- Pot: 100.67 AAPL; unclaimedShares 64.31; jackpot 11.45; admin 5.60; staking 0.46; treasury 0.002
- SeedStaking: 604,819 SEED staked, rewardIndex 10,002,687,779,707, pendingReward 0
- 246 rounds played total, 1 jackpot hit, 21 voided (non-empty), 36 claims
- Game currently dormant (only empty-round voids recent)
