# F05 — The skull, attacked directly: it holds. Plus a laser_party loss-settlement gap.

**Target:** death.fun (DeathFun) — Abstract, chain ID 2741
**Date:** 2026-09-10
**Scope:** the death-tile ("skull") mechanic — unpredictability, commitment coverage, on-chain
recording — the settlement paths, the pick-race, and the final `increaseBet` read.

**Bottom line:**
- ✅ **The skull is sound.** Nine attacks, all negative; no leak on any path, including the
  live `pending_onchain` window; skulls provably derived from the committed seed.
- ✅ **A laser_party win is paid correctly** (verified on-chain and by balance delta).
- ✅ **The pick race is guarded** — a safe pick cannot overwrite a fatal one.
- ⚠️ **One real defect:** **laser_party *losses* are never settled on-chain.** The game stays
  `Active` in the contract forever and its seed is never recorded. Low-to-Medium, with a latent
  exposure (see §3).
- ℹ️ **`increaseBet` contract bug confirmed** (no `msg.value` check, no nonce) — unreachable.

---

## 1. The skull cannot be predicted or forged — nine attacks, all failed

`deathTileIndex(i) = parseInt(sha256(seed + "-row" + i).slice(0,8),16) % tiles_i`

| Attack | Result |
|---|---|
| Skulls present in the live API response | **No** — all 25 `deathTileIndex` `null` while active; `gameSeed` absent |
| Skulls leaked during the `pending_onchain` window | **No** — see §2 |
| Seed on-chain while live | **No** — `createGame` writes `gameSeed: ""` (DeathFun.sol:207) |
| Seed reuse | **No** — 898/898 unique |
| Seed derived from public fields | **No** — 0/898 across six derivations (`gid`, `createdAt`, `player`, `seedHash`, combos) |
| Seed derived from the `preliminaryGameId` given to the client at create | **No** — UUIDs are proper **v4**, no timestamp, no derivation matches |
| Weak entropy | **No** — full 64-hex, leading nibble uniform over 898, min 10 distinct chars |
| PRNG correlation | **No** — consecutive-seed XOR 897/897 unique |
| Commitment inversion / modulo bias | Preimage-resistant; bias ~1 in 6×10⁸ |

**Skulls verified to derive exactly from the committed seed:**

```
death_race   706/706 standard games, 0 contradictions vs actual play   (F03 §2)
death_race   my own games, 25/25 rows — on-chain seed → skulls == API-reported skulls
laser_party  my own game, 20/20 rows
```

And for every game created, the `hash` returned to the client at create **equals** the on-chain
`gameSeedHash`. **A player cannot predict, bias, or forge the skull.**

## 2. The last secrecy path — the `pending_onchain` window — is clean

The one untested way the skulls could have leaked was the window between `createGame` returning and
the on-chain game confirming. Polled `/api/games/active` every **120 ms** across a create:

```
statuses observed: ['pending_onchain', 'active']
LEAK EVENTS (populated skulls or a seed on a live game): 0
```

The only populated-skull payload observed belonged to an already-settled game. **Closed.**

## 3. ⚠️ REAL DEFECT — laser_party *losses* never settle on-chain

On-chain status vs API status, mode by outcome:

```
onchainId  what                            status   gameSeed  gameState
4839144    laser_party  LOSS  (~25 min)    Active   EMPTY     EMPTY      <-- never settles
4839255    death_race   LOSS  (fresh)      Lost     yes       yes
4839256    laser_party  WIN   (fresh)      Won      yes       yes
```

Re-checked 25 minutes later: the laser_party loss is **still `Active`** with no seed. So this is
persistent, not settlement latency, and it is specific to **laser_party losses** — death_race
losses settle normally, and a laser_party **win does settle and pay** (§4).

`markGameAsLost` is simply never called for this path. Three consequences:

1. **The skulls of a lost laser_party game are never recorded on-chain.** This is the skull
   connection: the only on-chain artifact for such a game is `gameSeedHash` — and for laser_party
   that hash is computed over `rows: []` (an empty board; F03 §3), so it commits the seed but
   **no board**. A player therefore has no on-chain artifact from which to verify the skulls, and
   verification rests entirely on the operator's own API returning the truth — the exact trust the
   mechanism exists to remove. (`gameState` is empty too, so the player's moves are not recorded.)
2. **The contract never leaves `Active`.** `cashOut` (DeathFun.sol:239) and `markGameAsLost`
   (:296) both require `status == Active`, so the normal `Active → terminal` transition never
   happens and the game remains callable indefinitely. The stake stays in the contract (consistent
   with `withdrawFunds`'s "implicitly collected fees" model, so the funds side is arguably by
   design).
3. **Latent exposure.** Because the game stays `Active`, a **`cashOut` for a lost game would still
   succeed** if any valid signature for that game id existed. I could not obtain one — the server
   only signs payouts during a live game, and a cash-out terminates the game — so this is a latent
   risk, **not** a demonstrated exploit. It is the reason the missing transition matters beyond
   bookkeeping.

Scoped honestly: **2 laser_party games observed** (1 loss stuck, 1 win settled). The loss case is
confirmed and repeatable in principle; I did not have budget to reproduce it a second time.

## 4. Verified working — laser_party wins are paid

One game, one pick, one cash-out:

```
create     -> 200 preliminaryGameId 4f3d2e33-…  commitment 0x39138c78…
pick       -> 200 isDeathTile=false, currentRowIndex 1, finalMultiplier 1.06666667
              currentRow {tiles:10, dimension:"col", deathTileIndex:5}   nextRow {...deathTileIndex:null}
cash-out   -> 200 payoutAmount 1066700000000000  payoutTxSignature 0x715865f5…
ON-CHAIN 4839256: status=Won  payout=0.0010667 ETH     (api.mainnet.abs.xyz)
balance: 0.00326803 -> 0.00331755 ETH
```

Note the pick response also reconfirms the skull-hiding rule outside death_race: the **just-played**
row is revealed (`currentRow.deathTileIndex: 5`) and the **unplayed** row stays `null`.

## 5. Verified guarded — the parallel-pick race does not work

`version` is client-supplied, which suggested optimistic concurrency and therefore a TOCTOU window:
fire every tile of a row simultaneously and hope a safe pick lands after the fatal one.

Board `[2]×25`, both tiles fired concurrently at row 0:

```
tile 0 -> 200  isDeathTile=true
tile 1 -> 400  {"error":"Game is not active"}      <-- rejected on the already-terminal game
AFTER: status=lost   deaths overwritten: 0
```

The server **serialises the terminal transition**, so a later safe pick cannot overwrite a death.
Honest caveat: only the death-first ordering was observed; the safe-first ordering (where a
successful advance makes the second request evaluate against the *next* row) is untested.

## 6. `increaseBet` — confirmed contract bug, unreachable

```solidity
function increaseBet(uint256 onChainGameId, uint256 amount, uint256 deadline, bytes calldata serverSignature)
    external payable
{
    if (block.timestamp > deadline) revert SignatureExpired();
    bytes32 messageHash = keccak256(abi.encode(
        string.concat(messagePrefix, ":increaseBet"),
        onChainGameId, amount, deadline          // no nonce
    ));
    _verifyAnyAdminSignature(messageHash, serverSignature);
    Game storage game = games[onChainGameId];
    if (game.player != msg.sender) revert NotAuthorized();
    game.betAmount += amount;                    // msg.value NEVER checked
}
```

`payable`, credits a bet, **never validates `msg.value`**; the signed message has **no nonce**, so
one signature replays until its deadline, inflating `betAmount` for free each time. No `Active`
check either. **Reachability unproven:** selector `0x0b669290` appears nowhere in the 76-chunk
bundle, the only references are the ABI and a session policy granting Unlimited / 100 ETH per call,
and ~16 candidate routes return the SPA shell rather than a JSON handler. **Critical if an endpoint
exists; not reachable as it stands.**

## 7. Cost ledger (all minimum stakes, no cash-out taken except our own game)

```
start                    0.00427907 ETH
death_race [2]x25        -0.001        race + pending_onchain test, lost on row 0
laser_party  [3]         -0.001 +0.0010667   win-payout test, cashed out our own stake
end                      0.00331755 ETH
net spent                ~0.00095 ETH  (~$2.32) + gas
```

Every spend was a minimum-stake game and each answered a named question. No player funds were
touched, no cash-out was taken on a game we did not own, and no mainnet writes were made beyond
those game creations.

## 8. Provenance

```
contract   : src/DeathFun.sol — createGame 168-215, cashOut 226-275, markGameAsLost 285-321,
             increaseBet 349-371, GameStatus enum 39-43, gameSeed:"" at 207, cashOut
             status guard at 239, markGameAsLost guard at 296
on-chain   : games(uint256) selector 0x117a5b90, decoded directly via api.mainnet.abs.xyz
             0x27EDd16eE56958fddCBA08947f12C43DDeC2B20C
api        : /api/abstract/games/create, /api/games/{id}/select-tile, /api/games/{id}/cash-out,
             /api/games/active, /api/games/history  (authenticated session)
scripts    : inline; verify_all_games.mjs / verify_fairness.mjs (F03 §2)
```
