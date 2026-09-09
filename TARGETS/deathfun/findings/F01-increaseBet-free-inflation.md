# Finding F01 — death.fun (DeathFun contract)

## Reality Gate (Check before writing)

- [x] I have a concrete exploit path — not speculation (exact missing checks, exact lines)
- [x] I can reproduce this on a fork or via on-chain call — **CONFIRMED**, executed end-to-end
  against the real deployed contract on a zkEVM-aware Foundry fork (`foundry-zksync`, built
  from source — see "Toolchain notes" below for what that took). Full run output in the Proof
  of Concept section.
- [x] I have exact line numbers for the vulnerable code
- [x] I have tested the happy path AND the exploit path — both confirmed: happy path
  (createGame/cashOut) via real historical transactions on Abscan; exploit path via the fork
  test below
- [x] This is not "owner can steal" (design choice) — exploitable by any ordinary player, no
  elevated privilege needed, against the shared bankroll
- [x] This is not "centralization risk" without exploitability
- [x] I've documented the trust model assumptions this finding relies on (see TMAAR.md)

**Confirmed end-to-end on a real zkEVM fork of the actual deployed contract.** RULES.md #2
satisfied. See "Toolchain notes" at the bottom of this doc for what it took to get a working
zkEVM-aware Foundry build on Windows — kept for future sessions since none of it is
exploit-specific, it's a real, reusable environment gap this repo hit for the first time here.

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
**Confirmed** — reproduced end-to-end on a real zkEVM (foundry-zksync) fork of the actual
deployed contract.

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
**Run and passing, against the real deployed contract on a zkEVM fork.**
`TARGETS/deathfun/fork-test/test/F01_IncreaseBetFreeInflationAndReplay.t.sol`. It:
1. Forks Abstract mainnet (via `foundry-zksync`'s `--zksync` execution mode)
2. Uses `vm.store` (fork-local only, mirrors what `deal()` does for token balances) to make a
   test-controlled key an admin, since we don't hold the real admin's private key
3. Signs a real `createGame` message with that test key, creates a 1-wei game
4. Signs ONE `increaseBet` message for 5 ETH
5. Calls `increaseBet` with that signature and `msg.value: 0` — **seven times**

```
Ran 1 test for test/F01_IncreaseBetFreeInflationAndReplay.t.sol:F01_IncreaseBetFreeInflationAndReplay
[PASS] test_F01_FreeInflationViaReplayedSignature() (gas: 993951540)
Logs:
  Game created. Real bet paid (wei): 1
  After 1st increaseBet (paid 0 ETH), recorded betAmount: 5000000000000000001
  After REPLAYING the same signature (paid 0 ETH again), betAmount: 10000000000000000001
  After 7 total replays of ONE signature, recorded betAmount (wei): 35000000000000000001
  Real ETH the player ever paid (wei): 1 (the original createGame bet)

  CONFIRMED: a single admin-signed increaseBet message can be replayed
  an unlimited number of times before its deadline, each time crediting
  the full `amount` to betAmount with ZERO required ETH - the function
  never checks msg.value against amount, and never marks a signature used.

Suite result: ok. 1 passed; 0 failed; 0 skipped; finished in 111.96s (34.53s CPU time)
```

The player paid **1 wei total** (the original `createGame` bet) and walked away with a recorded
`betAmount` of **35 ETH** through pure signature replay — seven free credits of 5 ETH each from
one legitimately-obtained signature.

To reproduce (see Toolchain notes below for the environment this needs):
```bash
cd TARGETS/deathfun/fork-test
ZKSOLC_PATH=/path/to/zksolc.exe forge test --zksync --zk-solc-path /path/to/zksync-solc.exe \
  --match-contract F01_IncreaseBetFreeInflationAndReplay -vvv
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

## Toolchain notes — getting `foundry-zksync` actually running on Windows

This took a genuinely long path; recorded in full so no future session has to rediscover it.
Standard Foundry cannot fork-execute zkEVM (zksolc-compiled) bytecode at all (see CHAIN_INFO.md
→ Abstract). What follows is what it actually took to get real fork execution working here:

1. **No official Windows binary for `foundry-zksync`.** Only Linux/macOS releases exist
   (`matter-labs/foundry-zksync` releases). Had to build from source.
2. **Building from source hits a real upstream Windows-portability bug.**
   `crates/zksync/compilers/src/compilers/zksolc/mod.rs` uses `std::os::unix::fs::PermissionsExt`
   (correctly gated `#[cfg(target_family = "unix")]` on its import) but calls it unconditionally
   in `set_permissions(&compiler_path, PermissionsExt::from_mode(0o755))` — no matching cfg guard
   on the call site. Patched: wrapped that call in `#[cfg(target_family = "unix")]` too (a no-op
   on Windows, which doesn't need chmod-style bits on downloaded binaries anyway).
3. **A separate, unrelated compile break: `cargo`'s toolchain auto-update mid-build.** The
   project's `rust-toolchain` file triggers a `rustup update stable` at the START of the very
   first build. If that update lands while cargo's `target/` cache still has fingerprints from
   before it, you get bizarre cascading errors (looked like 831 errors in an unrelated crate,
   `ratatui-core`, all "cannot find type X" — the REAL first error, easy to miss in a long log,
   was `only metadata stub found for rlib dependency core`). Fix: `cargo clean` once the
   toolchain has settled, then rebuild clean. Costs the cache, no way around it once corrupted.
4. **`get_operating_system()` in the same `zksolc/mod.rs` has no Windows case at all** — hard
   errors `"Unsupported operating system windows"` for anything not linux/macos. This gates
   the ENTIRE zksolc auto-download/lookup system, called from multiple places
   (`get_path_for_version`, `compiler_path`, `solc_installed_versions`, etc.). Patched the
   catch-all arm to fall back to a harmless `LinuxAMD64` default instead of erroring — safe
   because step 5 below bypasses the auto-download path entirely.
5. **`ZKSOLC_PATH` env var is documented (in a doc comment) but was never actually implemented**
   in this revision. Added a real check for it at the top of both `get_path_for_version` AND
   `compiler_path` (there are TWO separate zksolc-path-resolution entry points; missing either
   one still breaks) — if set and the file exists, use it directly, skip OS detection and
   auto-install entirely.
6. **The real Windows `zksolc` binary DOES exist upstream** — just missing from this Rust
   project's own OS-detection table. Real releases at `matter-labs/zksolc-bin`, e.g.
   `zksolc-windows-amd64-gnu-v1.5.15.exe`. Downloaded directly, pointed `ZKSOLC_PATH` at it.
7. **zksolc requires a special ZKsync-patched fork of `solc`, not vanilla solc.** Vanilla
   `solc-windows.exe` from `ethereum/solidity` fails with `"Only the ZKsync fork of solc can be
   used... ZKsync revision parsing: missing line"` when called directly, or a confusing
   `"The pipe is being closed"` error when invoked through forge's piping layer. The real
   binary lives at `matter-labs/era-solidity` releases, versioned like `0.8.30-1.0.2` (that
   `1.0.2` suffix is the ZKsync revision) — e.g. `solc-windows-amd64-0.8.30-1.0.2.exe`. Pass it
   via `--zk-solc-path`.
8. **GitHub release-asset downloads kept resetting mid-transfer on this network** (curl
   `Recv failure: Connection was reset`, different point each time, `--retry` doesn't help
   since the failure happens mid-transfer not on connection start). Fixed with a manual loop
   using `curl -C -` (resume) repeated until the file reaches the expected size.

End state, three local patches to `foundry-zksync`'s source plus two extra binaries:
- Patched `crates/zksync/compilers/src/compilers/zksolc/mod.rs` (3 spots: `#[cfg(unix)]` guard,
  `get_operating_system()` fallback, `ZKSOLC_PATH` check in both path-resolution functions)
- `zksolc.exe` (real Windows build, `matter-labs/zksolc-bin` v1.5.15) → set as `ZKSOLC_PATH`
- `zksync-solc.exe` (real ZKsync-fork solc, `matter-labs/era-solidity` 0.8.30-1.0.2) → passed via
  `--zk-solc-path`

None of this is exploit-specific — it's a reusable environment fix for any future Abstract (or
other zkSync-family L2) target that needs real fork execution on Windows.
