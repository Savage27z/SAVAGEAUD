# F01 live demo (authorised)

**Status:** ✅ harness built and tested · ⏳ waiting on two signed notes from the death.fun team
**Owner rule:** read-only until the notes arrive. `preflight` and `verify` never send anything.

## Files

| File | What it is |
|---|---|
| `replay_demo.py` | the whole demo — `preflight`, `create`, `replay`, `verify` |
| `NOTE-FORMAT.md` | **send this to the team** — the two notes we need and why |
| `demo-receipt-*.json` | written on run; the artefact we hand over |

## The plan

1. `preflight` — confirm wallet funded, contract un-upgraded, `messagePrefix` live.
2. `create` — create a game we own, with note 1 (pays our own 0.001 ETH stake).
3. `replay` — submit note 2 five times with **`msg.value` = 0**.
4. `verify` — read back `games(id).betAmount` and every replay tx's `value` from public chain data.

Then **stop.** No `cashOut`. `betAmount` is left inflated in storage for them to read; nothing
leaves the bankroll. See `NOTE-FORMAT.md` → "Why not cash out as well".

## Why the notes are mandatory (this is the part that matters)

F01's two gaps live in `increaseBet`:

```solidity
function increaseBet(uint256 onChainGameId, uint256 amount, uint256 deadline, bytes calldata serverSignature) external payable {
    if (block.timestamp > deadline) revert SignatureExpired();
    bytes32 messageHash = keccak256(abi.encode(
        string.concat(messagePrefix, ":increaseBet"), onChainGameId, amount, deadline));
    _verifyAnyAdminSignature(messageHash, serverSignature);   // <-- needs a real note
    Game storage game = games[onChainGameId];
    if (game.player != msg.sender) revert NotAuthorized();
    game.betAmount += amount;                                  // <-- no msg.value check
}
```

`_verifyAnyAdminSignature` runs **before** anything else, so:

- **No funding level unlocks this.** A wallet full of ETH just pays gas to watch it revert.
- **No admin key helps.** `increaseBet` has no admin bypass — `isAdmin` callers skip the
  signature check in `cashOut` and `markGameAsLost`, but never in `increaseBet`.
- The only party who can produce a note is the backend, because the message is signed by a key
  in the `isAdmin` set.

So an authorised demo has exactly one shape: **they issue the notes, we replay one on-chain.**
That is also what makes it airtight — the signature is produced by the real production signer,
not forged, and the replay happens against the live proxy. It is the strongest possible evidence
and it is entirely within their consent.

## Verification is trustless, by design

`verify` needs no key and no cooperation:

```bash
python3 replay_demo.py verify --game-id <id> --txs 0xtx1,0xtx2,0xtx3,0xtx4,0xtx5
```

It pulls each transaction's `value` field and `games(id)` straight from Abstract RPC and prints
them side by side, so the team confirms the claim from public data without taking our word for
anything.

## Harness testing done before use (so the demo can't fail on our side)

- `increaseBet` selector `0x0b669290`, `gameCounter` `0x2e0be39a`, `messagePrefix` `0x91da2b3d` —
  all match the values probed live on the proxy.
- `increaseBet` calldata is byte-identical across repeat calls (that identity *is* the bug).
- `games(id)` / `getGameDetails(id)` struct decoder cross-checked against the `GameCreated`
  event, which carries `player` and `betAmount` as an independent oracle — **8/8 matched, 0
  mismatches**, across game ids from 200,000 to 4,838,797.
- Decoder pitfall worth remembering: the struct returndata carries **one leading offset word**
  (`0x20`), and dynamic-member offsets are relative to the tuple start at **byte 32**, not byte 0.
  Indexing from word 0 silently produces a plausible-but-wrong player and `betAmount` — it looked
  fine at a glance and was completely wrong.

## Safety rails in the script

- `--dry-run` on `create` prints calldata and sends nothing.
- `replay` always sends `msg.value = 0` — it is hard-coded, not a flag.
- `replay` refuses to run if `game.player != our wallet` (the contract would revert anyway).
- `replay` warns if `deadline` has already passed before spending gas.
- Every tx receipt is checked for `status == 0x1` before continuing, and the run aborts on the
  first failure so a partial result is never reported as a success.
- No `cashOut` call exists anywhere in the script.
