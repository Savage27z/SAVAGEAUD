Thanks — appreciated, and I'll keep this tight.

To demo it I need **two signed notes from your backend**, plus one detail on the second one.
Nothing new has to be built; both messages are ones your backend already generates.

**1. A `createGame` note for my test wallet**

`createGame` verifies a signature even for admins, so without this I can't own a game to demo on.
Message your backend would sign (this is the one you got right — `msg.sender` and `msg.value` are
both inside it):

```
keccak256(abi.encode("<prefix>:createGame", preliminaryGameId, gameSeedHash,
                     algoVersion, gameConfig, <MY TEST WALLET>, <STAKE WEI>, deadline))
```

Send me: `preliminaryGameId`, `gameSeedHash`, `algoVersion`, `gameConfig`, `deadline`,
`serverSignature`. Stake will be 0.001 ETH — your minimum.

**2. An `increaseBet` note for the game that creates**

This is the one the whole thing is about. Message:

```
keccak256(abi.encode("<prefix>:increaseBet", onChainGameId, amount, deadline))
```

Send me: `onChainGameId`, `amount` = `1000000000000000` (0.001 ETH), `deadline`,
`serverSignature`.

**Two small requests on this one:**

- **Please set `deadline` to 60 minutes or more.** On a replay demo the contract re-checks
  `block.timestamp > deadline` on every submission, so your production 15-minute default is
  tight for a run of five. Costs nothing, changes nothing about the format.
- **Please keep `amount` at 0.001 ETH.** There's no upside to a bigger number here and I'd
  rather nothing consequential ride on a demo.

**What I'll do with them**

Create the game (paying my own 0.001 ETH), then submit that single `increaseBet` note **five
times with `msg.value` = 0**. Your contract will credit 0.001 ETH to `betAmount` on each one.
Final state: `games(id).betAmount` reads 0.006 ETH, while the transactions sent 0.001 ETH total.

**Then I stop — I will not call `cashOut`.** `betAmount` stays inflated in storage so you can
read it yourselves, and nothing leaves your bankroll. The only ETH spent is my own stake plus
gas.

**On cashing out, since it came up:** I don't think we should, and not for etiquette reasons —
it wouldn't prove anything. `cashOut` needs *your* signature over `payoutAmount`, so paying out
the inflated figure means you signing for money nobody staked. That demonstrates you paid me,
not that the contract is broken, and it moves real player funds to do it. The inflation already
proves the missing guard. If you want to see the money path anyway, the clean version is: let me
`cashOut` my own game for my **real** 0.001 ETH — same flow, nobody out of pocket.

**You won't have to take my word for any of it.** I'll send a verification command that needs no
key and no cooperation from me:

```bash
python3 replay_demo.py verify --game-id <id> --txs <tx1>,<tx2>,<tx3>,<tx4>,<tx5>
```

It pulls each transaction's `value` field and `games(id)` straight from Abstract and prints them
side by side. If the replays show `value = 0` while `betAmount` is 0.006 ETH, it's confirmed on
public data alone.

**One thing worth deciding before you issue note 2, because it's the actual point:** your staged
v2 adds `rakebackNonces` and `referralNonces` to `claimRakeback` and `claimReferral`, but
`increaseBet(uint256,uint256,uint256,bytes)` is byte-identical to v1 and has no nonce. If v2 also
binds `msg.value` into that hash, say so and I'll drop the whole thing — I can't tell from an ABI,
and that would mean it's already fixed for the new deployment. If it doesn't, this demo is what
the redeploy would ship.

Ready when you are.
