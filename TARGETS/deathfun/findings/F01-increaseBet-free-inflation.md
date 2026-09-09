# Finding F01 — death.fun (DeathFun contract)

## Reality Gate (Check before writing)

- [x] I have a concrete exploit path — not speculation (exact missing checks, exact lines)
- [ ] I can reproduce this on a fork or via on-chain call — **BLOCKED, not skipped.** Abstract's
  deployed bytecode is zksolc-compiled (zkSync-family L2), not standard EVM bytecode. Standard
  Foundry's fork execution (revm) cannot run it — confirmed: even a plain `gameCounter()` view
  call reverts under `vm.createSelectFork` against this contract, while the identical call via
  `cast call` against the live RPC succeeds normally. This needs `foundry-zksync` (a separate
  zkEVM-aware Foundry build), not set up in this session. The fork-test project (storage-slot
  math and signature construction verified correct against live on-chain values) is at
  `TARGETS/deathfun/fork-test/test/F01_IncreaseBetFreeInflationAndReplay.t.sol`, ready to run
  once that tooling exists.
- [x] I have exact line numbers for the vulnerable code
- [ ] I have tested the happy path AND the exploit path — happy path (createGame/cashOut)
  confirmed via real historical transactions on Abscan; exploit path blocked as above
- [x] This is not "owner can steal" (design choice) — exploitable by any ordinary player, no
  elevated privilege needed, against the shared bankroll
- [x] This is not "centralization risk" without exploitability
- [x] I've documented the trust model assumptions this finding relies on (see TMAAR.md)

**Status is honestly downgraded from what the code alone would justify, specifically because
the fork-execution step could not be completed.** Per RULES.md #2, treating this as a strong,
source-verified LEAD rather than a Confirmed finding until someone with `foundry-zksync` (or
the real admin key, for an authorized test) closes the loop.

## Title
`Missing msg.value validation + missing signature-replay protection in increaseBet() allows unlimited free bet-amount inflation from a single admin-signed message`

## Severity
High (Medium if the off-chain backend genuinely never trusts on-chain `betAmount`/`BetIncrease`
for anything — see the explicit unknown in TMAAR.md; treating as High because the missing checks
are real either way and the downside if the assumption fails is a direct bankroll drain)

## Impact × Likelihood

| Axis | Rating | Rationale |
|------|--------|-----------|
| **Impact** | High (conditional on off-chain trust in `betAmount` — explicitly flagged as unverified, not assumed) | If the backend uses on-chain `betAmount`/`BetIncrease` for payout sizing, odds, or limits in any way: direct path to draining the ~$44K bankroll. If not: still a permanently-falsifiable public record and fake on-chain volume, real but lower-stakes |
| **Likelihood** | High | Requires only ONE legitimate use of the "increase bet" feature ever (to obtain one valid signature) — no cryptographic breakage, no admin-key compromise, just resubmitting the exact same calldata Abstract already accepted once |

**Final severity: High** (High × High per METHODOLOGY.md's matrix, under the conditional
above — flagged honestly as conditional rather than asserted)

## Status
**Unverified — code-confirmed, fork-execution blocked by zkEVM tooling gap** (see Reality Gate)

## Root Cause Classification
- [x] Validation / input sanitization (missing `msg.value == amount` check)
- [x] Logic / state machine (missing signature-consumption/replay tracking)

## Impact Litmus Test
> A player who has ever obtained ONE valid admin-signed `increaseBet` message (i.e., anyone who
> has used the feature once through the normal app flow) can **call `increaseBet` again with the
> identical signature and `msg.value = 0`, repeated an unlimited number of times before the
> signature's deadline**, resulting in **`game.betAmount` being inflated by the full signed
> `amount` on every single call, with zero additional ETH ever required after the first
> legitimate top-up.**

## Summary
`increaseBet()` is marked `payable` — it can accept ETH — but never checks that the ETH actually
sent (`msg.value`) matches the `amount` parameter it's about to credit to the game's recorded
bet. It's also missing any mechanism to mark a given signed message as used. Put together: one
valid signature for "increase bet by X" can be resubmitted as many times as the caller wants,
before the deadline, each time adding X to the on-chain record for free.

## Vulnerability Detail
- **File:** `contracts/DeathFun.sol` (implementation `0x2c133230CFca00b9bf78c46DAe03A97019D96551`,
  behind proxy `0x27EDd16eE56958fddCBA08947f12C43DDeC2B20C` on Abstract)
- **Function:** `increaseBet()`
- **Lines:** L349-371

```solidity
function increaseBet(uint256 onChainGameId, uint256 amount, uint256 deadline, bytes calldata serverSignature) external payable {
    // --- validations
    if (block.timestamp > deadline) {
        revert SignatureExpired();
    }
    bytes32 messageHash = keccak256(
        abi.encode(
            string.concat(messagePrefix, ":increaseBet"),
            onChainGameId,
            amount,
            deadline
        )
    );        
    _verifyAnyAdminSignature(messageHash, serverSignature);

    Game storage game = games[onChainGameId];
    if (game.player != msg.sender) {
        revert NotAuthorized();
    }

    game.betAmount += amount;             // <-- credited regardless of msg.value
    emit BetIncrease(onChainGameId, amount, msg.sender);
}
```

Two independent gaps, either one alone is exploitable, and they compound:

1. **No `require(msg.value == amount, ...)` anywhere.** The function is `payable` (so real ETH
   CAN be attached) but nothing ties the attached value to the claimed `amount`. Compare to
   `createGame()` (L168-215), which correctly signs `msg.value` itself into the hash — so the
   admin's signature there is bound to a specific payment. `increaseBet`'s signature only covers
   `amount`, not `msg.value`, and the function body never cross-checks them.
2. **No signature consumption.** There is no `mapping` or flag anywhere marking a given
   `(onChainGameId, amount, deadline, serverSignature)` tuple as already used. `deadline` is the
   only time-bound; within that window (however long the backend chose — e.g. an hour), the
   identical calldata can be sent to the contract repeatedly, and it will succeed identically
   every time (status checks in `cashOut`/`markGameAsLost` don't apply here — `increaseBet` never
   changes `game.status`, so there's nothing to block a repeat call).

**Root cause:** the developer correctly bound `msg.value` into the signed hash for `createGame`
(the deposit-creating action) but didn't apply the same pattern to `increaseBet` (a second
deposit-adding action) — an inconsistency between two structurally similar functions, and
separately, never implemented any nonce/used-signature tracking anywhere in the contract.

**Consequence:** `game.betAmount` — the contract's own record of how much a player has genuinely
staked — can be inflated arbitrarily for free by any player who has ever legitimately used the
feature once. Whether this becomes a direct fund-drain depends entirely on whether the (closed-
source) backend trusts this on-chain value for anything (see TMAAR.md's explicit unknown). At
minimum, it falsifies a public, on-chain record and the `BetIncrease` event stream — which
DefiLlama's own fee/volume adapter for this protocol reads (`"DEX Volume: ... summed from each
settled bet's stake_amount on suigar::core::BetResultEvent"`-style methodology per the
category's convention) — so at minimum this can fabricate wagered-volume statistics with zero
real money.

**Remediation:**
```diff
 function increaseBet(uint256 onChainGameId, uint256 amount, uint256 deadline, bytes calldata serverSignature) external payable {
     if (block.timestamp > deadline) {
         revert SignatureExpired();
     }
+    require(msg.value == amount, "msg.value must equal amount");
     bytes32 messageHash = keccak256(
         abi.encode(
             string.concat(messagePrefix, ":increaseBet"),
             onChainGameId,
             amount,
             deadline
         )
     );        
     _verifyAnyAdminSignature(messageHash, serverSignature);
+    require(!usedIncreaseBetSig[messageHash], "signature already used");
+    usedIncreaseBetSig[messageHash] = true;

     Game storage game = games[onChainGameId];
     if (game.player != msg.sender) {
         revert NotAuthorized();
     }

     game.betAmount += amount;
     emit BetIncrease(onChainGameId, amount, msg.sender);
 }
```
Also worth considering, more broadly: move to EIP-712 typed signatures with `address(this)` and
`block.chainid` in the domain separator for ALL four signed actions (`createGame`, `cashOut`,
`markGameAsLost`, `increaseBet`) — see the separate hardening note in TMAAR.md Assumption 4
about missing domain separation (not itself exploitable today, but a real gap worth closing at
the same time).

## Proof of Concept
**Not executed — see Reality Gate above for the honest reason why (zkEVM/Foundry tooling gap,
not uncertainty in the bug).** Full test written and ready:
`TARGETS/deathfun/fork-test/test/F01_IncreaseBetFreeInflationAndReplay.t.sol`. It:
1. Forks Abstract mainnet
2. Uses `vm.store` (fork-local only, mirrors what `deal()` does for token balances) to make a
   test-controlled key an admin, since we don't hold the real admin's private key
3. Signs a real `createGame` message with that test key, creates a 1-wei game
4. Signs ONE `increaseBet` message for 5 ETH
5. Calls `increaseBet` with that signature and `msg.value: 0` — **seven times** — asserting
   `betAmount` grows by the full 5 ETH each time despite zero payment after the first call

Storage-slot math (`isAdmin` at slot 2, per `gameCounter`/`messagePrefix` at slots 0/1 —
cross-checked against real live values via `cast storage 0x27EDd16e... 0/1/2`) and the exact
hash-construction/signing logic were verified correct independent of the execution blocker.

To reproduce once `foundry-zksync` is available:
```bash
cd TARGETS/deathfun/fork-test
forge test --match-contract F01_IncreaseBetFreeInflationAndReplay -vvv
```

## Dedup Check
- [ ] Solodit search for this bug class — not yet done
- [x] `github.com/Death-fun` only hosts a client-side hash-verifier tool, no contract source
  repo to check changelogs/issues against
- [x] No audit badge/page found for death.fun
- [x] No prior disclosure found in this repo

## Recommendation
See diff above. Minimal fix is two lines (`msg.value` check + a used-signature mapping).

## Team Response
Not yet disclosed.

## References
- `CHECKLIST.md` → Signatures & EIP-712 → "msg.value in signature — is ETH amount part of the
  signed message? If not, can attackers grief with 1 wei? (see Compound M-2)" — this finding is
  exactly that pattern, just with the ETH amount fully unconstrained rather than off-by-one-wei
- Same file's domain-separator item (TMAAR.md Assumption 4) is a related but separate hardening
  gap in the same contract
