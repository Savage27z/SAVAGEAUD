# F05 — The skull, attacked directly: it holds. Plus a real laser_party settlement gap.

**Target:** death.fun (DeathFun) — Abstract, chain ID 2741
**Date:** 2026-09-10
**Scope:** the death-tile ("skull") mechanic — predictability, commitment coverage, and
on-chain recording — plus the final `increaseBet` contract read.

**Bottom line:** the skull is **not predictable and not forgeable** in either mode tested. One
**real defect** was found alongside it, and it is about the skull's *proof*, not its secrecy:
**laser_party games never settle on-chain, so their skulls are never recorded on-chain at all.**

---

## 1. The skull is sound — every attack failed

Skull per row: `deathTileIndex(i) = parseInt(sha256(seed + "-row" + i).slice(0,8),16) % tiles_i`.

Attacked from every direction, all negative:

| Attack on the seed | Result |
|---|---|
| Skulls visible in the active-game API response | **No** — all 25 `deathTileIndex` are `null` while live; `gameSeed` absent |
| Seed on-chain while the game is live | **No** — `createGame` writes `gameSeed: ""` (DeathFun.sol:207); only written on settlement |
| Seed reuse across games | **No** — 898/898 unique |
| Seed derived from public fields (`gid`, `createdAt`, `player`, `seedHash`, combinations) | **No** — 0/898, six derivations tested |
| Seed derived from the `preliminaryGameId` returned to the client at create | **No** — UUIDs are proper **v4** (no timestamp), and no derivation matches |
| Weak PRNG / low entropy | **No** — full 64-hex, leading nibble uniform over 898, min 10 distinct chars |
| Consecutive-seed correlation | **No** — consecutive XOR 897/897 unique (no PRNG state leak) |
| Commitment inversion | Preimage-resistant (`sha256` over `{version, rows, seed}`) |
| Modulo bias in `% tiles` | Negligible (2³² mod 7 = 4, ~1 in 6×10⁸) |

**Skulls verified to derive exactly from the committed seed:**

```
death_race   706/706 standard games   (see F03 §2 — 0 contradictions vs actual play)
death_race   my own games             25/25 rows, on-chain seed → skulls == API-reported skulls
laser_party  my own game              20/20 rows  [1,7,4,0,3,0,2,1,5,4,2,2,1,3,0,0,0,0,0,0]
```

And the commitment is not just present but *accurate* — for every one of my games the
`hash` returned to the client at create **equals** the on-chain `gameSeedHash`.

**Conclusion: a player cannot predict, bias, or forge the skull.** The seed is generated
server-side with a sound RNG, held off-chain while the game is live, committed on-chain at
create, and revealed only at settlement — and the revealed seed reproduces the exact skulls that
were played.

## 2. ✅ REAL DEFECT — laser_party games never settle on-chain

Comparing every game's **API status** against its **on-chain status**:

```
game      type         API     ON-CHAIN  seed    state   verdict
855fe6be  laser_party  lost    Active    EMPTY   EMPTY   *** MISMATCH ***
339034f6  death_race   lost    Lost      yes     yes     ok
145794c1  death_race   won     Won       yes     yes     ok
d2161775  death_race   won     Won       yes     yes     ok
1aeff01a  death_race   lost    Lost      yes     yes     ok
e8f75ddc  death_race   lost    Lost      yes     yes     ok
db7c8c09  death_race   lost    Lost      yes     yes     ok
7090fdf1  death_race   lost    Lost      yes     yes     ok
d5d0a364  death_race   lost    Lost      yes     yes     ok
c307e51a  death_race   lost    Lost      yes     yes     ok
```

Every death_race game is consistent, and its wins carry a real `payoutTxSignature`
(`0xded1f49d…`, `0x2de0eb0f…`) — **death_race settles correctly, wins included.**

The laser_party game is different. Full on-chain record for `onchainGameId 4839144`:

```
status    : Active          <- the API says the game is over; the contract says it is live
betAmount : 0.001 ETH
gameSeed  : (empty)
gameState : (empty)
```

So for laser_party, `markGameAsLost` / `cashOut` was never called. Consequences:

1. **The skulls are never recorded on-chain.** This is the skull connection: a laser_party player
   has *no on-chain artifact* from which to verify the skulls. The only on-chain data is
   `gameSeedHash` — and for laser_party that hash is computed over `rows: []` (an empty board; see
   F03 §3), so it commits the seed but **no board**. Verification therefore rests entirely on the
   operator's own API returning the seed and the board, which is exactly the trust the
   "provably fair" mechanism exists to remove.
2. **The game stays `Active` in the contract forever**, holding the stake. Since `cashOut` and
   `markGameAsLost` both require `status == Active`, a stuck-Active game remains callable
   indefinitely — the normal `Active → terminal` transition never happens.
3. **Wins are unproven.** I could not verify whether a **won** laser_party game gets paid: the only
   won laser_party game in this account was superseded by my later game before I could read it, and
   I could not create another (see §4). Given a *loss* fails to settle, whether a *win* pays is the
   open question and it is the one that would matter most to a player. **This needs one test.**

Honest scoping: one laser_party game observed, one occurrence. It is consistent with the mode's
settlement path simply not being wired up, but I am reporting a single confirmed instance, not a
rate.

## 3. Also confirmed: `increaseBet` — no `msg.value` check, no nonce

Final read of `DeathFun.sol:349-371`:

```solidity
function increaseBet(uint256 onChainGameId, uint256 amount, uint256 deadline, bytes calldata serverSignature)
    external payable
{
    if (block.timestamp > deadline) revert SignatureExpired();
    bytes32 messageHash = keccak256(abi.encode(
        string.concat(messagePrefix, ":increaseBet"),
        onChainGameId, amount, deadline          // <-- no nonce, no per-use binding
    ));
    _verifyAnyAdminSignature(messageHash, serverSignature);
    Game storage game = games[onChainGameId];
    if (game.player != msg.sender) revert NotAuthorized();
    game.betAmount += amount;                    // <-- msg.value NEVER checked
}
```

Two independent defects that compose: **`msg.value` is never validated** (a payable function that
credits a bet without requiring payment), and **the signed message contains no nonce**, so one
valid signature can be replayed until its deadline, each replay adding `amount` to `betAmount` for
free. There is also no check that the game is still `Active`.

**Reachability is unproven.** The client never encodes this call (selector `0x0b669290` appears
nowhere in the 76-chunk bundle), the only references are the ABI and a session policy that grants
it Unlimited / 100 ETH per call, and ~16 candidate API routes all return the SPA shell rather than
a JSON handler. So the server signature — the one thing needed — has no known way to be obtained.
**Severity if an endpoint exists: Critical. As it stands: unreachable, but live code with a live
session policy.**

## 4. Cost and blockers (for the record)

- **Funds spent:** 0.002 ETH of the account's balance — 0.001 on the death_race probe game and
  0.001 on the laser_party game. Both were minimum bets. The account is now at
  **0.00025316 ETH (~$0.62)** and the throwaway at 0.00002324 ETH (~$0.06), so **no further live
  games can be created without funding.**
- **Untested for want of funds:** (a) whether a **won** laser_party game is paid out; (b) whether
  the skulls leak during the brief `pending_onchain` window between create and on-chain
  confirmation — the one remaining skull-secrecy path; (c) the parallel-pick race on
  `select-tile`, which the client-supplied `version` field makes plausible.
- No mainnet writes were made by this research other than the two game creations. No cash-out was
  taken on any game.

## 5. Provenance

```
contract   : src/DeathFun.sol (createGame 168-215, cashOut 226-275, markGameAsLost 285-321,
             increaseBet 349-371, GameStatus enum 39-43, gameSeed:"" at 207)
on-chain   : games(uint256) 0x117a5b90 decoded directly, api.mainnet.abs.xyz
             0x27EDd16eE56958fddCBA08947f12C43DDeC2B20C
api        : /api/games/history, /api/games/active (authenticated)
scripts    : inline analysis; verify_all_games.mjs / verify_fairness.mjs (F03 §2)
```

No funds were moved other than the two minimum-stake game creations. No cash-out was taken.
