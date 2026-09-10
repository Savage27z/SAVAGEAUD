# Live game-mode surface (probed 2026-09-10, $0 spent)

## Method

`gameType` is a **query parameter** on `POST /api/abstract/games/create?gameType=…`,
not a body field (body is the superjson `{betAmount, rowConfig}`). Source:

```js
let r = new URLSearchParams({gameType: e});
let a = CURRENT_APP === DEATH_FUN_APP ? "/api/abstract/games/create" : "/api/games/create";
fetch(`${a}?${r.toString()}`, {method:"POST", ..., body: superjson.stringify({betAmount, rowConfig})})
```

### Free enum oracle (reusable trick)

To learn whether a value is a valid game type **without creating a game or spending anything**:
send it with `betAmount = 1` (below the 0.001 ETH minimum).

- valid type    → `400` with `betAmount: ["Bet is below the minimum allowed bet of 0.001 ETH."]`
  (schema passed, fell through to the *next* validator)
- valid-but-off → `403 gameType '<x>' is not available`
- invalid       → `400 gameType is required` (enum rejected outright)

The distinguishing signal is **which field the error lands on**. An error on a *later*
field proves the earlier field passed. This generalises: to test any enum, make the next
validator in the chain fail and see where the error surfaces.

## Result — 13 declared game types

**LIVE (3):**

| gameType | result |
|---|---|
| `death_race` | accepted → 400 bet-below-minimum |
| `laser_party` | accepted → 400 bet-below-minimum |
| `dice` | accepted → 400 bet-below-minimum |

**DISABLED (10):** `plinko`, `blackjack`, `blackjack_multihand`, `stuntguy`, `spinner`,
`pack_rip`, `basejump`, `brofun`, `smasher`, `hoopmadness`
— all `403 {"error":"gameType '<x>' is not available"}`

## Why this matters

The earlier "12 unreversed game modes" figure **overstated the remaining surface**.
Ten of those thirteen are switched off server-side and cannot be played, so they cannot
be reached, tested, or exploited by anyone — including us. The real remaining surface is
**one mode: `dice`**.

## Status of each live mode

| mode | board | skull/RNG formula | verdict |
|---|---|---|---|
| `death_race` | 25 rows, committed on-chain | reversed; 706/706 reproducible | sound (9 attacks, all negative) |
| `laser_party` | `rows: []` (no on-chain board) | skulls seed-derived, 20/20 verified | **losses never settle** (Low–Med) |
| `dice` | `rows: []` | **not yet reversed** | open |

## Dice: why it is not a "big model" problem

Dice has no board and therefore no `deathTileIndex`. Whatever the outcome is, it must be
derived from the committed `seed` — the same construction as the death-race skull:

```
skull_i = parseInt(sha256Hex(`${seed}-row${i}`).slice(0,8), 16) % tiles_i
```

That is hash-then-modulo arithmetic. Reversing it needs **data (settled dice games with
their seeds and outcomes)**, not more model capability. Capability is not the binding
constraint anywhere in this investigation — reachability is.

### Blocker

`settled-games-sample.json` (898 games) contains **no dice games**. Its `gameConfig` is
only ever `{rowConfig: …}`, and the 143 no-rows games are all nested-progressive-pick
shapes (`[[9,5,6,7,8,10,11],[…]]`) — i.e. laser_party family, not dice. Dice is live but
unsampled; on-chain `gameConfig` never records the game type, so dice games cannot be
identified retrospectively from the contract alone.

Options to obtain dice data:
1. Play one dice game (0.001 ETH) while capturing `/api/select-tile` responses. Pays for itself if the roll can be predicted.
2. Pull a larger sample from chain and identify dice by shape (no cost, but weak — the type is off-chain).
3. Ask the team (the disclosure is going out anyway).
