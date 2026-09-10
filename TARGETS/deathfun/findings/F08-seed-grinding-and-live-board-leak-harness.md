# F08 — "Can we script a game we already know the board of?" — negative, with harness

Date: 2026-09-10. Follows F07. Question posed: can a script create a game and force/manipulate it into
a state where all tiles and skulls are known in advance?

Short answer: **no — but the two mechanisms worth testing both got tested properly, and the tooling to
catch a leak if one ever appears is now in the repo.**

Artifact: `disclosure/live-capture/live-board-leak-scanner.py` (plays a real game and scans every read
path at every turn for a live-board leak).

## Idea 1 — is the seed derivable from the creation timestamp?

The API returns `createdAt` with **microsecond** precision (`2026-09-10 17:39:28.550675+00`). If the server
seeded its RNG from wall-clock time, that precision would make the seed reconstructible — and then the board
would be computable before the first pick.

Built the dataset of 10 games where I have both the revealed seed and the microsecond `createdAt`, then
swept:

```
formats   : epoch seconds, milliseconds, microseconds, ms-float, ISO string
prefixes  : "", "DeathFun", "deathfun", "seed", "0x"       suffixes: "", "-seed", "-game", "0x"
hashes    : sha256, keccak256
appended  : "", uuid, gid, betAmount
offsets   : ±3000 ms sweep against the millisecond timestamp
=> 68,010 candidates tested, HITS: 0
```

The seed is not a function of the creation time. Combined with F06 (3,047 candidates over 277 uuid/gid/
player/bet/seedHash derivations → 0 hits), the seed is server-side randomness with no client-observable
input. There is nothing to grind.

## Idea 2 — make the live game readable by making it "not the current game"

The sharper version: every read path that DOES reveal a full board (with seed and skulls) is a path that
serves a **finished** game. So can an attacker make their *live* game look finished to one of those paths?

Tested directly on a genuinely live game ([7]×25, created for the test):

```
GET /api/games/history WHILE THE GAME IS ACTIVE
   record present : True
   status         : "active"
   gameSeed       : None
   skulls         : NONE
   selectedTiles  : null
```

**`/api/games/history` does filter by status.** It lists the in-progress game but withholds the seed and
nulls every `deathTileIndex`. Cancelling the game (so it becomes "previous") is not possible — there is no
abandon/refund/forfeit route (`/refund`, `/abandon`, `/forfeit`, `/cancel` all 404).

Then this, at every turn of a real playthrough:

```
[pre-pick]  status='active' rowIdx=0 ver=1 | active skulls=none seed=None | history skulls=none seed=None
[after row0]            rowIdx=1 ver=2 | active skulls=[0]  seed=None | history skulls=[0]  seed=None
[after row1]            rowIdx=2 ver=3 | active skulls=[0,1] seed=None | history skulls=[0,1] seed=None
=> leaks: NONE across every read path at every turn
```

Only already-played rows ever appear. **No mechanism found to read a board you have not played.**

## The false positive (worth recording)

Running the scanner against an already-**settled** game reported `SEED EXPOSED` + `UNPLAYED ROW REVEALED`
with all 25 skulls populated. That looked like a Critical for about ninety seconds. It is not:

```
currentGame.status = "won"
```

`currentGame` is the **most recent** game, not necessarily a live one. After settlement it is the
just-finished game, and revealing its seed and skulls is correct and intended. The leak detector must
**gate on `status == "active"`** — without that gate, every settled game reads as a leak.

This is exactly the class of error that produces a bogus Critical, so it is baked into the tool and recorded
in CHECKLIST. (Second such self-inflicted false positive this session, after the laser_party commitment
key-order issue in F07 §5.)

## Still open — one structural test not yet run

**Does creating a *second* game while one is active make the first one appear as `previousGame` with its
seed, while it is still playable?** A leak of that shape would be real.

Not tested because it needs two live games simultaneously (0.002 ETH) and the account is nearly out of
funds. The scanner is already wired to catch it — run it while a second game exists and read the
`previousGame` fields.

Related observation from the same session: `previousGame` was observed serving a *finished* game's seed
(`status: won`), and `currentGame` kept serving the last settled game with a full board. Both are correct
for finished games; the question is only whether an **unfinished** game can occupy either slot in revealed
form.

## Reconciliation

My games only (the account also shows five games at 17:45–18:04 that I did not create — user's own play,
four lost and one won at 1.2×):

```
1a06e1a5 [2]x25  -0.001011   cash out 1.92x       +0.001920
220b7a2d [7]x25  -0.001011   cash out 1.3067x     +0.0013067
                 ----------                      ----------
net on my testing: +0.0012 ETH
```

Wallet after all testing: `0.00263248 ETH`. No funds were burned by this work; the balance went **up**.
