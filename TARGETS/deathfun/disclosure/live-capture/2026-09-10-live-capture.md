# Live capture — 2026-09-10 — F03 pre-reveal check (verdict: NO LEAK)

**Method:** `console-probe.js` (v1 at the time) pasted into DevTools on the real, logged-in
death.fun app; one game started at the minimum stake; exactly one tile picked; `__df_dump()`.
Nothing was sent anywhere — the probe only stores data in the page.

**Result:** 2 relevant responses. Neither carried the seed on a live game, and no unplayed row's
skull was revealed. Hypothesis falsified.

**Context of the session:** the app was served by deployment `dpl_BArumTqywc9BCFDEfAm58dKGRGJ2`
(newer than the `dpl_EL8LodHS2wjxZShsP7vH6U1XJhs2` used for earlier recon — see the gameplay-chunk
hash check in `findings/F03-…md` §8; the gameplay code was byte-identical).

---

## Raw output as returned

```
===== DF CAPTURE: 2 relevant responses =====

--- /api/games/active?gameType=death_race
    status="active"  hasSeed=false  seed=null
    rows=25  deathTiles=[null,null,null,null,null,null,null,null,null,null,null,null,null,
                         null,null,null,null,null,null,null,null,null,null,null,null]
    populatedDeathTile=false
    raw: {"currentGame":{"id":"145794c1-e83e-4258-a8d9-b5ea184f2f08",
          "walletAddress":"0x318f5353bab917b5243d78825875a247c90c8646",
          "createdAt":"2026-09-10 16:22:14.300264+00",
          "updatedAt":"2026-09-10 16:22:16.701943+00","status":"active",
          "betAmount":"1000000000000000","potBalance":null,"usdUnitPrice":2437.24,
          "rows":[{"tiles":7,"multiplier":1.12,"deathTileIndex":null},
                  {"tiles":3,"multiplier":1.68,"deathTileIndex":null},
                  {"tiles":3,"multiplier":2.52,"deathTileIndex":null},
                  {"tiles":3,"multiplier":3.78,"deathTileIndex":null},
                  {"tiles":2,"multiplier":7.56,"deathTileIndex":null},
                  {"tiles":3,"multiplier":11.34,"de…   [truncated at 900 chars by the probe]

--- /api/games/145794c1-e83e-4258-a8d9-b5ea184f2f08/select-tile
    status="active"  hasSeed=false  seed=null
    rows=null  deathTiles=null  populatedDeathTile=null
    raw: {"isDeathTile":false,"currentRowIndex":1,"finalMultiplier":1.12,"status":"active",
          "currentRow":{"tiles":7,"multiplier":1.12,"deathTileIndex":5},
          "nextRow":{"tiles":3,"multiplier":1.68,"deathTileIndex":null},
          "version":2,"animationTag":null}

===== ANSWER =====
No active-game response carried the seed or death tiles.
(A seed on a FINISHED game is normal.)
```

## What each field means

| Observation | Reading |
|---|---|
| `status:"active"`, `gameSeed` absent, `commitmentHash` absent | Seed withheld while the game is live — correct |
| all 25 `rows[].deathTileIndex` `null` | Board not revealed pre-pick — correct |
| `nextRow.deathTileIndex: null` on a live game | The **unplayed** row stays hidden — the decisive non-leak |
| `currentRow.deathTileIndex: 5` | The row **already survived** is revealed. Spent row, no advantage |
| `version: 2` | The v2 backend serves live play (bears on F02) |
| `betAmount "1000000000000000"` = 0.001 ETH, `usdUnitPrice 2437.24` | ~$2.44, the intended minimum stake |

## Caveats, stated honestly

- **One game, one pick.** The capture shows one poll and one `select-tile`. It did not observe a
  second or third pick, nor a settlement. A leak that appears only on later rows, or only in the
  settlement response, would not appear in this sample. Subsequent evidence is consistent with the
  design holding, but this single capture is the live evidence and should be read as such.
- The probe at the time was **v1**, which could not read `currentRow`/`nextRow` and therefore
  produced its verdict from the poll response alone. It said "no leak" correctly, but not for the
  right reason — see `findings/F03-…md` §6. v2 fixes this; `probe-selftest.mjs` now proves it
  fires on a synthetic `nextRow` leak (v1: 5/6, v2: 6/6).
- The account used was the user's own, not the funded throwaway wallet. Irrelevant to the result —
  the probe reads API responses, which are identical for any authenticated session.
- No funds were moved by this capture. The $5 remains in the throwaway wallet, unspent.

## Reproduction

1. Load death.fun and log in; open DevTools → Console.
2. Paste `console-probe.js` (v2) **before** starting a game.
3. Start a game at the minimum stake; make exactly one pick.
4. Run `__df_dump()`.
5. Expect: `No live-game response carried the seed or a future row's skull.`
