# F03 — Provably-fair scheme reversed, then live-verified

**Target:** death.fun (DeathFun) — Abstract, chain ID 2741
**Date:** 2026-09-10 (live capture) / algorithm work 2026-09-09
**Status:** Algorithm **fully recovered and validated on-chain** (706/706 standard games
byte-exact). Pre-reveal hypothesis **FALSIFIED by live capture** — see §4.
Two gaps **CONFIRMED independently**: §3 (games committed with no board) and §5 (the
published verifier cannot verify any real game).
**Severity:** **No Critical. No fund-loss vector.** §3 and §5 are integrity/reporting
defects, not exploitable ones.

> **Headline correction.** Earlier revisions of this document carried a *Critical if confirmed*
> pre-reveal hypothesis ("see the skull before clicking"). It was tested live on 2026-09-10 and
> **it does not hold** — the server withholds the seed and every unplayed row's skull. It is
> retracted here in place, not deleted, because the reasoning that produced it is instructive
> (§6). No funds were taken at any point in this research.

---

## 1. The whole scheme, recovered

Source: the devs' own public verifier (`github.com/Death-fun/death-fun-provably-fair`) **plus the
production JS bundle**, which ships the server-side implementation to the browser.

```js
// 324sagnahlooz.js — the module the app imports as the "provably fair" toolkit
sha256Hex(s)               = createHash("sha256").update(s).digest("hex")
generateGameSeed()         = randomBytes(32).toString("hex")
getDeathTileIndex(s,i,n)   = parseInt(sha256(`${s}-row${i}`).slice(0,8),16) % n
createCommitmentHash(v,r,s)= "0x" + sha256(JSON.stringify({version:v, rows:r, seed:s}))

// 3ym39zg5cgmew.js — the row builder
q(x)                       = Math.round(1e8 * x) / 1e8
appConfig.houseEdge        = .04                     // found in the app config blob

async function Y(counts, seed, edge = houseEdge) {
  let l = 1;
  return counts.map((d, i) => {
    const o = (l *= 1 / (1 - 1/d)) * (1 - edge);
    return { tiles: d, deathTileIndex: getDeathTileIndex(seed, i, d), multiplier: q(o) };
  });
}
```

### The consequence that matters

> **The entire board — every skull position, in every row — is a pure function of the seed alone.**

```js
deathTileIndex(row i) = parseInt(sha256("<seed>-row<i>").slice(0,8),16) % tiles_in_row_i
```

Nothing else feeds into it. No player input, no bet size, no timestamp. **Know the seed, know the
board.** That is by design — it is what makes the game verifiable. It also means the seed's secrecy
*is* the game's fairness, which is why the live check in §4 mattered enough to run.

## 2. Validation against production data

`provably-fair/verify_all_games.mjs` — replays all 898 settled games from
`settled-games-sample.json` through each candidate algorithm in exact JS semantics
(`Math.round(1e8*e)/1e8`, `JSON.stringify` key order) and compares to the on-chain
`gameSeedHash`.

```
games=898  usable=755  emptyRowConfig=143

  he=0.04 prec=1e8   order=tiles,deathTileIndex,multiplier   706/755  93.5%   ← the shipped builder
  he=0.04 prec=1e8   order=tiles,multiplier,deathTileIndex     0/755   0.0%
  he=0.04 prec=1e4   order=tiles,deathTileIndex,multiplier   339/755  44.9%
  he=0.04 prec=null  (any order)                               0/755   0.0%
  he=0.05 prec=1e8   (any order)  ← THE PUBLISHED VERIFIER      0/755   0.0%
  he=0.05 prec=null  (any order)  ← THE PUBLISHED VERIFIER      0/755   0.0%
```

**706 / 706 of the standard 25-row games reproduce byte-exact.** Not a sample — every standard
game in the set. The commitment mechanism is real and self-consistent.

**49 games do not reproduce**, and they are *not* a bug: they are a structurally different game
mode. Their `rowConfig` lengths are 4/10/12/20 and their `selectedTiles` are **coordinate pairs**
(`[[1,0],[1,0]]`), not ladder indices:

```
gid=4838991  rowConfig=[2,2,1,1]  selectedTiles=[[1,0],[1,0]]  status=Won
gid=4838988  rowConfig=[2,2,1,1]  selectedTiles=[[0,1],[0,0]]  status=Won
```

> **Superseded:** an earlier revision suggested these were 1-tile rows handled by a third builder
> `J`. That was wrong. They are a different game mode; the death-race ladder algorithm simply does
> not apply, so **they are not a finding and nothing is claimed about them.**

## 3. ✅ CONFIRMED — 143 real-money games whose commitment contains **no board at all**

For 143 settled games the on-chain commitment reproduces with `rows: []`:

```
gameSeedHash == "0x" + sha256(JSON.stringify({version:"v1", rows:[], seed:"0x..."}))
```

Verified **byte-exact for all 143** (every one, not a sample). Yet all 143 were played to
completion and settled:

```
game 4838969  Won   bet 0.001  payout 0.0035132   selectedTiles [9,5,6,7,8,10,11]
Won 36 / Lost 107 ; win multiples 1.0165x .. 4.3612x ; picks 1..9
```

**Reading:** for these games the on-chain "provably fair" commitment contains zero information
about the outcome. Nothing binds the server to any particular board. A player verifying one of
these games gets a hash that matches **and an empty board** — a green tick that proves nothing.

**Honest scoping — this is a code path, not a proven cheat:**
- The 898-game sample is **bot-heavy**: 25 unique players, 0.73-day span, one address with 365
  games and another with 201.
- The 143 empty-config games come from **10 unique addresses**, dominated by one (87 games).
- So the realistic reading is *"a client/API path exists that commits an empty board, and games
  played through it were settled for real money,"* **not** *"players are being cheated."* What is
  provable is narrower and still worth reporting: **the commitment did not cover those outcomes,
  and the game can be played in that state.**

## 4. ❌ FALSIFIED — the pre-reveal path ("see the skull before clicking")

**Tested live, 2026-09-10, via `console-probe.js` pasted into the real logged-in app.** The
question was one field wide:

> For an **active** game, does any API response populate `gameSeed` — or `rows[].deathTileIndex` —
> before the player picks?

**Answer: no.** Raw captured responses:

```jsonc
// GET /api/games/active?gameType=death_race        <- while a game was live
{"currentGame":{"id":"145794c1-…","status":"active","betAmount":"1000000000000000",
  "usdUnitPrice":2437.24,
  "rows":[{"tiles":7,"multiplier":1.12,"deathTileIndex":null},
          {"tiles":3,"multiplier":1.68,"deathTileIndex":null}, … 25 rows, every one null]}}
// no gameSeed, no commitmentHash, all 25 deathTileIndex null

// POST /api/games/145794c1-…/select-tile            <- immediately after one pick
{"isDeathTile":false,"currentRowIndex":1,"finalMultiplier":1.12,"status":"active",
 "currentRow":{"tiles":7,"multiplier":1.12,"deathTileIndex":5},   // row JUST played
 "nextRow":{"tiles":3,"multiplier":1.68,"deathTileIndex":null},   // row NOT yet played
 "version":2,"animationTag":null}
```

The server reveals the skull of the row **you have already survived**, and only that row.
`nextRow` — the one about to be played — is `null`. The seed is absent while the game is live.
**The design holds.** The board cannot be computed ahead of the pick, so the DOM-styling path
documented in earlier revisions (`l = a === e.deathTileIndex` → red styling independent of
selection) is **unreachable**: there is no populated `deathTileIndex` for an unplayed row to
style. Nothing to exploit.

Consequences, accepted plainly:
- The **100x flip is off the table.** The premise was a guaranteed win from a pre-reveal leak.
  There is no leak, so there is no guaranteed win, so there is nothing to demonstrate — and
  therefore no reason to move player funds.
- The `isDeathTile:false` field means the player still **trusts the server** for the moment of
  truth during play; fairness is only *checkable* after settlement, against the on-chain
  commitment. That is a normal provably-fair trade-off, and §2 shows the commitment backs it for
  standard games.
- `version: 2` in the select-tile response confirms the v2 backend is what is serving live play
  (relevant to F02).

## 5. ✅ CONFIRMED — the published verifier cannot verify any real game

The devs' own verifier hard-codes `HOUSE_EDGE = 0.05` and hashes **raw unrounded floats**:

```js
// upstream-verifier-deathFun.js:47-59
calculateRowMultipliers(tileCounts) {
  const HOUSE_EDGE = 0.05;                                    // ⊥ the shipped app uses .04
  … const multiplierWithEdge = currentMultiplier * (1 - HOUSE_EDGE);
}
reconstructRows() { … rows.push({ tiles, deathTileIndex, multiplier }); }   // no q() rounding
```

The shipped app uses `houseEdge = .04` **and** rounds to `1e8` before hashing. Both differences
change the hash, so the verifier recomputes a *different* `rows[]` and therefore a different
`gameSeedHash`. Single-game receipt, `gid=4838990`:

```
on-chain seedHash     0xb04da23c01e2a9341fc1d7e56d4dc6e97f00e3ab5e3ad15fb2a9a3cd5e6dfc29
PUBLISHED VERIFIER he=0.05 raw      0x5ca3d6cf…  no match
PUBLISHED VERIFIER he=0.05 round 1e8 0x72656601…  no match
APP he=0.04 round(1e8)              0xb04da23c…  MATCH
```

Across the whole set: **0 / 755.** Not one real game verifies under the tool the project
publishes for players to verify games with. The verifier is also v1-only (`value="v1"`,
"Always use v1 only").

**Impact:** any player who follows the "provably fair — verify it yourself" flow gets a mismatch
on an **honest** game and is told, in effect, that the operator cheated. It is a false
fraud-signal generator pointed at the project's own users, and it destroys the evidentiary value
of the one mechanism meant to prove fairness. Fix is one constant plus the rounding function.

## 6. Methodology correction — my probe had a blind spot, proven not asserted

The first `console-probe.js` reported "no active-game response carried the seed or death tiles"
— which was right — but it was right **by accident for the shape that mattered**. Its parser only
read `currentGame` / `game` / `games[0]`, so it never looked inside the top-level `currentRow` /
`nextRow` object returned by `/select-tile`. A genuine leak in `nextRow` would have been reported
as clean.

Fixed in v2 and made testable: `probe-selftest.mjs` runs the snippet against 6 fixtures — the two
**real captured payloads** plus two **synthetic leaks** that exist to prove the probe would fire,
and two must-stay-quiet cases.

```
v1 (from git HEAD)  against the same 6 fixtures:  5 passed, 1 FAILED   ← missed the nextRow leak
v2 (fixed)                                         6 passed, 0 failed
```

The lesson is on `CHECKLIST.md`: **a detector that has never been shown to fire is not evidence of
absence.** Both real fixtures are kept in the test file so the negative result stays reproducible.

## 7. What to tell the team

> We reproduced your commitment scheme exactly — 706 of 706 standard games verify byte-for-byte,
> and we're reporting that alongside the two problems, because the scheme itself is sound.
>
> 1. **Your published verifier can't verify any real game.** It uses `HOUSE_EDGE = 0.05` and hashes
>    unrounded floats; your app commits with `0.04` and rounds to `1e8`. We tested all 755 standard
>    games: zero verify with the published tool, all of them verify once the constants match. Any
>    player who uses it gets a false mismatch — please fix it before it's read as fraud.
> 2. **143 settled games committed an empty board** (`rowConfig: []` → `rows: []`). The hash
>    verifies but proves nothing, so those outcomes were never fixed in advance. It looks like a
>    client/API path rather than the web flow, but the games settled for real money in that state.
> 3. **We also chased a pre-reveal angle and it's clean** — your API withholds the seed and keeps
>    `nextRow.deathTileIndex` null while a game is live. We've retracted that hypothesis. No funds
>    were taken at any point in this research.

## 8. Provenance

```
verifier repo : github.com/Death-fun/death-fun-provably-fair  (games/deathFun/deathFun.js, shared.js)
bundle        : 76 chunks, deployment dpl_BArumTqywc9BCFDEfAm58dKGRGJ2
                gameplay chunk 3ym39zg5cgmew.js sha256 8f0197141eea0eaa9d7a7a9636638974faa3cf88cf3f673a2b1ddbbf779389dd
                  -> byte-identical to the previous deployment dpl_EL8LodHS2wjxZShsP7vH6U1XJhs2
                     (content-addressed chunk => the deploy ID change was server-side, not gameplay)
                algorithm  -> chunks/324sagnahlooz.js
                row builder-> chunks/3ym39zg5cgmew.js, 2qzosnxwl7652.js
                mapper     -> chunks/3vf1zq2-0zz2k.js  (eM)
on-chain      : 898 settled games, gameSeed revealed, gameSeedHash public
scripts       : provably-fair/verify_all_games.mjs          (the 706/0/143 result)
                disclosure/live-capture/console-probe.js    (v2, blind spot fixed)
                disclosure/live-capture/probe-selftest.mjs  (6 fixtures, 2 real + 2 synthetic leaks)
```

No mainnet state modified — every call was `eth_call`/`eth_getLogs`. No exploit was executed
against the live app, and no funds were moved.
