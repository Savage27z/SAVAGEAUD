# F02 — Refund path: fork attack. Hypotheses #1 + #2 CLOSED NEGATIVE (nar.bet, Monad)

**Verdict: the refund mechanism is correctly guarded. No free-option attack, no double-spend.**
All evidence below is from an `anvil` fork of Monad mainnet (chainId 143), impersonating the Entropy
proxy to control outcomes, with real state changes. Nothing was written to mainnet.

Harness: `recon/fork_refund_twostep_v4.py` (re-runnable; accepts a wager in wei as argv[1]).

## 1. What the refund path actually is (decoded from behaviour, constants now explained)

`X_Refund()` is a **two-step** mechanism, and the two constants that looked like one thing are two
separate gates:

**Step 1 — commitment** (`REFUND_TIMEOUT_BLOCKS = 2000`)
- Before the request is 2000 blocks old: `RefundTooEarly(have, want)` with
  **`want = requestBlock + 2001`** — measured flat from +0 to +40 blocks, so this gate fires first
  and hides everything behind it.
- After it: the call **succeeds but pays nothing**. It emits
  `RefundCommitmentCreated` (`0x1b792f56…`), leaves `GetState` untouched, moves no MON.

**Step 2 — claim** (`REFUND_COMMIT_WAIT_BLOCKS = 20`)
- Immediately after committing: `RefundClaimPending(have, want)` with **`want = commitBlock + 21`**.
- After that: the call pays, emits `RockPaperScissors_Refund_Event` (`0x1b240de4…`), and
  **clears the request to `[0,0,0,0,0,0]`**.

**The refund pays 80% of the wager** — proportional, measured at three sizes (the ~0.0001 MON gap is
the refund tx's own gas):

| wager | refunded |
|---|---|
| 0.5 MON | +0.3999 |
| 1.0 MON | +0.7999 |
| 2.0 MON | +1.5999 |

So an abandoned bet costs the player 20%. (`wagerNumber() = 20` does not explain 20% — the naming is
suggestive and wrong; the number is measured, the mechanism behind it is not yet identified.)

**`GetState(player)` layout** (reverse-engineered from behaviour, not from source):
`[wager, sequenceNumber, ?, requestBlock, awaitingFlag, ?]` — word 1 is the Entropy sequence.

## 2. Attack shapes tested — all four NEGATIVE

| # | attack shape | result |
|---|---|---|
| 1 | **Refund after the reveal** (the naive race) | **Dead.** Refund is gated on the request being 2001 blocks old; the reveal lands in 2–9 blocks. `RefundTooEarly` for the entire life of a normal bet. |
| 2 | **Pre-mature a commitment while idle, then bet** | **Dead.** The first gate requires an existing pending request 2000 blocks old — you cannot create a commitment without first stranding a real bet for ~16.7 min. |
| 3 | **Stale commitment reused on a later bet** | **Dead.** The clock is bound to the request: after the first bet settled, a second bet showed `want = betB + 2001`. It resets; it does not carry over. |
| 4 | **Refund, then let the callback pay anyway (double-spend)** | **Dead.** After a successful claim the request is cleared; the late callback transaction **succeeds (status 0x1) but pays exactly nothing** and emits no logs. Balance delta `+0.0000`, `GetState` stays zeroed. |

Attack 4 is the one worth being explicit about: a player who abandons a losing bet for 16.7 min gets
80% back and **cannot** then be paid the win — the callback is a silent no-op against the cleared
state. Funds conservation holds.

## 3. Why the earlier static read got this wrong (recorded honestly)

Before the fork, the plan was: "commit a refund while idle, then bet, then refund the losses." That
was wrong on three counts, each only visible by executing:
- The commitment cannot be created without a stranded request (gate order).
- The clock resets per request (so nothing is reusable).
- Refund is two calls, and the first one pays nothing — reading a single success as "the refund
  worked" would have produced a false positive in the opposite direction.

The fork phase is what converted this from three plausible stories into one measured mechanism.

## 4. Harness bugs caught (both silent-wrong, both cost a full run)

- **Revert decoder returned "OK" for every revert.** `rpc()` unwrapped the JSON-RPC envelope, but
  `decode_err()` still looked for a nested `res["error"]` key — so a *bare* error object has no
  `"error"` inside it and every revert was reported as success. This produced a complete, plausible,
  entirely false timeline ("refund succeeds at +0"). Caught only by looking at the raw eth_call
  output. **Rule: when a decoder reports success for everything, print one raw response and check.**
- **`anvil_mine(count)` silently under-mines.** Asked for 2002 blocks, got 1058, so the refund was
  still `RefundTooEarly` and the test never reached the code under test. Mine in chunks of 100 and
  verify `eth_blockNumber` reached the target.
- **Balance-delta classification must account for fees.** A winning bet nets *negative* (the 1.4 MON
  entropy fee is paid on every bet), so `delta > 0` classifies every bet as a loss. Recover the
  payout as `delta + wager + fee` and compare against the wager.

## 5. Residual notes (not findings, worth a later look)

- The post-refund callback **succeeds silently** (status 0x1, no logs, no payout) instead of
  reverting. Benign here, but "accepted and ignored" is a weaker invariant than "rejected" — it is
  precisely what makes shape #4 safe, so it deserves a deliberate second read rather than an
  assumed pass.
- `RockPaperScissors_GetState` returns 6 words for a settled player (`[0,0,0,0,0,0]`) — clean.
- A second `Play` while a request is pending **reverts** (one pending request per player per game).

## 6. Status

Hypotheses **#1 (refund-after-reveal)** and **#2 (refund × settlement ordering)** from the target
README are **closed NEGATIVE with fork evidence**. Remaining on nar.bet: #3 ban/suspend × in-flight
funds, #4 multi-step game guards (Mines/VideoPoker), #5 BankRoll share accounting,
#6 client-supplied state (`Mines_Reveal(bool[25])`, `HiLo currentCard`), #7 client/on-chain house-edge
drift, plus the unexplained 20% refund penalty and the per-game `riskCap` spread (270 vs 10000).
