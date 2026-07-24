# STEEL — Grid Mining Lottery on Robinhood Chain

| Field | Value |
|-------|-------|
| **Chain** | Robinhood Chain (4663) |
| **TVL** | $911 |
| **Category** | Gamified Mining |
| **Age** | ~1 day (listed July 24, 2026) |
| **Audit** | None |
| **Team** | @steeldotfun (speculative) |
| **Base** | SLVR.fun fork with veSTEEL staking, motherlode, auto-subscribe |

## Contracts Audited

| Contract | Address | Lines | Role |
|----------|---------|-------|------|
| **SteelMineV2** | `0xB089d11432F219495A4278acd6446B7Faefa2bA6` | 728 | Core mining lottery |
| **SteelMineV2** | `0x20ee34e2194e77177EF27A4bD49512fEf5d7d868` | — | Secondary instance |

---

## TMAAR (Trust Model)

### Actors

| Actor | Role |
|-------|------|
| **Owner** | Can change: protocolFee, jackpotFee, keeperFee, steelPerRound, devBps, motherlodeBps, jackpotOdds, refiningFee, bettingDuration, veSteel address, devAddr |
| **Keeper** | Public permissionless role. Fires auto-subscribe commitments. Anyone can call `autoExecute`/`autoExecuteMany` |
| **Users** | Bet ETH on squares in 60s rounds. Win pro-rata. |
| **drand Oracle** | Provides randomness for winner selection + jackpot roll |
| **veSteel** | Receives 8% of ETH pot as staker rewards |

### Trust Analysis

**STEEL** is a SLVR.fun fork with 3 new mechanics:
1. **Auto-subscribe** — users pre-fund an escrow, keeper auto-commits per round
2. **Motherlode** — ETH/STEEL accumulators pay out on 1/625 jackpot roll
3. **Refining** — ORE-style dividend index for STEEL

### Key Owner Powers
- Can change fee structure (within reason — no hard caps)
- Can change veSteel address (where 8% of pot goes)
- Can change bettingDuration (but can't close before the round ends)
- Cannot move user funds

---

## Findings

Verdict: **🟢 Clean** — no reportable vulnerabilities.

This is a SLVR.fun derivative with well-structured code. The new mechanics (auto-subscribe, motherlode, refining) follow standard patterns.

### Observations

| # | Observation | Severity |
|---|------------|----------|
| 1 | **Owner can redirect staker rewards** — `veSteel` is changeable. If set to a malicious contract that reverts, `notifyReward` fails and ETH stays in the contract | Informational |
| 2 | **Jackpot odds derived from same randomness as winner** — `keccak256(abi.encode(rand, "jackpot"))` is a clean second derivation. No bias concern | Informational |
| 3 | **Auto-subscribe keeper can fail to execute** — permissionless keeper. If no one calls `autoExecute`, auto-subscribers miss the round. Low-likelihood grief | Informational |
| 4 | **carryEth/carrySteel accumulate on no-winner rounds** — no cap on carry. In theory could build up, but they pay out to the next winner | Informational |
| 5 | **Integer division in auto-subscribe** — `amountPerSquare` × squares. Dust accumulates in `autoBalance` for the user to withdraw | Informational |

### Key Design Notes

- **drand randomness**: identical to SLVR. Uses drand round for winner, second derivation for jackpot. ✅
- **Refining**: ORE-style accumulator with `globalIndex`. Standard dividend distribution pattern. ✅
- **Auto-subscribe**: escrow balance is user-specific. Keeper cannot redirect bets. ✅
- **Motherlode**: accumulates ETH and STEEL until jackpot hit. Jackpot odds 1/625 per round (on resolve). ✅
- **CEI pattern**: `autoCancel` sets `.active = false` BEFORE sending ETH refund. ✅

---

## Files

| File | Description |
|------|-------------|
| `code/SteelMineV2.sol` | Core SteelMineV2 contract (728 lines) |
| `code/SteelMineV2_2.sol` | Secondary SteelMineV2 instance |
| `README.md` | This file |

## On-Chain Verification

Both SteelMineV2 instances verified on Blockscout ✅
