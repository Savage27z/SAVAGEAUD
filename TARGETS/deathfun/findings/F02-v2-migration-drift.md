# F02 — Contract-v2 migration drift: `increaseBet` was skipped by the replay-protection rewrite

**Target:** death.fun (DeathFun) — Abstract, chain ID 2741
**Date:** 2026-09-10
**Status:** ✅ Confirmed (all claims below are live-receipt-backed — see Provenance)
**Severity:** Informational (deployment-timing risk on F01) — but the *timing* is the point

---

## One-paragraph version

The live death.fun frontend ships **two complete contract interfaces at once**: the v1 contract
that is actually deployed, and a full **v2 ABI that is not deployed anywhere yet**. Comparing
them shows the team is mid-rewrite, and the rewrite applies signature-replay protection to the
functions where it was missing — `claimRakeback` and `claimReferral` each got a per-address
nonce — **except `increaseBet`, whose signature is byte-identical to v1 and which still gets no
nonce getter.** F01's root cause is a missing nonce plus a missing `msg.value` binding in
`increaseBet`. One of those two fixes cannot be verified from an ABI; the other was demonstrably
not applied.

---

## What was verified (receipts)

### 1. The live contract is still v1 — NOT upgraded

```
NEXT_PUBLIC_CONTRACT_ADDRESS = 0x27EDd16eE56958fddCBA08947f12C43DDeC2B20C

EIP-1967 implementation slot on that proxy:
  0x2c133230cfca00b9bf78c46dae03a97019d96551   ← byte-identical to the implementation
                                                  we audited (DeathFun.sol, 463 lines)
code size: proxy 7,200 bytes / impl 30,624 bytes — matches the audited build
```

Selector probe against the live proxy — every v2-only function reverts with **no data**
(no fallback, no selector match), which is what "the function does not exist on this contract"
looks like:

| Function | Selector | Live proxy result |
|---|---|---|
| `messagePrefix()` | `0x91da2b3d` | ✅ returns string (v1 has it) |
| `createGamePrefix()` | `0x3893c500` | ❌ no data |
| `cashOutPrefix()` | `0x7bfe7a43` | ❌ no data |
| `claimRakebackPrefix()` | `0x6e2d05a5` | ❌ no data |
| `claimReferralPrefix()` | `0x39cff220` | ❌ no data |
| `markGameAsLostPrefix()` | `0x0a959f20` | ❌ no data |
| `serverSignerAddress()` | `0x5271ee50` | ❌ no data |
| `rakebackNonces(address)` | `0x0c4c8d89` | ❌ no data |
| `referralNonces(address)` | `0x14346d07` | ❌ no data |

### 2. But the frontend ships the whole v2 interface

**Positive controls first**, so the "no data ⇒ not implemented" claim above is rigorous rather
than an absence-of-evidence argument. `increaseBet` with an expired deadline reverts with
`SignatureExpired()`, which proves the proxy *does* execute that selector:

| Probe | Revert / return data | Meaning |
|---|---|---|
| `increaseBet(…, deadline=1)` | `0x0819bdcd` | = `SignatureExpired()` — **function exists and reached its first check** |
| nonexistent selector `0xdeadbeef` | `0x` (empty) | empty revert = selector does not exist |
| `claimRakeback(uint256,uint256,bytes)` | `0x` (empty) | **v2-only, not deployed** |

So an empty revert genuinely means "no such function," and `increaseBet` genuinely is live. The
`0xdeadbeef` control is what makes this airtight.

Both interfaces are present in the same production bundle (76 JS chunks, deployment
`dpl_EL8LodHS2wjxZShsP7vH6U1XJhs2`). The v2 ABI — extracted from
`/_next/static/chunks/2dv16jyi4hsfw.js`, 116 function entries — contains functions that
**do not exist on the deployed contract at all**:

| v2-only function | Notes |
|---|---|
| `claimRakeback(uint256 amount, uint256 deadline, bytes serverSignature)` | new, **ETH-paying** |
| `claimReferral(uint256 amount, uint256 deadline, bytes serverSignature)` | new, **ETH-paying** |
| `payReferral(uint256, address)` | new |
| `rakebackNonces(address)` | **new — replay protection** |
| `referralNonces(address)` | **new — replay protection** |
| `serverSignerAddress()` / `setServerSignerAddress(address)` | signer moves from the `isAdmin` set into a storage slot |
| `withdrawFunds(uint256, address)`, `setGameCounter(uint256)` | new admin surface |
| `createGamePrefix()`, `cashOutPrefix()`, `claimRakebackPrefix()`, `claimReferralPrefix()`, `markGameAsLostPrefix()` | per-action domain prefixes replace the single `messagePrefix` |

Changed in v2:

- `createGame(bytes32 preliminaryGameId, bytes32 commitmentHash, uint256 deadline, bytes serverSignature)` — was `createGame(string, bytes32, string, string, uint256, bytes)`
- `cashOut(uint256 onChainGameId, uint256 payoutAmount, bytes32 gameStateHash, uint256 deadline, bytes serverSignature)` — was `(…, string gameState, string gameSeed, …)`
- `markGameAsLost(uint256, bytes32, uint256, bytes)`

### 3. The rewrite fixed the replay class — everywhere except `increaseBet`

This is the finding. In the same v2 ABI:

```
rakebackNonces(address)   ← nonce tracking ADDED for a new ETH-paying signed function
referralNonces(address)   ← nonce tracking ADDED for a new ETH-paying signed function

increaseBet(uint256 onChainGameId, uint256 amount, uint256 deadline, bytes serverSignature)
   ← UNCHANGED from v1. No increaseBetNonces. No per-action nonce of any name.
```

Compare v1 vs v2 signature lists:

| Function | v1 | v2 | Nonce in v2? |
|---|---|---|---|
| `createGame` | `(string,bytes32,string,string,uint256,bytes)` | `(bytes32,bytes32,uint256,bytes)` | n/a — status-guarded |
| `cashOut` | `(uint256,uint256,string,string,uint256,bytes)` | `(uint256,uint256,bytes32,uint256,bytes)` | n/a — sets status `Won` |
| `claimRakeback` | **absent** | `(uint256,uint256,bytes)` | ✅ `rakebackNonces` |
| `claimReferral` | **absent** | `(uint256,uint256,bytes)` | ✅ `referralNonces` |
| **`increaseBet`** | `(uint256,uint256,uint256,bytes)` | **`(uint256,uint256,uint256,bytes)`** | ❌ **none** |

`cashOut` and `markGameAsLost` are self-protecting because they move `game.status` out of
`Active`, so a replay fails the status check. `increaseBet` deliberately never touches
`game.status` (confirmed in the v1 source at `DeathFun.sol` — it only does
`game.betAmount += amount`), so a nonce is the *only* thing that would close F01's replay half.
The two brand-new claim functions got exactly that. `increaseBet` did not.

### 4. `increaseBet` is a live, intended app flow — not dead code

Two independent artifacts in the live bundle:

```
/api/games/active  → refetches while currentGame.status is one of
                     ["cashout_pending", "pending_onchain", "increase_bet_pending"]
```

and the Abstract session-key policy module:

```js
let rl = env.NEXT_PUBLIC_CONTRACT_ADDRESS;
rh = [
  { target: rl, selector: toFunctionSelector("createGame(string,bytes32,string,string,uint256,bytes)"),
    valueLimit: { limitType: Unlimited, limit: parseEther("100") }, maxValuePerUse: parseEther("100") },
  { target: rl, selector: toFunctionSelector("cashOut(uint256,uint256,string,string,uint256,bytes)"),
    valueLimit: LimitZero, maxValuePerUse: parseEther("1") },
  { target: rl, selector: toFunctionSelector("markGameAsLost(uint256,string,string,uint256,bytes)"),
    valueLimit: LimitZero, maxValuePerUse: parseEther("1") },
];
rf = { signer: env.NEXT_PUBLIC_SERVER_WALLET_ADDRESS,
       expiresAt: BigInt(now + 2592e3),            // 30 days
       feeLimit: { limitType: Lifetime, limit: parseEther("1") }, transferPolicies: [] };

sessionPolicyV1 = { ...rf, callPolicies: [ ...rh ] };
sessionPolicyV2 = { ...rf, callPolicies: [ ...rh,
  { target: rl, selector: toFunctionSelector("increaseBet(uint256,uint256,uint256,bytes)"),
    valueLimit: { limitType: Unlimited, limit: parseEther("100") },
    maxValuePerUse: parseEther("100"), constraints: [] } ] };
```

Read that carefully — it says two things:

1. `increaseBet` is **newly added to the session permission set in v2**. It is absent from
   `sessionPolicyV1` and present only in `sessionPolicyV2`, granted at **Unlimited total value
   / 100 ETH per use**. So the rewrite is not just preserving `increaseBet` — it is about to
   *re-enable* it, at a 100 ETH single-call ceiling.
2. The session `signer` is `NEXT_PUBLIC_SERVER_WALLET_ADDRESS =
   0xc372B35582933277d5f4431F1a322Abc8DeA0612` — i.e. the backend wallet is delegated the
   ability to submit these calls on the player's account. On-chain check: that address has
   **nonce 0 and balance 0**, which is exactly right for a signer-only key that never sends a
   transaction of its own. It is *not* the `isAdmin` signer (`0x937CddeC…`), which is a separate
   key — see F01's addendum.

### 5. The reachability conclusion from F01 is unchanged (second independent confirmation)

`serverSignature` appears **20 times** in the production bundle, and **every single occurrence is
inside an ABI definition** — zero non-ABI occurrences (grep for `.serverSignature`,
`serverSignature:`, etc. returns nothing). And the complete live API route list contains **no
signature-issuing endpoint**: no `/api/*sign*`, no `/api/*increase*`, no `/api/*bet*`. The only
`/api/v1/sessions` routes are Privy's own session management (`/api/v1/sessions`,
`/api/v1/sessions/logout`).

So F01's retraction stands, now on two independent artifacts rather than one: **the backend signs
and submits; no player ever holds a note.** This is what makes F02 a *timing* finding rather
than a live exploit.

---

## Why this matters (the actual impact)

Not a bug in itself — it is **F01 arriving at a decision point**, and the receipts say the wrong
branch is loaded.

- The team is clearly acting on the missing-nonce class. They added `rakebackNonces` and
  `referralNonces` to the two new signed ETH-paying functions. That is the correct fix, applied
  twice.
- `increaseBet` is the one signed ETH-crediting function in the family that **has no state
  transition of its own to act as a natural replay guard** (`cashOut` and `markGameAsLost` both
  move `status`; `increaseBet` only adds to `betAmount`). It is therefore the one function that
  *cannot* be protected anything other than by an explicit nonce — and it is the one that didn't
  get one.
- v2 also widens the blast radius: `increaseBet` goes from *not granted at all* in
  `sessionPolicyV1` to *granted at Unlimited / 100 ETH per use* in `sessionPolicyV2`.

If v2 ships as the ABI implies, the window between "dormant" (F01's current live state — 7,329
historical calls, then nothing since 2026-04-12) and "re-enabled at 100 ETH a call" is a
redeploy wide.

## Honest limits — what this evidence does NOT show

Stated plainly, because overclaiming here is how reports get dismissed:

- **An ABI cannot prove the absence of a `msg.value` check.** F01 has two independent gaps
  (no `msg.value == amount` requirement, and no nonce). The `msg.value` half needs no new
  getter, no new storage and no ABI change — the team could have added a one-line `require`
  and the ABI would look exactly as it does. **So we do not claim v2 still contains F01.**
- What we *can* claim, and all we claim: the v2 `increaseBet` signature is byte-identical to
  v1, no nonce getter exists for it anywhere in the v2 ABI while both of its new siblings have
  one, and the function is being re-enabled at a 100 ETH per-call session limit.
- The v2 ABI is a **client-side artifact**. It is strong evidence of intent, not of the
  deployed v2 code. If v2's *source* has a nonce under a name that somehow needs no public
  getter, this finding downgrades to "ABI hygiene" — but nonce mappings in this codebase are
  public by convention, and both examples shipped in the same ABI.

## Recommendation to the team (one line, goes in the disclosure)

> Since v2 adds `rakebackNonces` / `referralNonces` but leaves `increaseBet`'s signature
> unchanged, please confirm before you deploy that `increaseBet` also (a) requires
> `msg.value == amount` and (b) consumes a nonce. If it does, this is resolved and nothing
> further is needed. If it doesn't, the v2 redeploy is the moment F01 becomes reachable.

## Remediation

Unchanged from F01, and now cheaper to apply because the v2 source is already open in front of
them:

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

Also worth folding in while they are already rewriting: v2 adds per-action prefixes (good — that
partly addresses F01's addendum note about missing domain separation) but still has **no
`address(this)` / `block.chainid` binding**. A future v3 redeploy that reuses these prefix
strings and this server key will make every signature from v2 replayable on v3. Putting
`address(this)` and `block.chainid` in the hash closes that permanently.

---

## Provenance (all reproducible)

```
live deployment hash : dpl_EL8LodHS2wjxZShsP7vH6U1XJhs2
frontend chunks      : 76 x /_next/static/chunks/*.js (9.1 MB) pulled 2026-09-10
v2 ABI location      : chunks/2dv16jyi4hsfw.js  (116 entries)
env config location  : chunks/3wkztugs0h6o2.js
RPC                  : https://api.mainnet.abs.xyz/  (chain 2741)
proxy                 : 0x27EDd16eE56958fddCBA08947f12C43DDeC2B20C
impl (EIP-1967 slot) : 0x2c133230CFca00b9bf78c46DAe03A97019D96551  (= audited v1)
server wallet        : 0xc372B35582933277d5f4431F1a322Abc8DeA0612  (nonce 0, bal 0)
isAdmin signer       : 0x937CddeCf00cD7f1f667f385deDFaE275A0f2Ea7  (see F01 addendum)
scripts              : frontend-recon/probe_live.py, probe_new.py, probe_all.py
extracted interface  : frontend-recon/v2-abi-functions.json  (116 v2 functions)
```

No mainnet state was modified. Every on-chain call in this document is `eth_call` /
`eth_getStorageAt` / `eth_getCode` — reads only. No transaction was broadcast, no signature was
produced, no funds moved.
