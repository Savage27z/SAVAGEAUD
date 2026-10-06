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
**Static analysis complete. Live reachability UNPROVEN — gate: authorization to test on a throwaway account.**
