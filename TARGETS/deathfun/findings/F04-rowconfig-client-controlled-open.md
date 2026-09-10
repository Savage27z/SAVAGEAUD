# F04 — `rowConfig` is client-supplied and only client-side-bounded (OPEN, not confirmed)

**Target:** death.fun (DeathFun) — Abstract, chain ID 2741
**Date:** 2026-09-10
**Status:** ✅ **CLOSED — VALIDATED SERVER-SIDE. Not a vulnerability.** See §0.
**Severity:** none. The requested input is rejected before any game exists.

---

## 0. RESOLUTION (2026-09-10) — the server validates `rowConfig` completely

Tested live against the real endpoint with an authenticated session. The server rejects malformed
boards with a per-element zod schema, and **no game is created and no funds are spent on rejection**:

| board sent | server response |
|---|---|
| `[8] × 25` | `400` — *"Each row must have at most 7 tiles."* (per row) |
| `[0] × 25` | `400` — *"Each row must have at least 2 tiles."* (per row) |
| `[1] × 25` | `400` — *"Each row must have at least 2 tiles."* |
| `[-1] × 25` | `400` — *"Too small: expected number to be >=0"* **and** *"at least 2 tiles"* |
| `[3.5] × 25` | `400` — *"Invalid input: expected int, received number"* |
| `[3] × 5` | `400` — *"Must have exactly 25 rows."* |
| `[3] × 25`, bet 1 wei | `400` — *"Bet is below the minimum allowed bet of 0.001 ETH."* |
| `[3] × 25`, bet 1 ETH | `400` — *"Bet exceeds the maximum allowed bet for the current game balance."* |

So the schema enforces, per element: **array**, **exactly 25 rows**, **integer**, **≥ 0**, **≥ 2**,
**≤ 7**. Every route to `tiles = 0` is closed, so `sha256(seed-rowN) % 0` → `NaN` is unreachable.

The client-side UI toast was never the real control — the server-side schema is. §1–§3 below are kept
as the record of the hypothesis and how it was killed; the "client is the only bound observed"
reasoning in §1 was an argument from absence (the server code isn't visible), and it was wrong.

**Bonus from the same session:** the contract genuinely validates *nothing* (§1 of
`auth-blockade-and-contract-trust-model.md`), so the server schema is the *entire* defence for the
board — and it holds. Also confirmed: `increaseBet` has **no client call site and no REST endpoint**
(the ABI and the dormant session policy are the only references, and selector `0x0b669290` appears
nowhere), which settles F01's reachability as **not reachable through the app**.

### The request format, for anyone reproducing this

The body must be **superjson**-wrapped, because `betAmount` is a `bigint`:

```json
{"json":{"betAmount":"1000000000000000","rowConfig":[3,3,…25 values…]},
 "meta":{"values":{"betAmount":["bigint"]}}}
```

A plain `{"betAmount":…,"rowConfig":[…]}` body produces
`expected bigint/array, received undefined` — the fields are never populated.

---

## 1. What the code does

The client builds the create-game request body itself, including the board shape:

```js
// chunks/3vf1zq2-0zz2k.js
let t = ee;                                   // the row config, from client state
fetch("/api/abstract/games/create?gameType=death_race", {
  method: "POST",
  headers: { "Content-Type": "application/json" },
  credentials: "include",
  body: B.default.stringify({ betAmount: ei, rowConfig: t.map(e => e.tiles) }),
});
```

`rowConfig` is therefore an array of tile counts **chosen by the caller**.

The only bound I can find is client-side, in a UI input that validates before setting state:

```js
// chunks/33e3oiue0bp6x.js
let e = parseInt(T);
isNaN(e) || e < u.DEATH_RACE_MIN_TILES || e > u.DEATH_RACE_MAX_TILES
  ? f.toast.error(`Tile count must be between ${u.DEATH_RACE_MIN_TILES} and ${u.DEATH_RACE_MAX_TILES}`)
  : (O(!1), P(""));
```

with `DEATH_RACE_MIN_TILES = 2`, `DEATH_RACE_MAX_TILES = 7`, `DEATH_RACE_TOTAL_ROWS = 25`
(`chunks/0yg8x3o7uh0c_.js`).

## 2. Why that would matter

The skull is `deathTileIndex(row i) = parseInt(sha256("<seed>-row<i>").slice(0,8),16) % tiles_i`.

- **`tiles_i = 0`** → `x % 0` is **`NaN`** in JS → `deathTileIndex` is `NaN` → the client's
  `isDeathTile = (pickedIndex === NaN)` is **always false** → the player can never land on a
  skull, survives every row, and cashes out at the multiplier cap.
  Caps that would limit (not prevent) the damage, from the constants module:
  `DEATH_RACE_MAX_MULTIPLIER = 500`, `MAX_PROFIT_PERCENTAGE = .05` (payout ≤ 5% of pot),
  `MAX_BET_PERCENTAGE = .01`.
- **`tiles_i = 1`** → the index is always `0` → the single tile is always the skull (a
  guaranteed *loss*), so this value is only interesting as a control.

## 3. What the on-chain history says — mixed, and it does not settle it

`provably-fair/scan_rowconfigs.mjs` sampled 450 games across the whole `gameCounter` range
(1 → 4,839,021), decoded `games(uint256)` straight from the contract, and grouped tile values by
`rowConfig` length:

```
len=4   ~15 games   values 1..2
len=6    ~1 game    values 1..3
len=8    ~1 game    values 1..4
len=10   ~3 games   values 1..5
len=12   ~2 games   values 1..6
len=16   ~3 games   values 1..8
len=20  ~37 games   values 1..10      <- the "ladder" mode, symmetric descending configs
len=25  ~370 games  values 2..7  ONLY     <- death_race
```

Two facts, pointing opposite ways:

- **For the bug:** the lengths 4–20 mode carries values **1 and 8–10** on-chain. So the server
  does **not** clamp `rowConfig` to a single global `[2,7]` — bounds are per-mode at best, and
  for at least one mode they are wide. There is no evidence of a server-side check anywhere.
- **Against the bug:** across **370** sampled death_race games, **every** config is strictly
  within `[2,7]` — zero exceptions — and **no tile value of `0` appears anywhere in the 450-game
  sample.**

The most likely reading is that the client has simply always sent `[2,7]` because its own UI
enforces it, and **nobody has ever tried otherwise**. That is exactly what an unexercised
vulnerability looks like — and also exactly what a properly server-validated parameter looks
like. **These two cannot be distinguished from outside.**

Example out-of-bound config actually on-chain (the other mode, not death_race):

```
gid=1385686  rowConfig=[10,10,9,9,8,8,7,7,6,6,5,5,4,4,3,3,2,2,1,1]
             gameState={"selectedTiles":[[7,7]]}
```

## 4. Why it could not be settled here — the auth blockade, precisely characterized

Previously recorded as "Cloudflare Turnstile needs IPv6". The real reason is narrower and
harder to route around:

1. **death.fun's own session auth is 100% Privy.** Every game endpoint is `credentials: "include"`
   with **no** `Authorization` header — the backend reads a first-party cookie (Privy's
   `privy-token`), and answers `401 {"error":"missing jwt"}` without it. Every request routed
   through `/api/abstract/games/create` returns that 401 **before** any body parsing, so the
   server's `rowConfig` validation cannot be probed unauthenticated.
2. **Privy wallet/SIWE login is disabled at the app level.**
   `POST https://auth.privy.io/api/v1/siwe/init` with the app's own app id
   (`cm6txbwad00ikeoi9wu5wmi8p`, inlined in the client bundle as `NEXT_PUBLIC_PRIVY_APP_ID`)
   returns `403 {"error":"Login with wallet not allowed","code":"disallowed_login_method"}`.
   The bundle agrees: `privyProviderType: "abstract"` →
   `loginMethodsAndOrder: { primary: ["privy:${AGW_APP_ID}"] }`, i.e. **Abstract Global Wallet
   only**, which is a browser flow.
3. **That browser flow sits behind Cloudflare Turnstile**, which loads an asset from
   `brunhild.challenges.cloudflare.com` — an **IPv6-only** host with no A record (checked via
   DNS-over-HTTPS, not just the local resolver). This container has **no IPv6 route**, so the
   asset never loads (`[Cloudflare Turnstile] Error: 600010`), the Privy modal renders no login
   options, and no session can be minted.
4. The one HTTP-only auth flow present in the bundle (`/api/v1/auth/nonce | verify-signature |
   token`, PKCE, `X-Terminal-SDK-Version`) belongs to the **Terminal** SDK and posts to
   `https://terminal-backend-six.vercel.app` — a third-party stats integration, not death.fun.
   It carries `scope: "read:stats"` and is useless for the game API. (This also explains the
   404s seen on those paths earlier.)

**Conclusion: no session can be obtained without a real browser.** The check requires one manual
paste. See `disclosure/live-capture/rowconfig-probe.js`.

## 5. How to settle it (one paste, ~20 seconds)

`disclosure/live-capture/rowconfig-probe.js`, in the console at death.fun while logged in:

1. Sends **one legal control board** (`[3] × 25`) — proves the probe itself works.
2. Sends **one zero-tile board** (`[0] × 25`) — the actual test.
3. Reads `/api/games/active` back and prints the resulting rows, flagging any `NaN`/null skull.

It does **not** pick a tile, does **not** cash out, and does not touch any other player's game.
Cost if accepted: our own 0.001 ETH stake.

- **`400` / error body** → the server validates. **Path closed. Nothing to report.**
- **`200` + `preliminaryGameId`** → not validated. Read back the rows; `tiles: 0` with a
  `NaN`/null death tile confirms the arithmetic is reachable. **Then stop and report.**

## 6. Explicitly NOT claimed

- Not claimed that the server fails to validate. **Unknown.**
- Not claimed that any game has ever been played with an illegal `rowConfig`. **None found in
  450 sampled games.**
- Not claimed that funds are at risk today. **Unproven.**
- The other game modes (tiles 1–10, nested coordinate picks) are **not** analysed here; their
  algorithms are un-reversed and their fairness is untested.

## 7. Provenance

```
bundle        : 76 chunks, dpl_BArumTqywc9BCFDEfAm58dKGRGJ2
client create : chunks/3vf1zq2-0zz2k.js   (body: {betAmount, rowConfig: rows.map(e=>e.tiles)})
bound check   : chunks/33e3oiue0bp6x.js   (client-side toast only)
constants     : chunks/0yg8x3o7uh0c_.js   (MIN_TILES 2, MAX_TILES 7, TOTAL_ROWS 25, MAX_MULT 500)
privy app id  : cm6txbwad00ikeoi9wu5wmi8p (NEXT_PUBLIC_PRIVY_APP_ID, inlined client-side)
contract      : 0x27EDd16eE56958fddCBA08947f12C43DDeC2B20C  (api.mainnet.abs.xyz)
scripts       : provably-fair/scan_rowconfigs.mjs   (450-game on-chain bounds scan)
                disclosure/live-capture/rowconfig-probe.js  (the resolving test)
```

No mainnet state modified — every call was `eth_call`. No exploit was executed against the live
app. No funds were moved.
