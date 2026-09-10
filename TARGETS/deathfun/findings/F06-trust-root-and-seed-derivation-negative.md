# F06 — Trust root, signature binding, and the seed-derivation negative result

Date: 2026-09-10. Contract `0x27EDd16eE56958fddCBA08947f12C43DDeC2B20C` (Abstract, chain 2741).
Source of truth: `src/DeathFun.sol` (the deployed ABI matches it — verified below).

## 1. Selector corrections (my earlier notes were wrong)

`0x7bfe7a43` is **`cashOutPrefix()`**, a *view* getter — **not** `cashOut`. The real live selectors:

| selector | function | observed on-chain |
|---|---|---|
| `0xf04b8dc7` | `cashOut(uint256,uint256,string,string,uint256,bytes)` | called by owner, and by us |
| `0x3979c6a1` | `markGameAsLost(uint256,string,string,uint256,bytes)` | called by owner (38×) |
| `0x001308d8` | `createGame(string,bytes32,string,string,uint256,bytes)` | called by players |
| `0x0b669290` | `increaseBet(uint256,uint256,uint256,bytes)` | dormant since April |
| `0x24d7806c` | `isAdmin(address)` | — |
| `0x8da5cb5b` | `owner()` | — |

Correction applied to CHAIN_INFO/CHECKLIST where `cashOutPrefix 0x7bfe7a43` (view getter; real cashOut = 0xf04b8dc7) was recorded.

## 2. Trust root: owner **is** the payout signer, and it is one hot EOA

```
owner()                                        = 0x937CddeCf00cD7f1f667f385deDFaE275A0f2Ea7
isAdmin(0x937CddeCf00cD7f1f667f385deDFaE275A0f2Ea7) = true
isAdmin(0xa9fa3d1034e8bf2675b078070e303896cadb8eec) = false   (plain player, 38 games)
isAdmin(0x318f5353bab917b5243d78825875a247c90c8646) = false   (our test wallet)
isAdmin(0xc372B35582933277d5f4431F1a322Abc8DeA0612) = false   (the NEXT_PUBLIC "server wallet")
```

Recovered the signer from **our own** `cashOut` calldata (gid 4839256):

```
messageHash = keccak256(abi.encode(prefix+":cashOut", gid, payoutAmount, gameState, gameSeed, deadline))
ECDSA.toEthSignedMessageHash -> recover  = 0x937CddeCf00cD7f1f667f385deDFaE275A0f2Ea7
```

**The key that signs every payout is the same key that owns the contract.**
`withdrawFunds(uint256,address)` is `onlyOwner`, unguarded by any timelock/multisig/rate limit.
So compromise of the game server == immediate unilateral ability to withdraw the entire contract
balance. Also: the same EOA *directly* broadcasts `cashOut`/`markGameAsLost` (no signature needed
for admins), so the operational hot key and the ownership key are one and the same — there is no
separation between "the machine that runs the game loop" and "the key that can empty the contract".

Classification: **architectural / key-management risk, not exploitable by an outsider.** No path
from a player to `withdrawFunds`. Reported for the team's benefit, not as a bug class with an attack.

## 3. Signature binding audit — all four signed paths

| function | binds game | binds amount | binds caller | nonce / replay guard | msg.value checked |
|---|---|---|---|---|---|
| `createGame` | via `preliminaryGameId` | `msg.value` signed | **yes** (`msg.sender`) | yes — `GameAlreadyExists` on the preliminary id | n/a (value is the bet) |
| `cashOut` | `onChainGameId` | **yes** (`payoutAmount`) | n/a (must be player) | status flips to `Won` | n/a |
| `markGameAsLost` | `onChainGameId` | n/a | n/a (must be player) | status flips to `Lost` | n/a |
| `increaseBet` | `onChainGameId` | `amount` signed | **NO** | **NONE** | **NO** |

So F01 is confined to `increaseBet` alone: no nonce, no `msg.value` check, and — new observation —
**no status check either** (`increaseBet` will happily inflate `betAmount` on an already `Won`/`Lost`
game; every other mutating path gates on `status == Active`).

`increaseBet` is nonetheless **doubly unreachable**:
1. No client call site and no REST endpoint issues such a signature (confirmed: selector absent from
   all 76 shipped chunks; route enumeration blocked at Cloudflare).
2. Even holding a valid `increaseBet` signature is useless to a stranger: `require(game.player == msg.sender)`,
   and the `onChainGameId` is inside the signature — so the signature only works for the game's own player.

The other three paths bind their parameters correctly. `_verifyAnyAdminSignature` uses OZ `ECDSA`
(handles `v`, high-`s`, and zero-address) — no malleability or signature-replay shortcut found.

## 4. Seed derivation — NEGATIVE (this closes the "predict the board" hypothesis)

The client receives `gameSeedHash` (the commitment) **before** playing, and the seed's commitment is
`sha256(JSON.stringify({version, rows, seed}))`. If the seed were derived from anything the client
already knows, the board would be predictable pre-play and every game would be winnable.

Built **277 real `(preliminaryGameId → onChainGameId → revealed seed)` triples** from `GameCreated`
logs plus the `games()` struct, then brute-forced the seed against **3,047 derivation candidates**
across all 277 pairs:

```
sha256/keccak of : uuid | gid | player | bet | seedHash | uuid+gid | gid+uuid | player+uuid |
                   uuid+player | seedHash+uuid | bet+uuid | uuid-as-padded-hex  … etc
=> 3,047 candidates tested, 277 pairs, HITS: 0
unique seeds: 277/277
nibble-diversity: normal (70/277 below 16 distinct nibbles; expected ~25% by chance)
```

### Independent confirmation of the pasted board

The user supplied a 25×2 board. It decodes to **gid 4839255**, player `0x318f5353…8646` — **our own
test wallet** — status **Lost**, bet 0.001 ETH, i.e. the post-game verification page for a game we
lost. It is **not** a pre-reveal leak.

Verifying that payload against our reversed formula:

```
reversed formula  skull_i = parseInt(sha256(seed+"-row"+i).slice(0,8),16) % tiles_i
  -> 25/25 match the published deathTileIndex values
house edge:  0.04 -> 25/25 multipliers match      (the priced values 1.92, 3.84, … 32212254.72)
             0.05 ->  0/25 match                  (what their OWN published verifier uses)
```

So the on-site verifier is off by exactly one house-edge constant, which is why it reproduces 0/706
(F03): it computes different multipliers, the multiplier array is part of the hashed JSON, so the
hash never matches. Their own fairness tool cannot verify their own games.

## 5. Verdict

- Board generation: **sound.** Seed is 256-bit server entropy, committed on-chain at create, unique
  per game, not derived from any client-visible input, and the reveal matches the commitment 706/706.
- The skull cannot be predicted before play. No pre-reveal leak exists in any window tested
  (active list, `select-tile` response, `pending_onchain` transition — all clean).
- Contract: no outsider-reachable exploit found. Trust root is a single hot EOA holding both
  ownership and the payout-signing key.
