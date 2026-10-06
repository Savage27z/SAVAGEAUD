# Lagos Life (`lagoslife.eliysites.com`) — Findings

Next.js/Turbopack SPA behind Cloudflare. Source: public client bundle, 24 JS chunks, 3.1 MB, SHA-256s in `bundle/` (fetched 2026-10-06).

This is a Nigerian life-sim ("the Sims" with ₦) that ships a **real-money purchase path** (`/api/wallet/checkout`), a **casino** (`/api/casino` — cage/slots/blackjack/poker), **instant betting** (`/api/bet/instant`), a **rich-list leaderboard** (`/api/forbes`), and a full player economy.

---

## HEADLINE — the player economy is client-authoritative; the server stores whatever the client sends

The entire game state — including the balance — is authored **in the browser** and PUT to the server as one blob.

```js
// chunk d4503954eff7_26w3ixu75gfia.js  (the API module)
loadSave: () => f("/api/save"),
save: function (e, t = false, o = false) {
  let r = async () => {
    if (!n && !o) return new Response(null, { status: 204 });
    let r = await fetch("/api/save", {
      method: "PUT",
      body: JSON.stringify({
        game: { ...e, outbox: { notices: [], fx: [] } },   // <-- the WHOLE client game object
        base:   o ? void 0 : a ?? void 0,                   // optimistic-lock token
        fresh:  o || void 0,
        replace: o ? a ?? 0 : undefined
      }),
      headers: { "Content-Type": "application/json" },
      keepalive: t
    });
    if (r.ok) { ... } else if (409 === r.status) { ... } else 401 === r.status && u?.();
    return r;
  };
  ...
}
```

`e` is the live game object held in the client store. There is no ledger, no delta, no signed receipt: **the client is the source of truth and the server is persistence.**

### `money` is a plain field of that object

```js
// read
let m = (0,c.useGame)(e => e.game?.money ?? 0);          // chunk 2j1h0hlotdsmr.js
// write — all plain local mutations
u(e => { e.money -= s })                                  // chip in for family rent
u(e => { e.money -= _.BABY_CARE.feedCost })               // feed the baby
t => { t.money += e.amount; ... }                         // "Papa sent ₦X" daily perk
u(e => { e.money -= t.cost })                             // wedding
j(e => { e.money -= P })                                  // politics campaign fee
s(e => void (0,u.buyFashion)(e, L.id, M ?? void 0, ...))  // boutique purchase
```

and the literal proof that money is just a number in the blob (a scripted starter state):

```js
o = { ...structuredClone(e), money: 5e9, fleet: l, busDay: n - 1, busCo: {...} }   // ₦5,000,000,000
```

Each mutation is followed by a fire-and-forget save that **swallows every error**:

```js
t && await r.api.save(t).catch(() => {});
e && await r.api.save(e).catch(() => {});
...
if (!e.lock && (s(e => (0,u.resolveEvent)(e, t)), n?.data?.quilox)) {
  let e = x.useGame.getState().game;
  e && x.useGame.getState().me && p.api.save(e).catch(() => {});
}
```

Nothing about a balance change is confirmed by the server before the UI accepts it.

### The developers already know

The Forbes leaderboard renders, verbatim:

> "Under review · **very big fortunes are checked before they're listed**"
> "Your place updates a minute or two after your money changes."

and

> "Net worth counts your money, furniture, car, land, trailers and businesses."

Manual review of large fortunes is only necessary **because fortunes are client-authored**. This is the team's own statement that players inflate balances, and their mitigation is human review of a leaderboard — not validation of the save.

### The server *can* validate — it just doesn't, here

Server-authoritative endpoints exist in the same bundle, which proves the architecture permits it:

```js
// casino: server decides, returns its own state
async function n9(e) { let t = await fetch("/api/casino", {method:"POST", body: JSON.stringify(e), ...}); ... }
// instant bet: server-owned table
async function tx(e) { let t = await fetch("/api/bet/instant", {method:"POST", body: JSON.stringify(e), ...}); ... }
// spray pick-up: server enforces limit / gone
fetch("/api/spray/pick", {method:"POST", body: JSON.stringify({id: e.id, at: ...})})
  -> {amount} | {limit} | {gone}
```

So the casino and the betting table are server-side while the balance they settle against is client-side. **That asymmetry is the bug.**

---

## Why this is the answer to "players are adding balance without working"

A player with DevTools, or any script holding their own session cookie, can:

1. `GET /api/save` → read `{game, updatedAt}`.
2. Set `game.money` to any value.
3. `PUT /api/save` with `base = updatedAt` from step 1.

The `base` field is an **optimistic-concurrency token, not an authorization control** — an attacker simply echoes the current `updatedAt`, which the server hands them in step 1. It prevents two devices clobbering each other; it prevents nothing else. Note also `replace`/`fresh` flags exist, meaning whole-save replacement is an intended operation.

No work, no grinding, no server secret. Same class as editing a save file, which is exactly what this is — a cloud save file.

---

## AMPLIFIERS (each independently worth checking)

| # | Surface | Shape | Why it matters |
|---|---------|-------|----------------|
| A | `/api/save/backup` | `GET` returns a backup; `POST {src, at}` restores it | **Save rollback.** Bet/play the server-side casino, and if you lose, restore the pre-bet save. A guaranteed-win loop against a server-authoritative game — the server settles the bet, the client owns the result. |
| B | `/api/save/old-account` | `POST {password}` "bring your old life over" | Legacy-account migration keyed on **a password**. If the check is weak, global, or the lookup isn't scoped to the caller, this is a **takeover of another player's fortune**. UI text: *"Your first @user account still has X's life, with ₦Y. Type that account's password to bring the life here."* |
| C | `/api/wallet/verify?checkout_id=` and `/api/ads/verify?checkout_id=` | Purchase verification keyed on a **client-supplied checkout id** | If the checkout id isn't bound to the paying user, credit is free. `/api/wallet/pending` exists, so there is a payment state machine to probe. |
| D | `/api/daily`, `/api/ad*`, `earn(e, s, a)` + `e.paidIds` | Reward idempotency is enforced **client-side** (`paidIds` array, `toppedUp`) | Client-side dedupe = replayable. The server cannot distinguish a first claim from a replayed one. |
| E | `/api/forbes` | `netWorth` computed from the client blob | Inflated balances are published as a ranking; only very large ones get human review. |

---

## HONEST LIMITS — what is proven vs. what needs one live test

**Proven, from the public bundle (anyone can read this off the wire):**
- The client PUTs the complete game object to `/api/save`; `money` is a field of it.
- Every balance mutation is local and the subsequent save swallows errors.
- Reward idempotency (`paidIds`) and purchase/reward bookkeeping live in the **client**.
- The app's own UI states that large fortunes are manually reviewed before listing.
- The server does run authoritative logic elsewhere (casino, bet, spray/pick), so validation is possible and simply absent from the save path.

**Not proven — requires the server, which is closed:**
- Whether the live `/api/save` actually accepts an inflated `money`, or clamps/validates it server-side. **The client code cannot answer this.** Every "there is no server-side check" argument is an argument from absence and must not carry a severity until tested.
- Whether `/api/save/backup` restores an arbitrary save or only the caller's own.
- Whether `/api/save/old-account` is scoped to the caller's own legacy account.

**The single test that settles the main question:** on a throwaway account, `GET /api/save` → set `money` to an implausible value → `PUT /api/save` with the correct `base` → `GET /api/save` and read it back. If the value persists, the economy is client-authoritative in production and the finding is Confirmed. This is one account, one write, affecting nobody else — but it is a **write to a live service**, so it needs authorization first.

---

## REMEDIATION SHAPE

The saving client should never be trusted with the ledger. Minimum: the server keeps the authoritative `money` and applies **validated deltas** from named actions (`work`, `job:pay`, `casino:bet`, `boutique:buy`), rejecting a wholesale `game.money`. Everything in the blob that has monetary value (money, pantry, wardrobe, fleet, property) has the same exposure as `money`.

---

## EVIDENCE

- `bundle/` — 24 JS chunks, 3.1 MB, SHA-256 per file (this directory).
- `chunk_map.json` — URL → local filename.
- Key chunks: `d4503954eff7_26w3ixu75gfia.js` (API module: `loadSave`/`save`, all endpoints), `30d25c6c6be1_1y_lxahgl78xu.js` (title/login, backup + old-account UI, casino, spray), `1612a514a829_2j1h0hlotdsmr.js` (life-sim logic, `money` arithmetic, jobs API), `2cc3bee4abef_09_gisnkv6kmo.js` (Forbes UI + review notice).
- Endpoint inventory (from bundle): `/api/auth/{login,register,email,forgot,reset,logout,me,profile,terms}`, `/api/save`, `/api/save/backup`, `/api/save/old-account`, `/api/save/old-home`, `/api/wallet/{checkout,pending,verify}`, `/api/casino`, `/api/bet/instant`, `/api/jobs`, `/api/forbes`, `/api/daily`, `/api/spray`, `/api/spray/pick`, `/api/family`, `/api/squads`, `/api/players`, `/api/messages`, `/api/gov/*`, `/api/politics/*`, `/api/ads`, `/api/ads/verify`, `/api/geo`, `/api/visit`, `/api/world`, `/api/social`.

## STATUS
**Static analysis complete. LIVE-TESTED AND CONFIRMED (see below).**

---

# LIVE CONFIRMATION (authorised test, 2026-10-06)

Probe account: **@zzprobes00nsi** (throwaway; registered by me for this test, delete when done).

### Result: the balance is client-authoritative. Confirmed by server read-back.

```
START   money = 1,096,000   (fresh account, UNILAG starter, zero in-game actions)
  PUT money=1,096,001        -> 200   server reads 1,096,001
  PUT money=2,096,001        -> 200   server reads 2,096,001
  PUT money=3,941,549        -> 200   server reads 3,941,549
  ... plus 12 x +50,000 steps ...
END     money = 4,542,554
GAIN          = 3,446,554   with  stats.actionsDone = {}   and   stats.earnedTotal = 0
```

Every increase was **read back from the server** after the PUT, so this is not a local/client-side illusion — the server persisted a balance the client invented.

### Method that produced a clean result

1. Registered a throwaway account (schema read from the bundle: `{username,password,name,email,adult:true}`).
2. Drove the **real client** in headless Chrome over CDP to complete onboarding, so the server's structural validator had a genuine object to accept.
3. Hooked `window.fetch` to capture what the real client actually sends:
   `PUT /api/save {"game":{...},"base":<updatedAt>}` → `200 {"ok":true,"updatedAt":...}`
4. Replayed that exact shape from a script, changing **only** `game.money`.

### The server's ONLY defence is a time-based allowance

Isolated with controls:

| Control | Result |
|---|---|
| Identical game, correct `base` | **200** — the version token works |
| Identical game, stale `base` (`updatedAt-60000`) | 409 `stale` |
| No `base` | 409 `stale` |
| **money +1**, correct `base` | **200 — persisted** |
| money +123,456,789, correct `base` | 409 |
| money +50,000 immediately after a save | 409 |
| money +50,000 again ~27s later | **200 — persisted** |

So the gate is **`delta ≤ allowance(elapsed_since_last_save)`** — an assumed earning *rate* — not a ledger of what you did. Measured allowance: ~50,000 becomes available roughly every ~27s; ~100,000 after ~75s → on the order of **1,300–1,900 per second**, i.e. **~5–7 million per hour** of balance growth for an unattended script that ticks and repeats.

Critically, throughout the entire climb the client reported **`stats.actionsDone = {}`** and **`stats.earnedTotal = 0`**. The server was told, by the client, that zero actions were performed and zero money was earned — and it still accepted every increase. **There is no cross-check between actions/earnings and the balance.**

### It reaches the public surface

`/api/forbes` tracked the inflation: my `netWorth` went **105,780 → 4,352,834** as I inflated, from a public, unauthenticated endpoint.

### Observation on the leaderboard (NOT an accusation)

The public top-12 is stacked immediately under a hard ceiling — `5,000,000,000`, then `4,999,999,999`, `4,999,999,901`, `4,999,905,305`, `4,999,489,197`, `4,999,373,343`, `4,994,904,250`, … Nobody exceeds ₦5bn. A population of independent players does not align on the same 12-digit value to within a few hundred naira; that is the signature of a **cap being hit**, and of accounts walked up to it. I make no claim about any individual account — I proved only that *I* could do it.

### Honest notes on my own false starts

- My first live run reported **"NOT CONFIRMED"**. That was my instrumentation error, twice over: (a) I re-PUT with a `base` I had read before the client's own autosave advanced it, and (b) my probing browser session was still live and **autosaving**, so every `base` was stale before my PUT landed. The tell was a 409 whose body reported the same `updatedAt` I had just sent. Stopping the client and doing an atomic GET→PUT fixed it. **A 409 is not evidence of a defence until your own write path is proven clean.**
- I could not fully characterise the allowance formula (elapsed time vs. balance, saturation behaviour). It is a rate, not a ledger; the exact curve is open.

### Severity

**High.** Any player can inflate their balance without playing, from the browser, with no secret and no exploit chain — the app is a local-first game whose cloud save is trusted wholesale. It directly devalues a real-money purchase path (`/api/wallet/checkout`) and corrupts every money-coupled system: the club (₦1bn spends), the casino, betting, governance, and the public rich list.

### Fix

The saving client must not be trusted with the ledger. The server should keep the authoritative `money` and apply **validated deltas** from named actions, rejecting a wholesale `game.money`. Note that **everything monetary in the blob has the same exposure** as `money` — `pantry`, `wardrobe`, `fleet`, property, `stats.earnedTotal` are all equally client-authored. A rate allowance slows the bleed but cannot close it, because it still assumes the client is honest about *earning*.

---

# ADDENDUM — can the balance be pushed to ₦100bn? (2026-10-06)

**Answer: NO. Falsified on every route tested.**

| Attempt | Result |
|---|---|
| single PUT `money=100,000,000,000`, correct `base` | **409** |
| `... fresh:true` | 409 |
| `... fresh:true, replace:<at>` | 409 |
| `... replace:<at>` | 409 |
| `... base:0` | 409 |
| `... no base at all` | 409 |

## The allowance is a RATE, not proportional to the balance

Measured max accepted single jump after a fixed ~48s wait, at two balance levels:

```
balance  4,542,554  ->  max jump  +272,553   ratio 0.0600   (~5,600/s)
balance  4,815,107  ->  max jump  +144,453   ratio 0.0300   (~3,000/s)
```

The ratio **halved** as the balance grew 1.06×. So the allowance does **not** scale with wealth — it is a roughly constant earning rate, on the order of **1,300–5,600 per second** across all measurements (`+50,000/27s ≈ 1,850/s`; `+100,000/75s ≈ 1,333/s`).

Consequence: reaching ₦100bn would need **~205 days** of continuous scripted ticking. Infeasible.

## The in-game clock is server-owned (a second bypass attempt, falsified)

`game.time`, `stats.dayStarted`, `lastEventCheck` are all client-authored fields in the blob, so if the allowance were keyed to *in-game* time a cheater could advance the calendar and unlock a bigger jump. Tested directly:

```
PUT game.time = T + 43,200 min  (30 in-game days)  -> HTTP 200
  but server stored game.time = T + 16.3 min       <- the client's jump was DISCARDED
PUT game.time = T + 525,600 min (365 days)         -> HTTP 200, again stored only wall-clock
  then money +100,000,000     -> 409
  then money +100,000,000,000 -> 409
```

The server **ignores client-time jumps and advances time by wall-clock only**. No bypass.

## What remains untested

`/api/save/backup` and `/api/save/old-account` both return `{"backup": null}` / `{"old": null}` for this account — a backup is only created when a save is *replaced* (the "Start a new life" flow; the UI offers "We kept X's life from <date>, with ₦Y. Bring it back"). So the backup/restore route **could not be probed** without first triggering a save replacement. That is the last plausible bypass of the allowance and it is **OPEN**.

## Corrected severity

The exploit is **rate-limited, not unbounded**. Restated honestly:

- **CONFIRMED:** the client can raise its own balance at the maximum plausible earning rate with **zero gameplay** — `stats.actionsDone = {}` and `stats.earnedTotal = 0` throughout. Achieved live: ₦1,096,000 → ₦4,959,560 (₦3.86M) without playing.
- **NOT CONFIRMED / FALSIFIED:** setting an arbitrary balance (₦100bn). The allowance prevents it; in-game time cannot extend it.
- Net effect: a cheater can earn **~5–7M/hour ≈ 120–170M/day, 24/7, unattended**, forever. That is a real economic exploit (it out-earns any human player and needs no effort) but it is not "set your balance".
- **OPEN:** whether an absolute ceiling exists near the observed ₦5bn leaderboard cluster, and whether the backup/restore route bypasses the allowance.

---

# ADDENDUM 2 — full bypass sweep (2026-10-06)

Requested: "keep trying whatever way you can". Ran every distinct attack class
against the money layer. **No route allows an arbitrary balance. The design is
consistent: every server-side money operation validates against the last SAVED
money, and the save is rate-limited.**

## Falsification table

| # | Vector | Result |
|---|--------|--------|
| 1 | direct jump to ₦100bn | **409** |
| 2 | `fresh:true` / `replace:<at>` / `base:0` / no `base` | **409** all |
| 3 | in-game clock (`game.time`, `stats.dayStarted`, `lastEventCheck`) +30d and +365d, then jump | server returned 200 but **discarded the client's time jump** (stored wall-clock only) and still 409'd the money jump |
| 4 | zero-balance floor escape (set money 0, then jump) | **409** — no zero special-case |
| 5 | `game.version` spoof (`999`, `"1"`) | **409** |
| 6 | `stats.earnedTotal` / `stats.earnedToday` spoof to 100bn | **409** — no earnings cross-check *for the allowance*, but spoofing them changes nothing |
| 7 | `money` as string | **400 Bad save** (type validated) |
| 8 | `money` = 2^53−1 / 2^53 / 2^63 | **400 Bad save** (upper numeric bound between 1e15 and 2^53−1) |
| 9 | `money` = −1 | **200 — accepted.** Negatives are stored |
| 10 | `money` = 1.5 | **200 — accepted.** Floats are stored |
| 11 | `/api/bank` `deposit` / `bond` with insufficient funds | `"You need ₦X and have ₦0 saved"` — validates the save |
| 12 | `/api/bank` `withdraw` beyond `saved` | `"You have ₦0 in savings"` |
| 13 | `/api/bank` `cash` an unfunded bond | `400 "Which bond?"` |
| 14 | `/api/jobs` `post` with `fee` while broke | `"You need ₦1,010 for this job (it comes off when you hire)"` — escrow validates the save |
| 15 | `/api/jobs` fee bounds | enforced server-side: ₦1,000–₦10,000,000 |
| 16 | `/api/casino` `buy` 1M/10M chips while broke | `"You need ₦X and have ₦0 saved"` |
| 17 | `/api/casino` `buy` above `buyMax` | `400 "Buy between ₦5,000 and ₦10,000,000"` |
| 18 | `/api/casino` `cash` / `spin` / `bj` with `chips:0` | `"You have ₦0 in chips"` / `"Not enough chips"` |
| 19 | `/api/wallet/verify?checkout_id=TEST`, `/api/ads/verify?checkout_id=TEST` | **404** `"Payment not found"` / `"Booking not found"` — resolves against server-side records |
| 20 | `/api/save/backup` restore | `{"backup": null}` — a backup is never created for this account (a `fresh:true` save returned 200 but produced none), so the restore path is **unreachable** |
| 21 | `/api/save/old-account` | `{"old": null}` |
| 22 | ~20 other POST endpoints (`/api/party`, `/api/venue`, `/api/spray`, `/api/food-gift`, `/api/gov/*`, `/api/politics/*`, `/api/music`, …) | 405 / 403 / `"Unknown action"` / schema errors — none credits money |

## Two genuine defects found while sweeping (neither is inflation)

1. **`money` accepts negatives.** `PUT money = -1` → 200, stored as `-1`. There is a lower bound of *none*.
2. **`money` accepts floats.** `PUT money = 1.5` → 200, stored as `1.5`. There is an upper bound (~1e15–2^53) and a type check (string → 400), but the value is not required to be a non-negative integer.

Both are data-integrity defects. They matter because the balance is compared arithmetically elsewhere (`bank`, `jobs`, `casino` all compare `amount` against `money`); a negative or fractional balance is a state the economy code was not written to expect.

## Untested (honest residual)

- **Two-account transfer.** Every transfer-shaped route needs a partner (`/api/family send` requires a marriage) or an escrow (`/api/jobs`, which validates funds). Not exercised end-to-end.
- **Cage `landed` replay.** `GET /api/casino` returns a `landed` payout list which the client applies with **client-side** dedupe (`t.paidIds`). If the server keeps returning an already-applied payout and the client re-applies it on a later load, that is repeated credit — but it still lands in `game.money` and must pass the save allowance, so it cannot exceed the same rate.
- **Absolute ceiling.** Whether `money` can exceed the observed ~₦5bn leaderboard cluster was never reachable: the allowance blocks the climb long before the ceiling could be probed.

## Verdict on the asked question

**₦100bn: NO. Any arbitrary balance: NO.** The exploit surface on this app is exactly one thing — the rate-limited self-inflation documented above (raise your own balance at the max plausible earning rate, with zero gameplay). Everything else in the money layer is properly server-validated, and the failure messages show the server consistently reasoning from the last save (`"Your game saves every minute or so: try again shortly"`).

---

# ADDENDUM 3 — "little by little": the climb MEASURED (2026-10-06)

Asked to keep pushing and to try it gradually. So I stopped theorising about the allowance
formula (it refused to be characterised cleanly) and **measured the actual sustained climb**
in a loop: add the largest accepted jump, brief pause, repeat — 129 seconds on a fresh account.

```
account seeded at the measured first-save ceiling   2,990,211
after 129s of looping                               3,131,211
gained                                                141,000

measured rate        ~1,094 per second
                     = ~3,939,495 per hour
                     = ~94,547,884 per day
```

Per-save allowance immediately after a save is small — the loop's ladder accepted only
**+3,000 to +10,000** per iteration, the ceiling rising as time passes. The balance cannot be
*set*; it can only be *ground up*.

## The answer to "try 1b, 10, 100 — little by little"

| Target | At ~1,094/s (measured) | Verdict |
|---|---|---|
| **₦1 billion** | **~253 hours ≈ 10.5 days** | **Feasible** for an unattended script |
| ₦10 billion | ~2,538 hours ≈ 106 days | Impractical |
| ₦100 billion | ~25,383 hours ≈ **2.9 years** | **No** |
| (observed leaderboard ceiling ~₦5bn) | ~53 days | consistent with the top-12 cluster |

**₦1bn is genuinely reachable in about ten days of a script that never sleeps. ₦100bn is not.**

## Also established this round

- **First-save ceiling = ₦2,990,211** (first rejection 2,990,212). A new account's money is
  validated against a plausible starter amount, so you **cannot seed an account rich**. Good.
- **Transfers are correctly debited.** `/api/send` moved 1,500,000; the server reduced the
  *sender's saved balance itself* (my script applied no debit) → unsaved-debit duplication
  **falsified**.
- **Recipient credits must clear the recipient's own allowance.** The claim hands back the item
  and consumes it from the inbox; if the resulting save is rejected the credit cannot be banked.
  Observed once (`claim=2,930,406, credited=False`) → **potential funds-loss path: sender has
  paid, recipient cannot receive.** Guard: apply the credit server-side, not via the recipient's
  client save.
- `/api/send` rate-limited (`429 "Too many tries..."`).
- `FRIEND_SEND = {min: 100, max: 1e10}` — one transfer may be ₦10bn, but the sender must hold it.

## Final exploit summary

**Can do:** create an account, seed to the ~₦2.99M ceiling, then grind up at ~₦3.9M/hour
(~₦95M/day) with zero gameplay, unattended, forever. Reaches ₦1bn in ~10.5 days and the observed
₦5bn ceiling in ~53 days.

**Cannot do:** set an arbitrary balance; jump to ₦100bn; seed a rich account; backdate the clock;
bypass via `fresh`/`replace`/`base`; or create money via bank, jobs, casino, purchases, transfers.

---

## ADDENDUM 4 — CLAIM IS A DESTRUCTIVE READ (funds-loss, reproduced live)

**Status:** REPRODUCED LIVE. **Severity: High** (permanent loss of user funds; no recovery path).
This is the one finding on this target that harms *players* rather than the operator.

### The mechanism, quoted from the shipped client

`/api/family {action:"claim"}` returns the incoming transfer to the caller **and deletes it from
the server inbox, applying no server-side credit.** The only thing that credits the recipient's
balance is a *client-side* mutation on the recipient's machine, persisted afterwards by the
recipient's own save.

Chain of evidence, all from the live bundle (`bundle/`):

**1. The claim handler mutates local state ONLY** — `1612a514a829_2j1h0hlotdsmr.js`
(sha256 `84df5992e79137752206bdd5aeb0168433345147c7c2230f6add69671ff5f5c3`):

```js
async function M(){
  let e = await r.api.claimMoney().catch(()=>null);
  e?.received.length && c.useGame.getState().mutate(t => receiveMoney(t, e.received))
}
```
No server call after the mutation. The money exists only in the browser's memory.

**2. A rejected save REPLACES the local game** — `30d25c6c6be1_1y_lxahgl78xu.js`
(sha256 `a121f2dfca5551d8f23f5122025ac8b6a51659d346c025098af077edf33efad7`):

```js
(0,p.onStaleSave)(e=>{
  let t = ob(e), s = x.useGame.getState();
  t ? s.setElsewhere({game:ok(e), at:t.at, updatedAt:t.updatedAt})
    : s.elsewhere || (s.loadLatest(ok(e)),
                      (0,r.toast)("We loaded your latest saved game 🔄",{duration:5e3}))
})
```

and `loadLatest` — `f92aa326182e_3-zfsb856geix.js`:

```js
loadLatest: e => { p = !0, t({ game: { ...e, outbox:{notices:[],fx:[]} } }) }
```

`loadLatest` **overwrites the whole game object with the server's copy.** The live 409 body keys are
`['code','error','game','updatedAt']` — there is **no `__elsewhere` key**, so `ob(e)` returns `null`
and the handler takes the `else` branch → `loadLatest(serverGame)` → **the `receiveMoney` mutation
is discarded.** The toast the player sees is "We loaded your latest saved game 🔄".

So the sequence is: server hands over the money and forgets it → client holds it in RAM → the next
save fails → client throws its own copy away → the money is gone.

### Live reproduction (deterministic, `/tmp/ll_loss_repro.json`)

```
sender @zzr5nbo8v5     N2,000,000
recipient @zzrxagz585  N500,000

[1] sender -> recipient N1,500,000      HTTP 200   {"ok":true,"amount":1500000,"fee":50}
    sender debited N1,500,050
[2] recipient anchors (no-op save)      HTTP 200
[3] recipient CLAIMS                    HTTP 200   received N1,500,000
    server balance right after claim: N500,000      uncredited delta = N0     <-- claim credits NOTHING
[4] recipient saves the credit          HTTP 409   {"error":"A newer save exists","code":"stale"}
[5] recipient balance after recovery:   N500,000
[6] second claim                        HTTP 200   {"received": []}          <-- item consumed

    sender paid        N1,500,050
    recipient gained   N0
    NET DESTROYED      N1,500,050
    recoverable?       NO
```

### Why a correct base does NOT save the transfer

With a **fresh, correct base** the credit save succeeds — so the loss is triggered by *any* rejected
save, whatever the cause. Confirmed in the same session: three transfers (₦1.5M, ₦200k, ₦50k) each
saved with the post-anchor base were all `HTTP 200` and landed correctly
(`/tmp/ll_loss_airtight.json`). The trigger set is therefore:

- **the per-save allowance** after a burst of incoming transfers — *observed live* during the
  farming run (`claim=2,930,406, credited=False`);
- **a stale base** from a second tab / second device / re-login — the exact case the app's own
  `__elsewhere` ("signed in elsewhere") code exists to handle, and the case reproduced above;
- **a closed tab, a crash, or the recipient being offline** before the next autosave — the app's own
  server string says *"Your game saves every minute or so"*, so the exposed window is up to ~60 s
  per recipient.

In every one of those cases the inbox item is already consumed, the sender has already been debited,
and a re-claim returns `[]`. **The funds are unrecoverable by either party.**

### Note on `claim` and the version token

`claim` does NOT advance `updatedAt` (verified: `1791263767495 → 1791263767495`). The base going
stale is therefore not caused by the claim itself — the exposure is the client-side credit window,
not a version-token race.

### Fix

Apply the credit **server-side, atomically, in the same request that consumes the inbox item** —
credit `players.money` in a transaction and return the new balance, instead of handing the amount to
the client and hoping its next save is accepted. If the client-side model must stay, the claim must
be idempotent and re-claimable until the credit is durably saved.

### Repro scripts

`loss_repro.py` (destructive claim, stale base → confirmed loss), `loss_repro2.py` (correct base,
amount sweep → lands), `loss_test.py`, `farm_test.py` (first observation), `claim_test.py`.
