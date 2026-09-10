# F01 — ADDENDUM & **CORRECTION**: on-chain forensics on all 7,329 `increaseBet` txs

**Date:** 2026-09-10
**Method:** full-history `eth_getLogs` scan of the live contract + calldata decode of every
`increaseBet` transaction ever mined + client-bundle analysis. No fork, no synthetic data.

> ## ⚠️ THIS DOCUMENT CORRECTS ITS OWN FIRST DRAFT
>
> An earlier version of this addendum concluded **"the player submits the transaction, therefore
> any player could have zeroed `msg.value` and replayed their signature."** That conclusion was
> **wrong** and has been retracted. It was pushed in commit `ac15485` before being checked
> properly. The evidence below is the same; the interpretation is corrected.
>
> **What was right:** the on-chain facts (7,329 txs, `tx.from` == `game.player`, 554 players,
> zero signature reuse, 15-minute deadline, dormant since 2026-04-12, signer identified).
>
> **What was wrong:** assuming `tx.from == game.player` means the *player* chose the calldata and
> `msg.value`. On Abstract it does not — see §2.

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
| Distinct player accounts | **554** |
| Signature deadline window | **exactly 15 minutes** after each call |
| Amounts seen | 0.0005–0.01 ETH (median 0.001) |

The feature ran for one month across 554 users, then was switched off. Not called once in the
five months since.

- No player-facing button today (confirms the earlier live-UI check).
- No API route either: `/api/games/<id>/increase-bet` returns the Next.js 404 page, while the
  genuine sibling route `/api/games/<id>/select-tile` returns `{"error":"missing jwt"}` 401.
  (Probe method validated against a known-real route, not assumed.)
- The function is still deployed and still callable. The frontend still ships the ABI entry and
  the session-key policy granting it `valueLimit: Unlimited`.

**Net:** dormant, not removed.

## 2. Who submits? — the backend, not the player

The first draft read `tx.from == game.player` as "the player sent it". That inference is invalid
on Abstract. Three independent checks, in order of strength:

### 2a. The transactions are type-113 (native account abstraction)

Both a real `increaseBet` tx and a real `createGame` tx are **type `0x71` = 113**, the zkSync
EIP-712 native-AA transaction type:

```
type 0x71   from 0xad2d158d…35aad   to 0x27edd1…b20c   value 0x1c6bf52634000
```

The `from` account is a **smart contract** (1,632 bytes of code at both sampled player
addresses), not an EOA. On this transaction type the `from` field is the *account*, and the
account's validator decides which key signed: the owner's key **or any session key installed on
the account**. So `from == player` identifies **whose account acted**, not **who signed the
order**. A relayer holding a session key produces exactly the same on-chain shape.

### 2b. The client bundle never handles a signature — decisive

If the player were submitting, the client would need the server's signature to build the call.
It does not. Across all 76 frontend chunks:

- **Every** occurrence of `serverSignature` is inside an ABI definition (`name:"serverSignature"`).
  Non-ABI occurrences: **zero**.
- **Every** occurrence of `preliminaryGameId` is likewise inside an ABI definition; the single
  non-ABI use is `let {preliminaryGameId} = await resp.json()` — it reads an *identifier* from
  the REST API and does nothing else with it.
- The only client call-site referencing `createGame` is a **gas estimate** with placeholder
  arguments — a zeroed `bytes32`, a zeroed 130-hex-character dummy signature, and
  `account: 0x…0001`. It exists to quote a fee to the user; it is not a submission.

A client that never receives a signature cannot construct a signed call. Whatever submits these
transactions holds the signature, and it is not the browser.

### 2c. The session key belongs to the server

From the app's own session-key policy:

```js
signer: NEXT_PUBLIC_SERVER_WALLET_ADDRESS   // 0xc372B35582933277d5f4431F1a322Abc8DeA0612
callPolicies: [ createGame (Unlimited, cap 100 ETH/use), cashOut (LimitZero),
                markGameAsLost (LimitZero), increaseBet (Unlimited, cap 100 ETH/use) ]
```

The grant names the **server wallet** as the session signer, and the client PATCHes that config to
`/api/users` — i.e. it is handed to the backend for the backend to use. This is consistent with
2a and 2b: the backend signs an admin message, then signs and broadcasts a type-113 transaction
through the session key, with the player's account as `from`.

**Corrected conclusion:** the exploit path is **not** held by players. A player never possesses a
signature, never chooses `msg.value`, and has no code path to build the call. `tx.from == player`
is an artefact of session-key architecture, not evidence of player authorship.

**This means the original writeup's inference was correct after all** — *"an unlimited-value
permission grant isn't registered for dead code; the backend evidently calls this server-side."*
The backend does. The first draft of this addendum wrongly "corrected" that.

## 3. Impact on the rating — F01 is downgraded

| | Original writeup | After forensics |
|---|---|---|
| Exploitable by | "any ordinary player, no elevated privilege" | **the backend only** (or a compromised session/admin key) |
| Likelihood | High | **Low for external exploitation** |
| Severity | High | **Low / informational — defence-in-depth** |

F01 is a **latent hardening gap, not a live drain**:

- The two missing checks are real and still deployed.
- The function is public and callable — but it **reverts without a valid admin signature**, and
  no external party can obtain one.
- The observed production flow was **correct in practice**: all 7,329 calls attached exactly the
  signed amount, and zero signatures were ever reused.

What keeps it worth reporting rather than dropping:

1. **Payer-controlled signatures are one integration away.** The contract's safety depends
   entirely on the *off-chain* caller choosing the right `msg.value`. The provider/iframe mode
   (`/api/i/…`, `sessionPolicyV2`) and any future partner or alternative client are new callers
   who may not preserve that property. The contract should not need to trust them.
2. **Systemic inconsistency.** `createGame` binds `msg.value` into its signed hash; `increaseBet`
   does not. There is no nonce/used-signature tracking anywhere in the contract. Adding a third
   deposit function by copy-paste is a natural next step and would inherit the gap.
3. **Cheap to fix, no migration cost** — bind `msg.value` into the hash and add a nonce.
4. **Zero cleanup needed** — no signature was ever replayed, so no bad state exists.

Still unresolved and unchanged: whether the backend trusts on-chain `betAmount`/`BetIncrease` for
anything. It no longer affects exploitability (only the backend can write that value), but it
still bounds how bad a future mis-integration would be.

## 4. What was actually learned here

The generalisable lesson, worth folding into CHECKLIST.md: **on a native-AA chain, `tx.from` is
the account, not the signer.** Session keys, relayers, and paymasters all produce transactions
that look like the user's. `tx.from == subject` proves *whose account*, never *who ordered it*.
Determining authorship requires reading the client for signature handling — which is what should
have been done before drawing the conclusion the first time.

## 5. Closing the last gap — what the client actually receives (2026-09-10, third pass)

The retraction above rested on a string search: `serverSignature` appears 20 times in the
production bundle and all 20 are inside ABI definitions. That is strong but it is a *negative*
result, and a negative result from a literal-string grep has an obvious hole — if the backend
returned a signature under a different field name (`sig`, `signature`, `payload`), the grep would
miss it. So this pass checked the **flow itself** instead: what does the client do, and what does
it actually read out of the response?

From `/api/abstract/games/create`'s call site (`chunks/3vf1zq2-0zz2k.js`):

```js
let a = CURRENT_APP === DEATH_FUN_APP ? "/api/abstract/games/create" : "/api/games/create";
let i = await fetch(`${a}?${r.toString()}`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: stringify({ betAmount: ei, rowConfig: t.map(e => e.tiles) }),
    credentials: "include",
});
if (!i.ok) { /* error toast */ }
let { preliminaryGameId: n } = await i.json();      // <-- the ONLY field destructured
return { nextGameId: n };
```

and the loading state it shows is the literal string `"Preparing game…"`.

Then on success it does **not** sign, does **not** build calldata and does **not** send a
transaction. It invalidates the `/api/games/active` and user queries and sets `fresh: false`, and
the active-game poller (`refetchInterval`) waits while `currentGame.status` is one of
`["cashout_pending", "pending_onchain", "increase_bet_pending"]`.

Three things follow, and they close the hole completely:

1. **The response contains one field, `preliminaryGameId`.** Not "the client ignores a signature"
   — the client *cannot* receive one, because it only ever reads one key out of the response body.
2. **The word "Preparing" is accurate.** The client's job ends at asking. There is a
   `pending_onchain` status precisely because the on-chain call has not happened yet when the
   client is done — something else has to do it.
3. **`increaseBet` uses the identical shape.** It has its own pending status
   (`increase_bet_pending`) in the same poller, which is the same prepare-then-poll pattern: the
   client asks, the backend signs and submits, the client waits for the status to change.

Combined with the session-key grant (where the session's `signer` is
`NEXT_PUBLIC_SERVER_WALLET_ADDRESS = 0xc372B35582933277d5f4431F1a322Abc8DeA0612`, a signer-only EOA
with nonce 0 and balance 0), the picture is unanimous across four independent artifacts: the
client bundle's lack of any signature handling, the absence of any signature-issuing API route,
the response-body destructuring above, and the pending-status poller.

**So the one genuinely open soft spot is now closed.** The residual uncertainty is no longer "does
the client secretly get a signature" — it is only the irreducible fact that the backend is closed
source, so we cannot audit the server side itself. A funded live capture (log in, play a game,
record every response) would close even that, and remains the recommended next step.

### 5.1 Reconciling with the earlier "restore High likelihood" pass

Commit `3b095dd` rated likelihood **High** on the strength of the session-key grant for
`increaseBet` (`valueLimit: { limitType: Unlimited }`), reasoning that a team does not register an
unlimited-value grant for dead code, so the backend must be calling it regularly. **That premise
is correct** — the backend does call it. The conclusion drawn from it does not follow, and the
distinction is the whole finding:

> "The feature is used regularly" and "an outside party can reach it" are different questions.

The grant assigns a permission to the **server wallet** to submit `increaseBet` on the player's
account. It is not a capability handed to the player, and the signature exists only on the server
that produces it. Likelihood, as an axis, asks whether someone outside can reach the flaw — and
nothing in the grant moves that. Hence **Low (external)**, with the full three-round trail kept in
the finding so the reasoning is auditable rather than just its endpoint.
