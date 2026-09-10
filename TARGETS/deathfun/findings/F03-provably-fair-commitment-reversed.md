# F03 — The provably-fair commitment, fully reversed (and the pre-reveal question it opens)

**Target:** death.fun (DeathFun) — Abstract, chain ID 2741
**Date:** 2026-09-10
**Status:** ✅ Algorithm **fully recovered and validated on-chain** (849/898 games reproduce
byte-exact). ⚠️ Pre-reveal hypothesis **open** — one live check away.
**Severity:** **Critical if confirmed** (player sees skulls before picking → guaranteed win).
The commitment-coverage gap below is confirmed independently and is serious on its own.

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
board.** That is by design (it is what makes the game verifiable), but it means the seed's secrecy
*is* the game's fairness.

## 2. Validation: 849 / 898 real games reproduce byte-exact

| Builder | houseEdge | Reproduced | Failed |
|---|---|---|---|
| **Y (as shipped)** | **.04** | **849** | 49 |
| Y | .05 | 143 | 755 |
| Y | .045 | 143 | 755 |

The edge value is the discriminator, and `.04` is the one in their own config. 849/898 games'
on-chain `gameSeedHash` are reproduced exactly from `(seed, rowConfig)` using the algorithm above.
**The scheme is not a guess — it is confirmed against production data at scale.**

**49 games do not reproduce**, and they are exactly the configs of length 4, 10, 12 and 20
(27 + 11 + 1 + 10) — i.e. the configs containing a `1`-tile row. The bundle has a *second* builder
for that case:

```js
async function J(counts, seed, edge = houseEdge) {
  let l = 1;
  return counts.map((d, i) => {
    if (d > 1) l *= 1 / (1 - 1/d);
    const o = l * (1 - edge);
    return { tiles: d, deathTileIndex: d === 1 ? 0 : getDeathTileIndex(seed, i, d),
             multiplier: d === 1 ? null : q(o) };
  });
}
```

Neither `Y` nor `J` matches those 49, so a third path handles 1-tile rows. Not itself a finding —
recorded so the next person does not re-derive it.

## 3. ✅ CONFIRMED: 143 real-money games whose commitment contains **no board at all**

For 143 settled games, the on-chain commitment reproduces with `rows: []`:

```
gameSeedHash == "0x" + sha256(JSON.stringify({version:"v1", rows:[], seed:"0x..."}))
```

Verified **byte-exact for all 143** (not a sample — every one). Yet those games were played and
paid:

```
game 4838969  Won   bet 0.001  payout 0.0035132   gameState {"selectedTiles":[9,5,6,7,8,10,11]}
game 4838965  Lost  bet 0.001  payout 0
   gameConfig = {"rowConfig":[]}        ← and the committed rows are [] too
   Won 36 / Lost 107 ; win multiples 1.0165x .. 4.3612x ; picks 1..9
```

**Reading:** for these games the on-chain "provably fair" commitment contains zero information
about the outcome. Nothing binds the server to any particular board. A player verifying one of
these games would receive a hash that matches and an **empty board** — a green tick that proves
nothing. Whatever game mode this is (the bundle carries at least three game types:
`DEATH_RACE`, `BASE_JUMP`, `SMASHER_FUN`, and only death_race uses `rowConfig`), the commitment
scheme does not cover it.

This is independent of §4 and stands on its own: **the outcome of 143 real-money games was never
committed in advance.** Whether the skulls were in fact chosen afterwards is unknowable *precisely
because* nothing was committed — which is the problem.

## 4. ⚠️ The pre-reveal path — "see the skull before clicking"

Everything needed to see the board is **already in the player's browser**:

**a. The browser ships the seed generator, the skull function, and the commitment builder.**
`324sagnahlooz.js` exports `generateGameSeed`, `getDeathTileIndex`, `createCommitmentHash`,
`sha256Hex`. A player can compute any board from any seed, locally, with the site's own code.

**b. The live board component receives `rows[].deathTileIndex` and `gameSeed` in client state**
(`3ym39zg5cgmew.js`):

```js
let l = a === e.deathTileIndex,            // is this tile the death tile?
    d = l && i;
className: cn("...",
  l && !i && "border-destructive bg-destructive/60",   // ← death tile styled even when NOT selected
  d && "border-destructive bg-destructive/80"),
children: d ? "💀" : null
```

The class is applied on `l` (is-death) alone. **Selection is not required.** If that state is
populated while the game is live, the skull is readable straight off the DOM — no exploit needed,
just inspect element. The `💀` glyph is the only part gated behind selection.

**c. The API→state mapper passes the seed and rows straight through** (`3vf1zq2-0zz2k.js`):

```js
function eM(e) {
  if (!e) return;
  return { ..., rows: e.rows, currentRowIndex: e.currentRowIndex ?? -1,
           selectedTiles: e.selectedTiles,
           commitmentHash: e.commitmentHash, gameSeed: e.gameSeed, ... };
}
```

**No nulling.** There *is* a deliberate strip path in the codebase —
`Y(e) { return rows.map(r => ({...r, deathTileIndex: null, multiplier: ...})) }` — which proves the
developers knew to null the death tile when it should be hidden. `eM` does not use it.

**d. Client-side seed generation exists**, and in demo mode it is reachable:

```js
shuffleRows = useCallback(async e => {
  let t = generateGameSeed();                       // client-made seed
  let n = await Promise.all(rows.map(async (r,i) =>
      ({...r, deathTileIndex: await getDeathTileIndex(t, i, r.tiles), multiplier: ...})));
  ... setRows(n)                                    // client sets its own board
}, []);
```

In the real-mode hook this is stubbed (`shuffleRows: async () => false`), so it is **not** a live
exploit — recorded because it shows the client is fully capable of building its own board, and a
future wiring change would make it one.

### So the single open question is narrow and checkable

> For an **active** game, does any API response populate `gameSeed` — or `rows[].deathTileIndex` —
> before the player picks?

- **Yes** → Critical, immediately. The player reads the skull from the DOM, or computes the whole
  board offline from the seed with the site's own `getDeathTileIndex`.
- **No** (fields null/absent until settlement) → the design holds, and this closes clean.

Everything else in this document is already proven. This one field is the whole difference.

## 5. How to settle it

The `live-capture` harness (`disclosure/live-capture/`) already records every response body. The
specific check is one grep of the capture:

```
grep for "gameSeed" and "deathTileIndex" in responses while currentGame.status == "active"
```

`capture.js --connect --play` + `analyze.js` gives it; I will add `gameSeed`/`deathTileIndex` to
the analyzer's watch list (they are currently only covered by the generic 65-byte/selector
patterns, which would **not** catch a plaintext seed — a gap worth closing before the run).

## 6. What to tell the team (draft line)

> Your commitment scheme is fine and we've reproduced it exactly on 849 of your games. Two things:
> (1) 143 settled games commit to an empty board — the hash verifies but proves nothing, so their
> outcome was never fixed in advance; (2) your client receives `rows[].deathTileIndex` and
> `gameSeed` in the game state mapper, and the board styles the death tile even when it isn't
> selected — so if those fields are populated before the player picks, the skull is visible in the
> DOM. Please confirm which. If they're null until settlement, ignore (2).

## 7. Provenance

```
verifier repo : github.com/Death-fun/death-fun-provably-fair  (games/deathFun/deathFun.js, shared.js)
bundle        : 76 chunks, deployment dpl_EL8LodHS2wjxZShsP7vH6U1XJhs2
                algorithm  -> chunks/324sagnahlooz.js
                row builder-> chunks/3ym39zg5cgwew.js, 2qzosnxwl7652.js
                mapper     -> chunks/3vf1zq2-0zz2k.js  (eM)
                board      -> chunks/3ym39zg5cgwew.js, 243hitda8tys5.js
on-chain      : 898 settled games, gameSeed revealed, gameSeedHash public
scripts       : /tmp/prereveal_step1b.js .. step8.js  (to be moved into the target dir)
```

No mainnet state modified — every call was `eth_call`/`eth_getLogs`. No exploit was executed
against the live app.
