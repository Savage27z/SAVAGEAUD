# F06 — Player-supplied game state: inputs ARE validated; the Mines table pays ~2.5% not 5%

**Scope:** the outsider-reachable surface — calldata a plain player controls.
**Verdict: no exploitable configuration found on this surface so far.** Two negatives and one
measurable inconsistency.

## 1. Mines validates the player's inputs

`Mines_Start(uint256 wager, address token, uint8 numMines, bool[25] tiles, bool isCashout)` — the
player supplies both the mine count and a 25-element tile array up front, while the board only exists
once the random lands. That is the classic shape for a "lie about your own state" bug, so it was
probed directly on the fork with out-of-range values:

| call | result |
|---|---|
| `Mines_Start(…, numMines=3, …)` | `InvalidNumMines()` (`0x822cb1a0`) |
| `Mines_Start(…, numMines=1, …)` | `InvalidNumMines()` |
| `Mines_GetMultipliers(numMines ≤ 3, …)` | returns `0` (no valid payout) |
| `Mines_GetMultipliers(numMines 4…23, …)` | returns real multipliers |
| `Mines_GetMultipliers(numMines ≥ 24, …)` | returns `0` |

So `numMines` is range-checked (`4…23`) and the payout lookup returns zero outside the range — a
player cannot select a degenerate configuration (e.g. 0 mines, or 24) to get a cheap guaranteed win.
The documented tile guards (`TileAlreadyRevealed(uint8)`, `InvalidNumberToReveal(uint32,uint256)`,
`MinNumberToReveal(uint32)`) are all present in the recovered error set, consistent with real
validation on the reveal path.

## 2. No positive-EV cell exists in the Mines multiplier table

`Mines_GetMultipliers(numMines, numRevealed)` is a **view**, so the whole payout table can be read
without playing. All 225 valid pairs were enumerated and compared against the true fair odds
(`fair = C(25, r) / C(25−m, r)` — the probability of surviving `r` reveals with `m` mines is
`C(25−m, r)/C(25, r)`, independent of which tiles the player picks):

- **pairs with RTP > 1.0: 0.** Best cell is `mines=10, revealed=15` at **RTP 0.9780**; worst ~0.9749.
- So there is no configuration a player can grind for a profit. Table saved:
  `recon/mines-multiplier-table.json`.

This is the check that matters for the "client-supplied state" family, and it is negative.

## 3. Inconsistency found: Mines pays ~2.5%, while the contract declares 5%

The same enumeration yields the *implied* house edge on every cell: **2.2%–2.5%**, i.e. RTP
97.5–97.8%. Meanwhile:

- `edgeFactor()` returns **9500** (5.00%) on every game proxy;
- and the edge is genuinely 5% where it was measured end-to-end: a winning RPS bet paid
  **1.9×** on an even-money bet (RTP 0.95), and a 1,000 MON win paid **1,899.98** (F03 §1).

So Mines' multiplier table is **not derived from the contract's configured edge** — it is a separate
(hardcoded or differently-parameterised) table that gives away roughly twice the edge the protocol
advertises. Effects:

- **Players** get better-than-advertised odds on Mines (still negative EV — 97.5% RTP is not
  exploitable).
- **LPs** earn roughly half the configured margin on the game with the most steps, and the
  advertised 5% edge is not true for it.

This is the "verifier-constant drift" family that produced a finding on death.fun (F03 §5), and it is
worth reporting as a Low/Informational consistency issue: either the table or the declared edge is
wrong, and nothing in the app tells a user which.

## 4. What this does NOT cover (open, and honestly blocked)

- **9 of the 19 game contracts have no known address.** Only 10 game proxies were mapped in recon
  (Mines, CoinFlip, Roulette, Plinko, Slots, Limbo, VideoPoker, RPS, Baccarat, FishPrawnCrab). HiLo,
  Keno, Crash, Dice, DragonTiger, Range, SicBo, War, WheelOfFortune are **unaudited** — including
  HiLo, whose `HiLo_Play(uint256,address,uint8 currentCard,bool isHigher,uint32 numBets)` takes a
  **player-chosen `currentCard`** with the randomness arriving afterwards, guarded by
  `InvalidCurrentCard(uint8)`. That is the single most promising remaining outsider-reachable input,
  and it could not be probed because the address is unknown (a first attempt accidentally used the
  **Limbo** address and produced eight uniform empty reverts — a wasted run; the tell was that *every*
  input value failed identically, which means the call never reached the contract).
- A topic-based discovery scan for the missing addresses **failed silently**: every chunk errored and
  the loop skipped them without reporting, so it returned "no logs in 30 days" for all 19 games —
  including RPS, which provably had ~100 plays in that window. The scan needs chunk-error surfacing
  and a positive control (both already written into `CHAIN_INFO.md` as rules; violated here anyway).

**Next:** recover the missing game addresses (frontend bundle, or a controlled topic scan with the
error rate reported), then run the same input-validation probe on `HiLo_Play.currentCard` and
`Keno_Play.pickedNumbers`.
