# F03 — riskCap resolved, suspension is self-service, and a corrected detector (nar.bet)

**Verdict: two more hypotheses NEGATIVE (#3 suspension/funds-lock, and the riskCap scare).**
All evidence from a fork of Monad mainnet (chainId 143), scripts under `recon/fork_v5_*`, `fork_v6_*`.

## 1. `riskCap` is per-game risk budget in PARTS PER MILLION, not percent — lead closed

The recon note read `riskCap()` on one proxy and recorded "275 → 2.75%", then live values showed
RPS/Plinko at **10000** vs Mines **270** — a 37× spread that looked like either drift or a
misconfiguration. It is neither.

Measured on the fork: placing an oversized bet reverts with the amount and the limit:

```
WagerAboveLimit[given, 2631578947368421052631]
```

The limit is **2,631.578947368421 MON**, and the house liquidity is **500,000 MON** (5.0e23). With
RPS's max payout multiplier ≈ 1.9:

```
maxWager = houseLiquidity / 1.9 / 100  =  500,000 / 190  =  2,631.58   EXACT
```

So the formula is `maxWager = houseLiquidity × riskCap / 1e6 ÷ maxPayoutMultiplier` — i.e.
**`riskCap` is denominated in parts per million**, and RPS's 10000 means **1% of house liquidity at
maximum payout**, not 100%. Mines' 270 ppm = 0.027%, which is the *correct* direction for a game with
large multipliers. The per-game spread is a coherent, conservative risk budget, not a hole.

The bet at scale settled correctly: 1,000 MON wagered → 1,899.98 paid (1.9×), BankRoll −901.00
(=−1,899.98 + 1,000 + edge) — consistent with `edgeFactor` 9500 and the 1.9× win multiplier.

**Correction to the earlier note:** the README's "riskCap = 275 → 2.75%" was a units error (it is
0.0275%), and F01's "per-game 37× spread worth understanding" is now explained and closed.

## 2. Suspension is SELF-service — no operator ban, no funds lock (#3 closed NEGATIVE)

`suspend(uint256)` and `permantlyBan()` take **no address argument**, and the flag lands on
`msg.sender`:

| action | result |
|---|---|
| owner calls `suspend(86400)` | **owner** becomes suspended; a *player* is unaffected (`isPlayerSuspended(player)` stays `(false, 0)`) |
| player calls `suspend(3600)` | that player is suspended; `Play` reverts `PlayerSuspended(uint256)` |
| player calls `permantlyBan()` | flag becomes `(true, uint256.max)` — permanent |
| suspended player calls `liftSuspension()` | **reverts** — the player cannot undo their own exclusion |

`isPlayerSuspended(address)` was also mis-read at first: it returns **two words**,
`(bool suspended, uint256 suspendedUntil)`, not a single value. (Same flattening trap as
`GetState`.) The decoded `suspendedUntil` values — 1789316168, then `uint256.max` after
`permantlyBan()` — are exactly self-exclusion expiries.

**The funds-lock test.** A player self-suspended with a bet already in flight:

- the winning outcome still settled and **paid out normally** (+19.00 MON on a 10 MON bet, BankRoll −9.01);
- the refund path still worked while suspended (commit + claim, +7.9998 MON = 80% of a 10 MON wager).

So the operator has **no per-player ban power at all**, and self-suspension does not strand money.
This is a self-exclusion/responsible-gambling feature, and it behaves correctly. The highest-severity
family in our corpus (`funds_locked_dos`) does not apply here via this mechanism.

## 3. Detector correction: the 14 "unidentified" BankRoll selectors ARE live functions

F01 (addendum) concluded from one game-impl false positive that an unmatched dispatcher selector is
probably a data constant. That generalisation is **wrong for BankRoll**: probing all 14 unidentified
selectors × 6 argument shapes, **55 of 84 calls answered** — including real behaviour:

- `0x4a9aa3c5` and `0x7320ca26` **revert `Ownable: caller is not the owner`** → genuine owner-only
  functions, each taking a single static argument, present in no recovered ABI.
- `0x385dc3df` returns a constant `0x93a80` = **604800** (7 days in seconds) → a no-arg getter.
- `0x5094eada(address)` returns a word; `0x6fea06b6` answers for two args → further getters.

**Rule, restated correctly:** an unmatched selector is a *candidate*, per-selector. Confirm it with
an `eth_call` — but note that "empty revert" is ambiguous: it is returned both for a selector that
does not exist **and** for one that exists but was given the wrong argument count (ABI decode
failure). Only a decoded return value or a decoded custom error/require-string proves existence.
`0x4a9aa3c5` returned an empty revert with 0 args and a named `Ownable` revert with 1 – that pair is
the signature of "exists, takes one argument".

What these two owner-only functions *do* is **not yet established** — they had no observable effect on
suspension state or on whether a player could play. Recorded as unidentified owner entry points,
**not** as findings.

## 4. False positive caught in this chunk (the trap that keeps recurring)

Mid-test I had "the owner silently blocked player A2 from playing via `0x7320ca26` while
`isPlayerSuspended` still said `(false,0)`" — a great-sounding silent-blacklist finding.
It was wrong. A2's `Play` reverted `AwaitingVRF(uint256)`: my **own** earlier probe had left A2 with an
unsettled bet, and a second bet while one is pending always reverts.

Caught only because the revert *reason* was decoded instead of just the tx status (`0x0`).
**Rule: never read `status 0x0` as the behavior — decode the reason.** Every "guard" I have probed on
this target so far has turned out to be either a different guard or my own leftover state.

## 5. Status

Closed NEGATIVE now: **#1** refund race, **#2** refund × settlement ordering, **#3**
suspension/funds-lock, plus the `riskCap` lead. Still open on nar.bet: **#4** multi-step game guards
(Mines `Reveal(bool[25])`, VideoPoker), **#5** BankRoll share accounting / LP deposit-withdraw,
**#6** client-supplied state (`Mines_Reveal`, `HiLo currentCard`), **#7** client-vs-on-chain edge
drift, the unidentified owner-only BankRoll functions, and the unexplained 20% refund penalty.
