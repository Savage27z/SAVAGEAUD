# F07 — Game registry from the bundle: the "9 unaudited games" don't exist on mainnet, and Dice points at the Range contract

**Status:** verified on-chain. Contains a **retraction** of my own earlier coverage-gap claim.

## 1. The registry (from the frontend bundle, `_next/static/chunks/6157-*.js`)

The bundle carries a per-chain game registry — `{game: {monadT: addr, monad: addr}}` — which is the
authoritative list of where the app sends players. Mainnet (`monad`) entries:

| game | mainnet address | on-chain check |
|---|---|---|
| CoinFlip | `0xb82360d0…` | 209 B proxy ✓ |
| RockPaperScissors | `0x843d62ad…` | 209 B proxy ✓ |
| Slots | `0xd6F08aF2…` | 209 B proxy ✓ |
| Plinko | `0x5859E292…` | 209 B proxy ✓ |
| Mines | `0x3014d056…` | 209 B proxy ✓ |
| Baccarat | `0x8261A173…` | 209 B proxy ✓ |
| Roulette | `0x4A050DD0…` | 209 B proxy ✓ |
| FishPrawnCrab | `0xbbE3FA39…` | 209 B proxy ✓ |
| Limbo | `0xb9e0b544…` | 209 B proxy ✓ |
| VideoPoker | `0xb86A1955…` | 209 B proxy ✓ |
| **Dice** | **`0x0B1E533e…`** | 209 B proxy — **but see §2** |
| **Range** | **`0x0B1E533e…`** | same address as Dice |
| Bankroll | `0x71dc4a72…` | 2739 B proxy ✓ |
| HiLo, War, DragonTiger, Keno, WheelOfFortune, SicBo, Crash | **`"0x"` (not configured)** | — |

13 registry entries → **12 distinct mainnet addresses**. So the mainnet game surface is **eleven game
proxies plus the bankroll**, and every one of them was already mapped in recon.

## 2. FINDING (Low, config): Dice is routed to the Range contract

Dice and Range share the same mainnet address, and that contract implements **Range**, not Dice.
Called against `0x0B1E533e…`:

| call | result |
|---|---|
| `Dice_Play(...)` | **empty revert** — selector absent |
| `Dice_GetState(address)` | **empty revert** — selector absent |
| `Dice_Refund()` | **empty revert** — selector absent |
| `Range_GetState(address)` | **present**, returns data |

The selector map of that proxy's implementation (`0xdba35808…`) contains `Range_Play`,
`Range_Refund`, `Range_GetState` + the shared base — and **no** `Dice_*` function. So any player the
app routes to Dice is talking to the Range contract, and any `Dice_Play` call it makes cannot succeed.
Either the registry entry is a copy-paste error, or Dice was replaced by Range on mainnet and the
entry was never cleaned up. The app lists the game either way.

Impact: functional/config, user-facing (a game that cannot be played, or fails silently), no fund
loss. Worth a line in the report because it is exactly the kind of thing an integrator copies.

## 3. RETRACTION: the "9 unmapped games" coverage gap was wrong

I recorded, in `spec.json` and in the F06 write-up, that **9 of 19 games were unmapped and therefore
unaudited**, and called HiLo the sharpest remaining outsider surface because
`HiLo_Play(..., uint8 currentCard, ...)` takes a **player-supplied card** while the randomness arrives
afterwards.

**That framing was wrong on both counts:**

- The mainnet registry has **no address at all** for HiLo, War, DragonTiger, Keno, WheelOfFortune,
  SicBo and Crash (`"0x"`). The testnet addresses that exist for them (`0x788A451C…` for HiLo etc.)
  have **zero bytes of code on mainnet** — verified with `eth_getCode`.
- Therefore **HiLo is not deployed on mainnet and presents no outsider risk.** A player-supplied
  `currentCard` cannot be attacked on a contract that does not exist on the chain in scope. The
  sharpest untested input I was tracking does not exist here.

**What survives as real remaining work on mainnet:** the multi-step games that *are* deployed — Mines
(`Mines_Start`/`Mines_Reveal(bool[25])`/`Mines_End`, 2 plays in 30 days) and VideoPoker
(`VideoPoker_Replace(bool[5])`) — plus the eight single-step games whose per-game implementations were
never individually swept. That is a smaller and more honest gap than "9 unaudited games".

## 4. Method note (the expensive part of this finding)

The topic-discovery scan returned **zero logs for all 19 games across 7 days**, including
RockPaperScissors, which provably had ~100 plays in a 30-day window. I treated that as a broken
scanner and rewrote it — with a topic-hash calibration that *passed*, a positive control, and
per-chunk error reporting (86 of 484 chunks errored, so the scanner genuinely was unreliable too).

None of that mattered. The result was correct: those games have no mainnet logs because they are not
deployed. The lesson, in order:

1. When a scan returns *absolutely nothing* over a window where you expect activity, **check the
   configuration source** (frontend bundle / docs / registry) before rebuilding the scanner. One grep
   of the bundle answered in 30 seconds what two rewrites of the scanner could not.
2. Calibration (does my topic hash match reality?) is necessary but **not sufficient** — it proves the
   instrument, not the population. A passed calibration made the empty result *look* trustworthy and
   actually reinforced the wrong conclusion ("the games are quiet").
3. An empty result and a broken scanner are indistinguishable from the inside. Only an external
   source of truth separates them.

## 5. Artifacts

```
recon/s7_find_games.py       calibrated scan (kept: the calibration + control are correct)
recon/game-addresses.json    (empty result — correct, see §4)
recon/eip7702-delegate.json  delegate selector map
/tmp/narbet-js/              the 49 downloaded bundle chunks the registry was read from
```
