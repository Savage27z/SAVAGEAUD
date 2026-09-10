**To:** (no security contact page / bug bounty / security.txt found on death.fun or
`github.com/Death-fun` — sending via [support / X DM / Discord — pick one])
**Subject:** `increaseBet()` — missing payment check and missing replay protection, plus a v2
note (private disclosure)

> **STATUS: DRAFT v3 — 2026-09-10.** v3 adds the contract-v2 section below. The earlier
> revision claimed a player could replay a note obtained through normal app use; that claim was
> wrong and was removed in v2 of this draft. See the correction note at the bottom. Do not send
> any earlier revision.

Hi death.fun team,

I'm an independent security researcher. I found a defect in your deployed DeathFun contract
(`0x27EDd16eE56958fddCBA08947f12C43DDeC2B20C` on Abstract). Sending this privately before any
public writeup. Nothing was ever run against mainnet, no real funds were touched, and no admin
signature was requested or forged.

**The issue — `increaseBet()`**

This function adds ETH to an active game, authorized by a signed note from your backend. Two
checks are missing:

1. **The payment is never verified.** The function is `payable`, but nothing compares `msg.value`
   to the `amount` it credits. Your `createGame()` gets this right — it signs `msg.value` into the
   hash, so the signature is bound to a specific payment. `increaseBet` signs only `amount`.
2. **The note is never consumed.** There is no record of which signed notes have been redeemed.
   The only bound is `deadline`.

Combined, the contract permits the same signed note to be submitted repeatedly, each time
crediting the full `amount` to `betAmount`, with no payment attached after the first. The contract
relies entirely on the off-chain caller to choose the correct `msg.value`.

Note that `increaseBet` is the only signed, ETH-crediting function in the contract with no
natural replay guard: `cashOut` and `markGameAsLost` both move `game.status` out of `Active`, so a
replay fails the status check. `increaseBet` deliberately does not touch `game.status` — it only
does `game.betAmount += amount`. A nonce is the only thing that closes this.

**What we verified, and how**

We confirmed the contract's behaviour end-to-end on a local zkEVM fork of your deployed bytecode
(Abstract needs a zkEVM-aware Foundry build; getting that working was its own project, and I'm
happy to share it). Using a test key installed as an admin **on the fork copy only** via
`vm.store`, a test account paid 1 wei for a real game, then replayed a single signed `increaseBet`
message 7 times, ending with a recorded bet of 35 ETH and no further ETH ever required.

**Important, and I want to be precise about it:** that fork test demonstrates what the *contract*
permits **given a valid signature**. It does not demonstrate that an external party can obtain
one — the test grants itself admin rights to get there. So please read the proof as "the function
is missing its guards," not "someone can already do this."

**That precondition matters, so here is everything we know about it**

- Your client bundle contains **no code that handles `serverSignature`**. The string appears 20
  times in the production bundle, and all 20 are inside ABI definitions — zero live occurrences.
- There is **no signature-issuing API route** in your app. The complete route list has no
  `/api/*sign*`, no `/api/*increase*`, no `/api/*bet*`.
- The session-key grant in your app names the server wallet
  (`0xc372B35582933277d5f4431F1a322Abc8DeA0612`) as the signer, so the backend builds, signs and
  submits these calls.
- I scanned the full history of the contract. `increaseBet` was called **7,329 times between
  11 March and 12 April 2026**, then **not once in the five months since**. Across all 7,329
  calls: every one attached exactly the signed amount, and **no signature was ever reused.** So
  this was not exploited, and there is no bad state to clean up.

**The part I'd most like you to look at before you ship — contract v2**

While re-checking your live frontend I noticed it ships **two complete contract interfaces at
once**: the v1 contract that is deployed, and a full **v2 ABI that is not deployed anywhere yet**
(your live proxy's EIP-1967 implementation slot still points at the audited v1 build,
`0x2c133230CFca00b9bf78c46DAe03A97019D96551`, and every v2-only selector returns no data on the
live proxy). So a v2 deployment looks staged.

Comparing the two, the v2 rewrite **adds replay protection exactly where it was missing** — and
skips `increaseBet`:

| Function | v1 | v2 | Nonce in v2 |
|---|---|---|---|
| `claimRakeback` | absent | `(uint256,uint256,bytes)` | ✅ `rakebackNonces(address)` |
| `claimReferral` | absent | `(uint256,uint256,bytes)` | ✅ `referralNonces(address)` |
| **`increaseBet`** | `(uint256,uint256,uint256,bytes)` | **`(uint256,uint256,uint256,bytes)`** — unchanged | ❌ **none** |

Both of the brand-new signed ETH-paying claim functions got a per-address nonce. `increaseBet`'s
signature is byte-identical to v1 and there is no `increaseBetNonces`-style getter anywhere in the
v2 ABI.

And v2 **re-enables** the function at a much higher ceiling. Your session-key policy module gains
an entry that v1 didn't have:

```js
sessionPolicyV1 = { signer: SERVER_WALLET, callPolicies: [createGame, cashOut, markGameAsLost] };
sessionPolicyV2 = { signer: SERVER_WALLET, callPolicies: [ ...same,
  { target: CONTRACT, selector: toFunctionSelector("increaseBet(uint256,uint256,uint256,bytes)"),
    valueLimit: { limitType: Unlimited, limit: parseEther("100") },
    maxValuePerUse: parseEther("100") } ] };
```

`increaseBet` isn't in `sessionPolicyV1` at all; in v2 it's granted at **Unlimited total value /
100 ETH per use**. So the rewrite doesn't just preserve the function — it turns it back on, at a
100 ETH single-call ceiling, and `/api/games/active` already carries an `increase_bet_pending`
status that will drive the flow.

**So here is the one thing I'd ask you to confirm before deploying:**

> Does v2's `increaseBet` (a) `require(msg.value == amount)`, and (b) consume a nonce?

An ABI can't tell me (a) — that fix is one line and needs no new getter, so it would be invisible
from the outside. So I am **not** claiming v2 still contains the bug. But (b) does show up in an
ABI, and it's missing. If both are in place, this is closed and you can ignore the rest. If not,
the redeploy is the moment this goes from dormant to reachable.

**Fix is small** — bind `msg.value` into the signed hash, and track consumed signatures:

```diff
 function increaseBet(uint256 onChainGameId, uint256 amount, uint256 deadline, bytes calldata serverSignature) external payable {
     if (block.timestamp > deadline) revert SignatureExpired();
+    require(msg.value == amount, "msg.value must equal amount");
     bytes32 messageHash = keccak256(abi.encode(
         string.concat(increaseBetPrefix, onChainGameId, amount, deadline)));
     _verifyAnyServerSignature(messageHash, serverSignature);
+    require(!usedIncreaseBetSig[messageHash], "signature already used");
+    usedIncreaseBetSig[messageHash] = true;
     Game storage game = games[onChainGameId];
     if (game.player != msg.sender) revert NotAuthorized();
     game.betAmount += amount;
     emit BetIncrease(onChainGameId, amount, msg.sender);
 }
```

While you're already rewriting: the per-action prefixes in v2 are a good improvement, but there's
still no `address(this)` / `block.chainid` binding in the hash. A future v3 that reuses these
prefix strings and this server key will make every v2 signature replayable on v3. Adding both to
the hash closes that permanently, and it costs nothing to do now.

**Also worth a look while you're in there** (v2 only, not urgent, just flagging since they're new
and I haven't seen them reviewed): `setGameCounter(uint256)` lets the owner rewrite the game ID
counter, and `setServerSignerAddress(address)` moves the trusted signer from the `isAdmin` set
into a single storage slot — the latter is a meaningful single-point-of-trust change compared to
v1, worth a second pair of eyes.

No ask beyond getting this in front of you. I'll hold off on anything public until you've had a
chance to look. Happy to send the fork project, the v2 ABI diff in full, or the exact patch.

**And to be explicit: no funds were taken at any point in this research, and nothing was written
to your live contract. Every on-chain interaction was a read.**

Thanks,
[your name / handle]

---

### Correction note (kept for the record, not for sending)

The first revision of this email stated that *"anyone who has ever gotten ONE legitimate note
from your backend"* can replay it, and described the fork signature as *"legitimately-obtained."*
Both were wrong:

- The fork PoC installs its own test key as admin (`vm.store`, `isAdmin` slot) — it manufactures
  the signature rather than obtaining one.
- The live client never handles a signature, so no player ever holds a note to replay.

The underlying defect (two missing checks) is unchanged and still real. Only the exploitability
claim changed. Sending the old version would have been a false claim that the team could disprove
in minutes.

### Why there is no "we exploited it live to prove it" paragraph in this email

Because the only live demonstration available is the one the backend performs — and the backend
is the party being asked to fix this. Cashing out an inflated bet would require the operator to
sign a payout for money that was never staked, so it would demonstrate that *they* paid us, not
that the contract is broken. It would also convert a hardening report into an unauthorized
withdrawal from live player funds, which is a materially different conversation and one that no
one reading this email consented to. The fork PoC plus the source lines prove the same thing
without that. If a live demo is wanted, the offer to run it **with their sign-off** is in the
email above (the "happy to send the fork project" line can be upgraded to a live-demo offer at
your discretion).
