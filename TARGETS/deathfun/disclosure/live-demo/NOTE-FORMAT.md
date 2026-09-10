# Note format — what we need from the death.fun backend

The demo needs **two signed notes** from your backend. Your backend already generates exactly
these two messages today; nothing new has to be built.

Both are plain ECDSA (65-byte `r || s || v`, hex with `0x`) over a `keccak256` of an
`abi.encode`d tuple, verified on-chain against the `isAdmin` set.

---

## Note 1 — `createGame`

Needed so the demo wallet owns a game at all. `createGame` always verifies a signature (admins
do not bypass it), so without this we cannot even get to `increaseBet`.

Signed hash — note that `msg.sender` **and** `msg.value` are both inside it. This is the one
function you got right:

```solidity
keccak256(abi.encode(
    string.concat(messagePrefix, ":createGame"),
    preliminaryGameId,   // string
    gameSeedHash,        // bytes32
    algoVersion,         // string
    gameConfig,          // string
    <DEMO WALLET>,       // address  <- bound to the payer
    <STAKE WEI>,         // uint256  <- bound to the payment
    deadline             // uint256
))
```

JSON we need:

```json
{
  "preliminaryGameId": "f01demo-<random>",
  "gameSeedHash": "0x...32 bytes...",
  "algoVersion": "v1",
  "gameConfig": "{\"rowConfig\":[...]}",
  "deadline": 1789000000,
  "serverSignature": "0x...65 bytes..."
}
```

## Note 2 — `increaseBet`  ← the one the demo is about

Signed hash — there is **no `msg.sender`, no `msg.value`, and no nonce** in here:

```solidity
keccak256(abi.encode(
    string.concat(messagePrefix, ":increaseBet"),
    onChainGameId,   // uint256
    amount,          // uint256
    deadline         // uint256
))
```

JSON we need:

```json
{
  "onChainGameId": 4838799,
  "amount": "1000000000000000",
  "deadline": 1789003600,
  "serverSignature": "0x...65 bytes..."
}
```

### Please make `deadline` generous

On a replay demo the contract checks `block.timestamp > deadline` on **every** submission, so a
15-minute window (your production default) is tight. **60 minutes or more** makes the demo
comfortable. This costs nothing and changes nothing about the message format.

### Please use a small `amount`

`amount` = `1000000000000000` wei (0.001 ETH — your minimum bet) is ideal. There is no benefit to
a larger number for the demo, and a small one keeps everything consequential-free.

---

## What the demo does with these, in order

| # | Action | ETH moved |
|---|---|---|
| 1 | `createGame` with note 1, `msg.value` = 0.001 ETH | 0.001 ETH **in** (our own stake) |
| 2 | read `games(id).betAmount` | — it reads 0.001 ETH |
| 3 | `increaseBet` with note 2, **`msg.value` = 0** | **0 ETH** |
| 4 | read `games(id).betAmount` | 0.002 ETH |
| 5 | `increaseBet` again, same note, same calldata, **`msg.value` = 0** | **0 ETH** |
| 6 | read `games(id).betAmount` | 0.003 ETH |
| 7 | (×5 total replays) | 0 ETH |
| 8 | read `games(id).betAmount` | **0.006 ETH** |

Final state: the contract says we staked 0.006 ETH. We sent 0.001 ETH. Five replays of one
signature, none of them paid for.

**Then we stop.** No `cashOut` is called. `betAmount` is left inflated in storage so you can
read it yourself, and no money leaves your bankroll — the only ETH the demo wallet spends is its
own 0.001 ETH stake plus gas.

## Why not cash out as well

Because the cash-out leg is *your* signature, not ours. `cashOut` requires an admin signature
over `payoutAmount`, so paying out the inflated amount would mean **you** signing a cheque for
money nobody staked. That would demonstrate that you paid us, not that the contract is broken —
and it would move real player funds to do it.

The betAmount inflation already proves the missing guard. If you want to see the money path
anyway, the clean version is: let us `cashOut` our own game for our **real** 0.001 ETH stake,
which shows the flow completing without anyone being out of pocket.

## How to verify without trusting us

`verify` mode takes no key and no trust:

```bash
python3 replay_demo.py verify --game-id <id> --txs <tx1>,<tx2>,<tx3>,<tx4>,<tx5>
```

It reads each transaction's `value` field straight from the chain and reads `games(id)` from the
contract, then prints both side by side. If every replay tx shows `value = 0 wei` while
`betAmount` is 0.006 ETH, the finding is confirmed on public data alone — you do not have to
believe a word we say. The `GameCreated` event is a second independent oracle for the player
address and the initial stake.
