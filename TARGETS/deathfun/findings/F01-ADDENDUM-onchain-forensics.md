# F01 — ADDENDUM: on-chain forensics settle the open questions

**Date:** 2026-09-10
**Method:** full-history `eth_getLogs` scan of the live contract + calldata decode of every
`increaseBet` transaction ever mined. No fork, no synthetic data — real production transactions.

This addendum answers the two questions left open in the original F01 writeup:

1. **Is `increaseBet` actually called in production, or is it dead code?**
2. **Who submits the transaction — the server, or the player?**

Both are now settled with on-chain evidence. One of them changes the likelihood rating.

---

## 1. `increaseBet` was heavily used — then died

Full-history scan of `BetIncrease` logs on the proxy (`0x27EDd1…B20C`), deployment
(block 9,967,717) through head (83,155,950):

| Metric | Value |
|---|---|
| Total `BetIncrease` events ever | **7,329** |
| First call | block 45,017,869 — **2026-03-11 05:53:40 UTC** |
| Last call | block 53,195,558 — **2026-04-12 13:20:51 UTC** |
| Calls since 2026-04-12 (5 months) | **0** |
| Distinct player wallets | **554** |
| Signature deadline window | **exactly 15 minutes** after each call |
| Amounts seen | 0.0005–0.01 ETH (median 0.001) |

So the feature ran hard for one month, across 554 real users, then was switched off entirely.
It has not been called once in the five months since.

- Today there is **no player-facing button** for it in the app (confirms the earlier live-UI
  check), and **no API route** for it either — `/api/games/<id>/increase-bet` returns the
  Next.js 404 page, while the genuine sibling route `/api/games/<id>/select-tile` returns
  `{"error":"missing jwt"}` 401. (Method validated against a known-real route, not assumed.)
- The function is still deployed and still callable on the live proxy. The frontend still ships
  the ABI entry and the session-key policy that grants it `valueLimit: Unlimited`.

**Net:** dormant, not removed. Re-enabling the feature re-opens the exploit path immediately.

## 2. The player — not the server — submits the transaction

This was the open question that decided whether the bug was reachable at all. Decoding all
7,329 transactions settles it:

| Check | Result |
|---|---|
| Txs where `tx.from` == `game.player` (event topic 2) | **7,329 / 7,329** |
| Txs where they differ | **0** |
| Distinct sending addresses | 554 (= distinct players) |
| Txs with `msg.value == 0` | **0** |
| Txs where `msg.value` ≠ signed `amount` | **0** |
| Signatures reused more than once | **0** (7,329 distinct) |

**The player's own wallet called `increaseBet` every single time.** The server never submits this
call — it only supplies the signature. That is only possible if the signature is handed to the
player's client, because otherwise the player's wallet would have nothing to build the
transaction from.

Which means, for the month the feature was live, **every one of those 554 players held
everything needed to exploit it**:

- they controlled `msg.value` (the contract never checks it — so `0` instead of `amount`), and
- they controlled the calldata (so the same signature could be resubmitted until the deadline).

**Recovered signer.** ECDSA-recovering the signature on all 60 sampled transactions yields one
address, 60/60:

```
0x937CddeCf00cD7f1f667f385deDFaE275A0f2Ea7
```

Live `isAdmin(0x937CddeC…)` on the proxy returns **true**. That same address is also:

- the contract **owner** (`owner()` on the proxy), and
- the **owner of the proxy admin**, i.e. it holds upgrade rights over the bankroll.

One EOA key controls upgrades, bankroll withdrawal, and every settlement signature.

## 3. What this does to the rating

**Likelihood — revised and split:**

- *Reachability* is no longer theoretical. It is **proven by 7,329 production transactions**:
  the caller is the player, the caller chose the value, and the caller could have sent zero.
  Any of 554 real users could have executed this with a modified client. This is as reachable
  as a bug gets.
- *Exploitation today* is **low**: the feature is off, no UI, no API route, and no signature can
  be obtained. All historical signatures are long past their 15-minute deadline.

The original writeup rated Likelihood **High** on the inference that "an unlimited-value
session-key grant isn't registered for dead code — the backend must be calling it." That
inference turned out to be **half right and half wrong**, and the correction matters:

- ✅ Right that the feature was real infrastructure, not dead code — it processed 7,329 calls.
- ❌ Wrong about the mechanism: the *backend* was not calling it. The **player** was. That makes
  the bug *worse* for reachability (any user can trigger it) and simultaneously explains why it
  was never exploited (nobody realised, and it is now switched off).

**Revised severity: High impact / reachability proven, currently dormant.**
Still High overall — the missing checks are real, the deployed code still has them, the money is
still in the contract, and the only thing standing between an attacker and a drain is a
server-side feature flag.

**Note on the 15-minute deadline:** short, but not a mitigation. A replayed signature needs only
seconds, and the credit is permanent on-chain once written.

**Note for the disclosure:** the absence of any reused signature across 7,329 calls is good news
for the team — it is evidence this was never exploited, which they will want to know. It also
means the clean fix (bind `msg.value` into the hash and add a nonce) has no cleanup to do.

## 4. Still unverified

Whether the off-chain backend trusts on-chain `betAmount` / `BetIncrease` for payout sizing.
Unchanged from the original writeup — the backend is closed-source and this remains the pivot
between "bankroll drain" and "falsified public record." The forensics above do not resolve it.
