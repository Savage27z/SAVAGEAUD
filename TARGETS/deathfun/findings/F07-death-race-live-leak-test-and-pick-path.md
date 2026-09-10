# F07 — death_race: live-game leak test, pick-path validation audit, version guard

Date: 2026-09-10. Contract `0x27EDd16eE56958fddCBA08947f12C43DDEc2B20C` (Abstract 2741).
Method: one live death_race game, created with the funded test wallet, played and cashed out.
**Spend: −0.00101136 ETH to create, +0.00192 ETH on cash-out → net +0.0009 ETH. Funds were not burned.**

## 1. Pre-reveal leak — CLOSED, on a live game

Hypothesis (the long-running one): the board can be read before picking, so death_race is a guaranteed win.

Live game `1a06e1a5-6583-4737-b681-53c961ba3769` (gid 4839273), `rowConfig [2]×25`.

**Full response dump, `GET /api/games/active?gameType=death_race`, before any pick:**

```
currentGame.currentRowIndex = 0
currentGame.version        = 1
currentGame.gameSeed       = null
currentGame.status         = "active"
currentGame.rows           = [ {tiles:2, multiplier:1.92,  deathTileIndex: null},
                               {tiles:2, multiplier:3.84,  deathTileIndex: null},
                               … all 25 rows, deathTileIndex null … ]
→ non-null deathTileIndex anywhere in the payload: NONE
```

**After one pick** (tile 0 → survived; response revealed `currentRow.deathTileIndex = 1`, `nextRow.deathTileIndex = null`):

```
GET /api/games/active?gameType=death_race
  rows[0].deathTileIndex = 1      ← the row JUST PLAYED
  rows[1..24].deathTileIndex = null
→ non-null deathTileIndex: [(0, 1)] — the completed row only
```

So the server scrubs correctly: **a row's skull is revealed only after that row is played.** The row about
to be played is always `null`. The `previousGame` object carries the finished game's seed and skulls — by
design.

**Verdict: no pre-reveal leak. death_race cannot be won by inspection.** This is now confirmed on a live
game with a full payload dump, not just from captured app traffic.

## 2. Pick-path validation audit (the F04 method, pointed at `select-tile`)

`POST /api/games/{uuid}/select-tile`, body `{game_type, tileIndex, version}`.

| attack | result | verdict |
|---|---|---|
| `tileIndex: 1.5` / `0.5` | `400 "expected int, received number"` | schema uses `z.int()` — closed |
| `tileIndex: 1e400` | `400 "expected number, received number"` | closed |
| `tileIndex: -1` | `400 "Too small: expected number to be >=0"` | closed |
| `tileIndex: 2` on a 2-tile row | `400 "Invalid tile index"` | runtime bound check is correct (`< tiles`), not `<=` |
| `tileIndex: 999` | `400 "Invalid tile index"` | closed |
| `game_type` absent / bogus | `400 "Invalid input"` | enum enforced |
| `game_type: "laser_party"` on a death_race game | `400 "Game type mismatch"` | **server compares body type to the game's real type** — confusion closed |
| `game_type: "laser_party"` without `cell` | `400 "expected tuple, received undefined"` | schema is a discriminated union on `game_type` |
| extra field `cell` on a death_race pick | accepted (zod not `.strict()` here) | cosmetic |

**Note:** `tileIndex` has `int` + `min(0)` but **no upper bound in zod** — the max lives in game logic.
Same shape as the laser_party `cell` gap (F05 §2). Not exploitable: the logic check runs and is correct.

**Check order on `select-tile`: schema → game lookup → `tileIndex` bound → version.**
(The `tileIndex` bound fires for every version value, including `1e15`, proving it precedes the version check.)

## 3. `version` guard — what it actually is, and why it holds

`version` is a **small incrementing integer, 1 + number of actions taken**:

- fresh game → `version: 1`
- after 1 pick → `version: 2`
- the finished earlier game with 1 pick → stored `version: 2` (found by brute force: `2` returns
  `"Game is not in a valid state for cashout"`, while `1` and `3` return `"Version mismatch"`)

It is **guessable** — which matters, because a "concurrency token" you can compute is not a secret. But it
is **enforced by exact equality**, so guessing it buys nothing. Tested on the live game while genuinely
active:

```
select-tile  version=3  (ahead)  → 404 "Game already updated"   , state UNCHANGED (row1, version=2)
cash-out     version=1  (stale)  → 409 "Version mismatch"
cash-out     version=3  (ahead)  → 409 "Version mismatch"
cash-out     version=25 (far)    → 409 "Version mismatch"
```

**Row-skipping via `version` is closed.** A client cannot advance to a row it has not reached, and cannot
replay a stale state. The payout is computed server-side from the game's real row — confirmed by the
cash-out below returning the correct multiplier for the actual position, not for the requested version.

### `cash-out` is `.strict()`

```
POST /api/games/{uuid}/cash-out   body {game_type, multiplier} → 400 "Unrecognized keys: game_type, multiplier"
                                  body {version}              → accepted
                                  body {payoutAmount: ...}    → 400 "Unrecognized key"
```

Only `version` is accepted; `payoutAmount`/`multiplier` cannot be client-supplied. **The player cannot
name their own payout.** Closed.

## 4. death_race win path verified end-to-end

```
POST /api/games/1a06e1a5…/cash-out  {"version":2}
→ {"status":"won","finalMultiplier":1.92,
   "payoutAmount":"1920000000000000",
   "payoutTxSignature":"0x42d93159894f3ca012805cf737fb6255bab768f920605dbe1a8674df6c0421fa"}
```

`0.00192 ETH` on a `0.001 ETH` bet = exactly the row-1 multiplier. Wallet `0.00331755 → 0.00421856 ETH`.

Settled record re-verified after the fact:

```
skulls reproduced from the revealed seed : 25/25
commitment verifies (sha256 of {version, rows, seed}) : True
row0 skull = 1, we picked 0 and survived  : consistent
```

## 5. All historical games: 10/10 boards and 10/10 commitments

Across the 10 games in `/api/games/history` (mixed death_race and laser_party, 2/3/4/7/10-tile rows):

- **skull formula reproduces every board: 10/10**
- **commitment verifies: 10/10** — but the row key order is **per game mode**:

```
death_race :  {"version","rows":[{tiles, deathTileIndex, multiplier}],"seed"}
laser_party:  {"version","rows":[{tiles, dimension, deathTileIndex, multiplier}],"seed"}
```

Getting the key order wrong makes the hash mismatch — this cost me a false "commitment MISMATCH" on the two
laser_party games before I brute-forced the correct key order. Recorded here so nobody repeats it:
**verify the mode's row shape, then hash.** The house edge is `0.04` in both modes (`0.05` in their own
published verifier is the bug, F03).

## 6. NEW (minor): the create response's `hash` is not the commitment

```
POST /api/abstract/games/create?gameType=death_race
→ {"preliminaryGameId":"1a06e1a5-…","hash":"0xbfed306807d95f94f876afe09ffd3a5fb13c3e01135c304aed5945f801326512"}

on-chain games(4839273).gameSeedHash = 0x4a76da3ecf71de12b1d86f9bda3b4fd8f38a1854caa2542a37d0bcbc563f9929
API currentGame.commitmentHash      = 0x4a76da3e…  (same as chain)
```

The `hash` returned at creation is **not** the value committed on-chain, and **not** the value the verifier
uses. The verifier prefills `hash` from `commitmentHash`:

```js
getInitialValues: e => ({version:"v1", rows:…, seed:e.gameSeed??"", hash:e.commitmentHash??""})
```

I could **not** reproduce the create-time `hash` from any shape I tried (request fields, `uuid`, `betAmount`,
`rowConfig`, wallet, or the revealed seed with empty/`[]` rows). So I can state what it is *not* — it is not
the commitment and it is not used for verification — but **not what it is.** Honest status: unexplained.

**Impact: low, and NOT a fairness break.** The commitment that matters (on-chain `gameSeedHash`) is correct
and verifies 10/10. The concern is presentational: a player who records the `hash` shown at creation as
"the commitment" will find it does not verify and has no way to know why. Worth one question to the team.

Also observed: games carry `releaseVersion: "v2"`. Unexplored.

## 7. Verdict for death_race

Every attack on the pick path now fails, and the failure modes are specific rather than vague:

- no pre-reveal leak (live-game dump, both before and after a pick)
- no non-integer or out-of-range tile to slip past the skull check (`z.int()` + correct bound)
- no game-type confusion (`Game type mismatch`)
- no version replay, no version row-skip (exact equality on both routes)
- no client-named payout (strict schema; server computes from its own row)
- board and commitment both verify 10/10

The game is honest. The defects worth reporting remain the ones already filed: `increaseBet`
(unreachable), laser_party losses never settling, the verifier's wrong house-edge constant, and the
owner==signer single-hot-EOA trust root.
