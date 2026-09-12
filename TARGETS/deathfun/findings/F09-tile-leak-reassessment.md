# F09 — Reassessment of the tile-leak conclusion (authorized, non-destructive)

**Target:** death.fun (DeathFun) — Abstract, chain 2741 — contract `0x27EDd16eE56958fddCBA08947f12C43DDEc2B20C`
**Date:** 2026-09-12
**Scope:** re-test the "no pre-reveal leak / a live board cannot be read" conclusion, covering
six gaps left open by F03–F08. Read-only against production; **local mock** for anything that
would otherwise need a state change. **No wagers placed. No other accounts used. No auth bypassed.**
**No live game interfered with.**

## Verdict

**Falsified** for every shape testable inside the authorized envelope — and one shape remains
**Blocked by missing authorized environment**.

- No test produced a leak of `gameSeed` or an unplayed row's `deathTileIndex` from an **active** game.
- The prior conclusion was nonetheless **overstated**: the scanner that certified "leaks: NONE"
  **could not see the `previousGame` shape at all** (proved with a planted leak, §T1). Corrected tool
  shipped and verified (§T1b).
- Two artifacts in the repo **contradicted each other** about the create-time `hash`; resolved with
  on-chain data (§T2) — **F05 §1 is falsified**, F07 §6 holds.
- One shape (two simultaneous live games) still needs a **production wager**, which this task forbids
  ⇒ **Blocked**, not "clean". The corrected scanner is now proven able to catch it (§T1b).

---

## Test records

### T1 — Does the F08 scanner cover the `previousGame` shape? (the gap F08 explicitly left open)
- **Hypothesis:** the scanner that returned "leaks: NONE" parses every read path, including
  `previousGame`.
- **Preconditions:** the unmodified scanner (`disclosure/live-capture/live-board-leak-scanner.py`)
  and a **local mock** of `/api/games/active` + `/api/games/history`
  (`mock_deathfun_server.py`) with three planted configurations.
- **Request/state transition examined:** `GET /api/games/active?gameType=death_race` where
  `previousGame` = an **active** game with `gameSeed` populated and all 25 `deathTileIndex` filled,
  while `currentGame` is clean.
- **Redacted response fields:** `previousGame.status="active"`, `previousGame.gameSeed=<SET>`,
  `previousGame.rows[*].deathTileIndex=<SET>`, `currentGame.gameSeed=None`.
- **Expected secure result:** the detector reports `SEED EXPOSED` + `UNPLAYED ROW REVEALED`.
- **Observed result:** **`leaks: NONE across every read path at every turn`** (exit 0). Source of the
  blind spot: `scan()` reads only `ac.get("currentGame")` and `history`; **`previousGame` is never
  referenced anywhere in the scanner**.
- **Reproducible:** **YES** — deterministic, local, three modes:

```
  secure         scanner_fired=False     <- negative control, correct
  leak-current   scanner_fired=True      <- positive control, correct
  leak-previous  scanner_fired=False     <- PLANTED LEAK, MISSED
```
- **Meaning:** F08's "leaks: NONE" carries **no information** about `previousGame`. The F08 doc says
  "the scanner is already wired to catch it" — **it was not.** This is a detector gap, **not** a
  protocol leak: no evidence any leak exists, only that the certification didn't cover the shape.

### T1b — Corrected detector + positive controls
- **Hypothesis:** a detector that parses `currentGame` **and** `previousGame`, gated on
  `status=="active"`, fires on every leak shape and stays quiet when secure.
- **Artifact:** `live-board-leak-scanner-v2.py` (pure `detect_leaks()`; `--self-test` with three fixtures).
- **Observed:** self-test **ALL PASS** (secure quiet; `leak-current` and `leak-previous` both fire with
  the slot named). Against the same mock, v1 → `leaks: NONE` (exit 0); **v2 →**
  `SEED EXPOSED via previousGame` + `UNPLAYED ROW REVEALED via previousGame (rows [1,2,3,4,5])` (exit 1).
- **Reproducible:** **YES** (`--self-test`, and v1-vs-v2 comparison on the mock).

### T2 — Is the create-response `hash` the on-chain commitment? (F05 §1 vs F07 §6)
- **Hypothesis (F05 §1):** "for every game created, the `hash` returned to the client at create
  **equals** the on-chain `gameSeedHash`."
- **Preconditions:** gid **4839273** (the game 1a06e1a5-… from F07 §6). Read-only `eth_call` to
  `games(uint256)` (`0x117a5b90`) on Abstract via `api.mainnet.abs.xyz`.
- **Request/state examined:** on-chain struct field `gameSeedHash` vs the create-response `hash`.
- **Fields:** on-chain `gameSeedHash = 0x4a76da3ecf71de12b1d86f9bda3b4fd8f38a1854caa2542a37d0bcbc563f9929`;
  create `hash = 0xbfed306807d95f94f876afe09ffd3a5fb13c3e01135c304aed5945f801326512`.
- **Expected secure result:** (per F05) equal.
- **Observed result:** **NOT equal.** F07's recorded chain value reproduces **exactly** on a fresh read
  (`True`). **F05 §1 is falsified; F07 §6 is correct.** F05 appears to have compared the create `hash`
  against the API's *own* `commitmentHash` field rather than the game's on-chain value.
- **Reproducible:** **YES** (`f09a_create_hash_forensics.py`).

### T3 — Does the create `hash` correlate with the seed or the board?
- **Hypothesis:** the create `hash` is a commitment over some (seed, board, version) payload —
  i.e. it leaks or commits to board information.
- **Preconditions:** the create `hash` above; gid 4839273's revealed seed
  `0x6d679f945aaa59b496…` and `rowConfig=[2]×25` read on-chain; the protocol's **own** construction
  taken verbatim from `provably-fair/upstream-verifier-shared.js`:
  `sha256(JSON.stringify({version, rows: rows||[], seed}))`.
- **Request/state examined:** offline recomputation only (no network state change).
- **Fields:** target `0xbfed3068…` vs computed digests.
- **Expected secure result:** no match (the value should not commit to a live board).
- **Observed result:** **607 candidate payloads, 0 hits** — 4 version encodings × 5 row shapes
  (skulls+multiplier, skulls-only, null skulls, bare tile counts, empty) × 4 seed encodings
  (`""`, actual 0x, actual bare, null) × all **6 top-level key orders**, plus 4 row-object key orders
  and 3 string constructions. Also **not** any of 9 neighbouring games' commitments and **not** any
  `seedHash` in the 898-game sample.
- **Sanity control (the reason to trust the negative):** the same hasher **does** reproduce gid
  4839273's on-chain `gameSeedHash` exactly from `{version:"v1", rows:<actual rows with skulls>,
  seed:<seed>}` → `True`. The hasher and board reconstruction are correct, so this is a real negative
  rather than a broken test.
- **Reproducible:** **YES** (`f09b_create_hash.js`, `f09c_create_hash2.js`).
- **Conclusion:** the create `hash` **does not commit to the seed or the board**, is **not** the
  on-chain commitment, and is **not used** by the verifier (F07 §6: the verifier prefills `hash` from
  `commitmentHash`). **Not a fairness break; remains unexplained. No finding** — treat as a
  presentational/documentation question for the team.

### T4 — Off-by-one: does the create `hash` equal a *neighbouring* game's commitment?
- **Hypothesis:** a placeholder/hash computed for the wrong index would leak another game's commitment.
- **Observed result:** tested gids **4839269–4839277** (9 games around the target) → **NONE** match.
- **Reproducible:** **YES** (`f09a_…`). Note: only the local neighbourhood was swept, not all games —
  the 898-game sample check in T3 widens this, still none.

### T5 — Do game-specific read endpoints expose active-game data given a UUID? (Q3)
- **Hypothesis:** some route taking a game UUID returns the game record (and, if ungated, the seed)
  for an **active** game.
- **Preconditions:** our own settled game UUID `1a06e1a5-6583-4737-b681-53c961ba3769`;
  **unauthenticated** read-only GETs (no session, nothing bypassed).
- **Observed result:** **no such route exists among 12 candidate paths** — `/api/games/{uuid}`,
  `/api/games/{uuid}/{state,status,verify,details,rows,seed}`, `/api/abstract/games/{uuid}` all
  **404 with the SPA HTML shell** (no handler). The two real read routes behave differently and
  correctly: `/api/games/history` and `/api/games/active` return **401 application/json** without a
  session.
- **Expected secure result:** no unauthenticated path to game data.
- **Reproducible:** **YES**.
- **Caveat:** a route that exists *and* requires auth would answer 401 (as the two real ones do), not
  404 — so the 404s are informative for these names, but this is not an exhaustive authenticated
  route enumeration. No active game was available to test against in any case.

### T6 — Does `/stats` (or a game-stats route) reveal rows? (Q4)
- **Observed result:** `/api/stats` and `/api/games/stats` → **404 SPA shell. Do not exist.**
- **Reproducible:** **YES**.

### T7 — Verifier links, background polling, client caches, real-time messages (Q4)
- **Verifier links:** the verifier page takes `version, rows, seed, hash` as URL/form params and
  prefills from values the app supplies (F07 §6). A verifier link for an **active** game therefore
  contains no seed, because the API withholds it. No server-side "verify by UUID" route exists (T5).
  → **no new surface.**
- **Background polling / history:** already tested in F08 on a genuinely live game at every turn
  (`/api/games/history` returned `status:"active"` with `gameSeed: None` and all skulls null) — **not
  repeated here.**
- **Real-time messages:** no WebSocket game channel was observed in the recorded captures
  (`/tmp/df-live1`, `/tmp/df-capture-shim`, `/tmp/df-preflight`, `/tmp/df-capture-dryrun`: 0 game
  payloads; the app is poll-based). Nothing to test.
- **Client caches:** not directly testable without an authenticated response. See T8.
- **Reproducible:** YES for the negatives that were executable; the WebSocket claim rests on the
  existing captures.

### T8 — Do caches isolate one player's game from another? (Q5)
- **Hypothesis:** a shared/edge cache could serve one player's game response to another.
- **Observed result (unauthenticated 401 responses):**
  `cache-control: public, max-age=0, must-revalidate`, `age: 0`, `cf-cache-status: DYNAMIC`.
- **Expected secure result:** no cacheable body for an authenticated game response.
- **Interpretation:** `max-age=0` + `must-revalidate` + `cf-cache-status: DYNAMIC` = Cloudflare is not
  storing/serving a cached copy. No evidence of a shared-cache cross-user path. **Honest limit:** this
  is the 401 path; the 200 headers were not observable without a valid session, so this is *absence of
  a caching signal*, not a positive isolation test.
- **Reproducible:** **YES** (headers above).

### T9 — Q1: can two simultaneous games make an unfinished game appear as `previousGame` with seed/skulls?
- **Status: BLOCKED BY MISSING AUTHORIZED ENVIRONMENT.**
- **Why:** it requires creating a second game while one is active — a **production wager**, which this
  task explicitly forbids — and the saved session (`/tmp/idtok.txt`, 2026-09-10) is **dead**
  (`/api/games/history` → `500`), so the environment can't be re-entered without a fresh browser login.
  There is no local staging backend for death.fun.
- **What was done instead:** the detector for exactly this shape was built and **proven to fire**
  (§T1, §T1b). So the gap is now **instrumented, not closed**.
- **Residual risk if untested:** unknown. `previousGame` serving a *finished* game's seed is correct
  by design (F05/F08); whether an *unfinished* one can occupy that slot in revealed form is untested.

### T10 — Q5: authentication/caching isolation across players
- **Status: BLOCKED BY MISSING AUTHORIZED ENVIRONMENT.**
- **Why:** requires a second account; "do not access other users' accounts" rules it out.
- **What is verified instead:** both game-read endpoints **401 without a session** (T5) and the
  response path shows no shared caching (T8). No cross-player read is reachable *unauthenticated*.

### T11 — Q2: does `pending_onchain → active` ever return sensitive game state?
- **Status: ALREADY COVERED — not repeated.** F05 §2 polled `/api/games/active` every **120 ms**
  across a create, observing `['pending_onchain','active']` with **0 leak events**.
- **Reassessment of that coverage:** valid. The transition payload is a `currentGame` object, which is
  the shape v1 *did* parse — so unlike the `previousGame` case, the negative here is supported by a
  detector that could have fired on it. No reason to re-run.

---

## Corrections issued to prior artifacts

| Artifact | Was | Now |
|---|---|---|
| `F05-…md` §1 | "for every game created, the `hash` returned to the client at create **equals** the on-chain `gameSeedHash`" | **FALSIFIED.** On-chain read of gid 4839273 shows the create `hash` ≠ `gameSeedHash`. F07 §6 is correct. |
| `F08-…md` §"Still open" | "The scanner is already wired to catch it — run it while a second game exists" | **WRONG.** v1 never parsed `previousGame`. Superseded by `live-board-leak-scanner-v2.py`, whose `--self-test` proves the capability. F08's "no mechanism found to read a board you have not played" stands for the shapes it parsed, and is **silent** on `previousGame`. |

## What is reportable

**Nothing new.** No active game exposed `gameSeed` or an unplayed row's `deathTileIndex` in any test.
The two corrections above are internal artifact fixes. The create-`hash` mystery is unexplained but
harmless (not used in verification). The open items remain the previously filed ones (laser_party loss
settlement, the verifier's wrong house-edge constant, the owner==signer trust root, unreachable
`increaseBet`).

## Artifacts

```
disclosure/f09-reassess/
  f09a_create_hash_forensics.py     on-chain read + hash tests   (T2, T3, T4)
  f09b_create_hash.js               candidate space, round 1     (T3)
  f09c_create_hash2.js              key-order permutations       (T3)
  mock_deathfun_server.py           local mock, 3 planted modes  (T1)
  f09d_detector_validation.py       v1 detector validation       (T1)
  live-board-leak-scanner-v2.py     corrected scanner + self-test (T1b)
  f09d-detector-validation.json     raw scanner output per mode
```

## Compliance statement

All production interaction in this reassessment was **read-only HTTP GET** (`/api/games/*` route
existence + headers) and **read-only `eth_call`**. Nothing was created, wagered, cancelled, or
settled; no other user's account or data was accessed; no authentication was bypassed; no game was
interfered with. Every state-changing scenario was exercised against a **local mock**.
