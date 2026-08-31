# Orchard — Audit Findings

**Target:** Orchard ($SEED) — 25-plot casino game, Robinhood Chain
**Audit date:** 2026-08-30 · **Commit/state pinned:** live on-chain (genesis ts 1784734757)
**Verdict:** 🟡 Informational — no exploitable vault/accounting bug found. Centralization + design observations only.

---

## What was checked

- Full source read: Orchard (game + vault accounting), SeedStaking, Arb2935Randomness, SeedSwapper, AAPL/SEED tokens
- On-chain state: owner, keeper, all fee params, all accruals, pot balances (RPC eth_call)
- **Timing verification: 112 sealed/revealed rounds scanned** — seal always lands at open+60–62s, reveal always at open+63–69s. Sowing window closes at +60s. **0 reveals inside a sowing window.**
- Seal→reveal block delta: min 33 / max 97 blocks (30-block delay honored)
- Juice/unclaimedShares accounting traced with live numbers (solvency confirmed)
- Full event history: 246 PlantedMany, 246 Sealed, 246 Revealed, 36 Claimed, 21 RoundVoided, 1 JackpotHit — all topics accounted for, no unexpected events

## The timing question (chased hard, resolved CLEAN)

Hypothesis: Robinhood Chain produces ~10 blocks/sec, so the 30-block reveal delay is only ~3s. If a round could be revealed while its sowing window (60s) is still open, an attacker could plant on a **known winning plot** after seeing the reveal.

**Result: structurally impossible.** `_crank()` sets `limit = currentRound()` during the sowing window and only `limit = currentRound()+1` after it closes. The current round is never sealed/revealed while its own sowing window is open. Verified empirically: every one of 112 reveals landed at open+63–69s — after sowing closed (+60s), before round end (+75s). There is a 3–9s window where the winner is known, but the round is closed to new plants (`SowingClosed` for `plant`, `startRound+1` skip in `plantMany`). No same-round post-reveal planting exists. **Not a finding.**

## Findings

### F1 — Single-EOA owner with full rug/rig power (High centralization, by-design risk)
`0x6f53b6aa3c8baf3b01e137da788300d417996d6d` is a plain EOA (no code) with:
- `setSwapper` — can point plant/claim swaps at a malicious contract (steal plant ETH, fake AAPL)
- `setRandomness` — can replace the commit-reveal source → **rig every round outcome**
- `setStaking` — can redirect staker rewards
- `setKeeper`, all fee params, `collectTreasury`, `collectAdmin`, `buybackSeed`
- `renounceOwnership` is disabled (by design)

Impact: if the key is compromised (or the operator goes malicious), the entire pot (currently ~100 AAPL + 604K SEED staked) is at risk. No timelock, no multisig. Standard for a 5-week-old game, but the headline risk for anyone depositing. **Worth reporting to the team as a recommendation (multisig + timelock), not as a vulnerability.**

### F2 — `_creditMany` rounding dust favors the first slot (Informational)
`perSlot = totalStake / slots`, then the entire remainder (`dust = totalStake - perSlot*slots`, up to `slots-1` wei) is added to the first (round, plot) in the iteration. Sub-wei-level asymmetry; not economically exploitable. Standard dust.

### F3 — V2 leg of the swapper has zero slippage protection (Informational)
`_ethToUsdg` calls `swapExactETHForTokens{value: msg.value}(0, ...)` — minOut=0 on the ETH→USDG leg. The final `minAaplOut` check in `plant()`/`plantMany()` covers the full path, so a user who sets a sane minimum is protected end-to-end. Only a user setting minAaplOut=0 is exposed to sandwiching on the V2 leg. Defensive improvement, not a bug.

### F4 — Juice mechanics: early claimers subsidize late claimers (Design note)
Every claim pays 10% juice fee; the fee inflates `juiceIndex`, which pays out to *future* claimers of *older* rounds. Claiming late on an old round yields more juice; the last claimant's fee goes to `jackpotAccrued` when `unclaimedShares == 0`. Verified solvent with live numbers (contract balance 100.67 AAPL ≥ unclaimedShares 64.31 + accruals 17.51 + juice owed ~18.85). This is a deliberate late-claimer incentive, not an exploit.

### F5 — Liveness dependency on at least one cranker (Informational)
`REVEAL_EXPIRY_BLOCKS = 100,000` ≈ 2.8 hours at 10 blk/s. If NOBODY calls `crank()`/`plant()` within that window after a seal, the round voids and all stakes are refunded (safety valve). Anyone can call `crank()` publicly, so a single active participant prevents voiding. Current game is dormant — 427 empty rounds voided recently by a bot. Not exploitable; worth noting the game relies on continuous interaction.

### F6 — Crop vaulting: empty winning plot confiscates the round (Design note)
If the winning plot has zero stake, the ENTIRE round's `totalStake` goes to `jackpotAccrued` (`CropVaulted`). Any player who didn't cover the winning plot loses their full stake to the jackpot pool. By design (the "empty plot" lottery), but a sharp house edge for players who spread thin.

## Accounting verification (live numbers)

- Pot AAPL 100.6682 = unclaimedShares 64.3133 + jackpot 11.4482 + admin 5.5993 + staking 0.4637 + treasury 0.00195 + juice owed ~18.85 ✓ solvent
- SeedStaking: 604,819 SEED staked, rewardIndex 10,002,687,779,707, pendingReward 0 ✓
- Staking rewards: 4.2661 AAPL held by SeedStaking ✓
- No fee-on-transfer on SEED/AAPL (standard ERC-20 / Robinhood BeaconProxy) ✓
- `flushStaking` balance-delta check is exact ✓

## Bottom line

The game logic, randomness, and vault accounting are **sound**. The only real risk is the single-EOA owner (F1) — standard for a young game but the thing anyone should know before depositing. No reportable on-chain exploit found. **Not proceeding to disclosure.** Target marked 🟡 Informational, consistent with the audit log.
