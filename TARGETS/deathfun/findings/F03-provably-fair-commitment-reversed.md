# F03 — Provably-fair scheme reversed, then independently verified on-chain

**Target:** death.fun (DeathFun) — Abstract, chain ID 2741
**Date:** 2026-09-10
**Status:**
- ✅ **Scheme INDEPENDENTLY VERIFIED** — 706/706 real death_race games reconcile exactly (§2)
- ❌ Pre-reveal hypothesis **FALSIFIED** by live capture (§4)
- ✅ **CONFIRMED defect:** the published verifier reproduces **0/706** real games (§5)
- ⛔ **RETRACTED:** my earlier "143 games committed an empty board" claim — it was **wrong** (§3)

**Severity:** **No Critical. No fund-loss vector. No exploitable finding.**
One real defect (§5, a false fraud signal aimed at their own users) and one strong
positive result (§2).

> **Two retractions are recorded in this document rather than quietly deleted.** A critical
> pre-reveal claim (§4) and an outright misreading of 143 games (§3). Both were killed by
> looking harder, and the reasoning that produced them is kept because it is the useful part.
> **No funds were taken at any point in this research.**

---

## 1. The scheme, recovered

Source: the devs' own public verifier (`github.com/Death-fun/death-fun-provably-fair`) **plus the
production JS bundle**, which ships the server-side implementation to the browser.

```js
// 324sagnahlooz.js — the module the app imports as the "provably fair" toolkit
sha256Hex(s)               = createHash("sha256").update(s).digest("hex")
generateGameSeed()         = randomBytes(32).toString("hex")
getDeathTileIndex(s,i,n)   = parseInt(sha256(`${s}-row${i}`).slice(0,8),16) % n
createCommitmentHash(v,r,s)= "0x" + sha256(JSON.stringify({version:v, rows:r, seed:s}))

// 3ym39zg5cgmew.js — the row builder, and the constants module 0yg8x3o7uh0c_.js
q(x)                       = Math.round(1e8 * x) / 1e8
houseEdge                  = .04
DEATH_RACE_MIN_TILES       = 2      DEATH_RACE_MAX_TILES   = 7
DEATH_RACE_TOTAL_ROWS      = 25     DEATH_RACE_MAX_MULTIPLIER = 500
DEATH_RACE_MAX_BET_PERCENTAGE    = .01     (max bet = 1% of pot)
DEATH_RACE_MAX_PROFIT_PERCENTAGE = .05     (max profit = 5% of pot)

async function Y(counts, seed, edge = houseEdge) {
  let l = 1;
  return counts.map((d, i) => {
    const o = (l *= 1 / (1 - 1/d)) * (1 - edge);
    return { tiles: d, deathTileIndex: getDeathTileIndex(seed, i, d), multiplier: q(o) };
  });
}
```

The entire board is a pure function of the seed: `deathTileIndex(row i) = sha256(seed-row i) mod tiles_i`.
No player input, no bet size, no timestamp. Know the seed, know the board.

## 2. ✅ INDEPENDENT VERIFICATION — 706 real games, end to end

`provably-fair/verify_fairness.mjs`, exact JS semantics (`Math.round(1e8*e)/1e8`,
`JSON.stringify` key order), run against 898 settled games pulled from the contract.

```
standard 25-row death_race games                       : 706
committed hash reproduces (app's own constants)        : 706/706   100.0%
committed hash reproduces (THEIR published verifier)   :   0/706     0.0%
committed board == board actually played               : 706/706
every pick within its row's tile range                 : 706/706
fairness: wins consistent                              : 193
fairness: losses consistent                            : 513
fairness: CONTRADICTIONS                               : 0
```

The third test is the one that matters most and it is not a hash check: for each game the
player's actual picks are compared with the skulls recomputed from the revealed seed. A player who
"survived" a skull, or "died" on a safe tile, would be a contradiction. There are **none** across
706 games. Every loss (513) landed exactly on the death tile for that row; every win (193) avoided
it on every row played, including the last.

**Conclusion: for standard death_race games the commitment is honest, it binds the board actually
played, and the outcome is a deterministic function of the committed seed.** This is a clean bill
of health for the core mechanic, and it is the reason the rest of this document is credible.

## 3. ⛔ RETRACTED — "143 games committed an empty board"

**Withdrawn.** An earlier revision of this document claimed 143 real-money games had
`rowConfig: []` committed, so the on-chain hash covered `rows: []` and proved nothing. The
arithmetic was right and the conclusion was wrong: **those are not death_race games.**

What I actually had was one dataset containing **three different games**, and I fed all of it
through the death_race algorithm. The tell was in the data and I read past it:

```
population          n     shape of selectedTiles
standard (25 rows) 706    flat ints, max index 0..6        <- death_race (MAX_TILES=7)
empty config       143    107 NESTED ([[row,tile],...]) ; 36 flat, max index 10..12
odd length (4/10/20/12) 49  49 NESTED
```

A pick index of 9, 10, 11 or 12 is **impossible** in death_race — rows have at most 7 tiles, so
indices cap at 6. And every one of the 706 genuine games is within range (706/706). The other two
populations are different game modes.

Their own shared verifier says so in a comment:

```js
// upstream-verifier-shared.js:85
rows: gameState.rows || [], // Use 0 for games without rows (like dice)
```

`rows: []` is the **documented-correct** commitment format for a game that has no rows. For those
games the seed is still committed, and the outcome still derives from it. There is nothing wrong
with them, and **no claim is made about them** — I have not reverse-engineered the dice or plinko
algorithms, so their fairness is untested and out of scope here.

**What went wrong:** I classified nothing before analysing. `gameType` is not in the on-chain
`Game` struct, so the dataset looked homogeneous and I treated it as such. The lesson is on
`CHECKLIST.md`: *before analysing a population, prove the population is one thing — look for a
bimodal distribution in the inputs, and treat an out-of-range value as a classification signal
rather than noise.*

## 4. ❌ FALSIFIED — the pre-reveal path ("see the skull before clicking")

Tested live, 2026-09-10, via `console-probe.js` pasted into the real logged-in app.

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
`nextRow` — the one about to be played — is `null`, and the seed is absent while the game is live.
**The design holds.** The DOM-styling path documented in earlier revisions
(`l = a === e.deathTileIndex` → red styling independent of selection) is therefore **unreachable**:
there is no populated `deathTileIndex` for an unplayed row to style. Nothing to exploit.

Consequences, accepted plainly:
- The **100x flip has no premise.** There is no leak, so no guaranteed win, so nothing to
  demonstrate — and no reason to move player funds.
- `isDeathTile:false` means the player still trusts the server for the moment of truth *during*
  play; fairness is checkable *after* settlement against the on-chain commitment. That is the
  normal provably-fair trade-off, and §2 shows the commitment backs it.
- `version: 2` in the select-tile response confirms the v2 backend serves live play (bears on F02).

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

The app commits with `houseEdge = .04` **and** rounds to `1e8` before hashing. Both differences
change the hash. Single-game receipt, `gid=4838990`:

```
on-chain seedHash                    0xb04da23c01e2a9341fc1d7e56d4dc6e97f00e3ab5e3ad15fb2a9a3cd5e6dfc29
PUBLISHED VERIFIER he=0.05 raw       0x5ca3d6cf…  no match
PUBLISHED VERIFIER he=0.05 round 1e8 0x72656601…  no match
APP he=0.04 round(1e8)               0xb04da23c…  MATCH
```

Across every standard game: **0 / 706.** Not one real game verifies under the tool the project
publishes for players to verify games with. (It is also v1-only — `value="v1"`, "Always use v1
only" — and death_race-only, so the other game modes have no verifier at all.)

**Impact:** any player who follows the "provably fair — verify it yourself" flow gets a mismatch
on an **honest** game and is told, in effect, that the operator cheated. It is a false
fraud-signal generator pointed at the project's own users, and it destroys the evidentiary value
of the one mechanism meant to prove fairness. Fix is one constant plus the rounding function.

## 6. Methodology corrections (both proven, not asserted)

**a. My probe had a blind spot.** The first `console-probe.js` parsed only
`{currentGame}/{game}/{games[0]}`, so it never read the top-level `{currentRow, nextRow}` object
returned by `/select-tile` — a genuine `nextRow` leak would have been reported as clean. Fixed in
v2 and made testable: `probe-selftest.mjs` runs 6 fixtures (2 real captured payloads, 2 synthetic
leaks that must fire, 2 must-stay-quiet).

```
v1 (from git HEAD) against the same 6 fixtures:  5 passed, 1 FAILED
v2 (fixed)                                       6 passed, 0 failed
```

**b. I did not classify my population.** See §3 — three game modes in one dataset, analysed as
one. The out-of-range pick indices were visible the whole time.

**c. Python and JS disagree on float formatting for 55 of these 706 games** (Python
`round(o*1e8)/1e8` + `json.dumps` vs JS `Math.round` + `JSON.stringify` — different half-rounding
and float-to-string). An early Python pass reported "651/706 reproduce" and "55 board mismatches";
both were my language mismatch, not the chain. **All authoritative numbers in this document come
from Node with exact JS semantics.** Any hash-reproduction claim about a JS codebase must be
computed in JS.

## 7. What to tell the team

> We reproduced your commitment scheme independently and verified it end to end: **706 of 706**
> standard death_race games reconcile byte-for-byte, the committed board is identical to the board
> played, and every one of your players' picks lines up exactly with the skulls recomputed from the
> revealed seed — **zero contradictions**. Your core mechanic is sound and we're saying so up front.
>
> One real problem: **your published verifier can't verify any of your games.** It uses
> `HOUSE_EDGE = 0.05` and hashes unrounded floats; your app commits with `0.04` and rounds to `1e8`.
> We tested all 706 standard games — **zero** verify with the published tool, all of them verify once
> the constants match. Any player who uses it gets a false mismatch and may read it as fraud.
> Please fix it, and consider publishing verifiers for your other game modes too.
>
> We also chased a pre-reveal angle and it's clean — your API withholds the seed and keeps
> `nextRow.deathTileIndex` null while a game is live. Retracted. And an earlier note from us
> suggesting games with an empty committed board were unverifiable was our error — those are your
> non-row games, where `rows: []` is correct. Withdrawn.
>
> No funds were taken at any point in this research.

## 8. Provenance

```
verifier repo : github.com/Death-fun/death-fun-provably-fair  (games/deathFun/deathFun.js, shared.js)
bundle        : 76 chunks, deployment dpl_BArumTqywc9BCFDEfAm58dKGRGJ2
                gameplay chunk 3ym39zg5cgmew.js sha256 8f0197141eea0eaa9d7a7a9636638974faa3cf88cf3f673a2b1ddbbf779389dd
                  -> byte-identical to the previous deployment dpl_EL8LodHS2wjxZShsP7vH6U1XJhs2
                     (content-addressed chunk => the deploy ID change was server-side, not gameplay)
                algorithm  -> chunks/324sagnahlooz.js      constants -> chunks/0yg8x3o7uh0c_.js
                row builder-> chunks/3ym39zg5cgmew.js, 2qzosnxwl7652.js
                mapper     -> chunks/3vf1zq2-0zz2k.js  (eM)
contract      : 0x27EDd16eE56958fddCBA08947f12C43DDeC2B20C  (api.mainnet.abs.xyz)
on-chain      : 898 settled games; games(uint256) decoded directly (no explorer dependency)
scripts       : provably-fair/verify_all_games.mjs   (candidate sweep: 706/0)
                provably-fair/verify_fairness.mjs    (706/706 hash + 0-contradiction fairness test)
                disclosure/live-capture/console-probe.js (v2) + probe-selftest.mjs (6 fixtures)
```

No mainnet state modified — every call was `eth_call`/`eth_getLogs`. No exploit was executed
against the live app, and no funds were moved.
