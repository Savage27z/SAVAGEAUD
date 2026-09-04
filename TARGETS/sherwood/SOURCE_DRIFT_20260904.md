# SHERWOOD — DEPLOYED BYTECODE ≠ BLOCKSCOUT-VERIFIED SOURCE (source drift)

**Status:** 🔴 NEW finding — the live vault's code is NOT the code anyone audited
**Date:** 2026-09-04
**Target:** SherwoodVault `0xf54013b8BE8fdFcF0CD1fD727c803F16c2450736` (RHC, immutable, ~14.85 ETH + USDG live)
**Method:** runtime-bytecode string diff + fork-oracle proof that the deployed `extDataHash` check
rejects the verified source's own hash logic

## Summary

While attempting to fork-execute the M1 fee-bypass with real Groth16 proofs (full
reverse-engineered client pipeline: Poseidon2 hashing validated against on-chain hashers,
1,346-leaf Merkle replay root-matched, notes/nullifiers reimplemented, proofs generated with
the real `transaction2.zkey` from sherwood.cash), every deposit reverted with
**"Incorrect external data hash"**. Investigation proved this is not a bug in our pipeline —
the **deployed bytecode computes a different `extDataHash` than its Blockscout-verified source**.

## Evidence

### 1. Require-string set differs between verified source and runtime bytecode

Strings present in the verified Solidity source but **ABSENT from the deployed runtime**:
- `"only admin"` · `"asset not registered"` · `"Input is already spent"`
- `"Invalid merkle root"` · `"Invalid public amount"` · `"fee too high"`
- `"not pending admin"` · `"recipient unset"` · `"already registered"`

Strings present in the **runtime** but absent from the verified source:
- `"extData.fee must be zero"` · `"relayerFeeOut must be zero"` · `"relayerFeeOut exceeds proceeds"`
- `"tokenOut not swappable"` · `"one leg must be a quote"`

(Require-string diff is decisive for a non-optimizer-aliased build: every `require(x, "msg")`
embeds the literal. The verified source's missing strings cannot fail to appear if that source
compiled to this bytecode.)

### 2. Fork-oracle: deployed extDataHash check rejects the source's own computation

Method: took a REAL successful mainnet `transact` calldata (tx `0xe01972...`), swapped in a
bogus proof with fresh nullifiers (so execution reaches the hash check), and probed candidate
`extDataHash` values on an anvil fork of RHC:

| candidate edh | result |
|---|---|
| the real tx's committed edh (control) | passes hash check → reverts later at `Invalid transaction proof` |
| `keccak256(abi.encode(ExtData)) % FIELD` — exactly what the verified source's `_verifyAndConsume` requires | **`Incorrect external data hash`** |

The calldata ExtData segment was proven byte-identical to a clean decode→re-encode (ABI
signature/selector match `0xd6b932ff`), so the deployed code is NOT executing the hash logic
shown in the verified source. 3/3 real transact txs show the same mismatch; variants
(packed, head-only, no-enc, no-swapParamsHash, enc-zeroed, utf8-of-hex) all fail offline.

## Implications

1. **No audit covered the live code.** HashCloak/Nethermind/Zigtur/Kriko covered the
   EtherPool/ERCPool repo code; the deployed SherwoodVault is a *different build* than even
   the Blockscout source that was previously treated as ground truth (our own Aug 5 read +
   the Aug 29 M1 re-check). Any analysis of this vault from public sources is suspect until
   the runtime is the reference.
2. **M1 status:** the deployed `transact` region retains the structural strings M1 depends on
   (`"fee must be a quote asset"`, `"Unexpected ETH value"`, `"swapParamsHash must be zero"`),
   so the fee-bypass path is *likely* still present in the live code — but it could not be
   executed end-to-end on a fork because third-party proof construction is blocked by the hash
   drift. Treat M1 as **unconfirmed against deployed bytecode**.
3. **Verifiability/lock-in:** the hash drift means only the team's own client (which computes
   the matching hash) can transact with the vault. This is a P7 (fixed-on-paper ≠ live) pattern
   and a transparency failure for a privacy mixer whose security boundary is its circuit+hash
   logic — none of which is reproducible from public artifacts.
4. The newer-looking deployed strings (`relayerFeeOut must be zero`, `extData.fee must be
   zero`, `tokenOut not swappable`) suggest the deployed code is a **hardened/drifted variant**,
   possibly the "v2" the founder referenced — deployed at 0xf540 while Blockscout still serves
   the old source.

## Receipts

- `/tmp/sherwood_attack/vault_runtime.hex` — runtime bytecode (23,418 bytes)
- `/tmp/sherwood_attack/f540_source.md` + `f540_main.sol` — Blockscout verified source (fresh pull, byte-identical to repo copy)
- `/tmp/sherwood_attack/nodetest/oracle_test.js` — fork-oracle probe (control passes, keccak(abi.encode) rejected)
- `/tmp/sherwood_attack/nodetest/bytediff.js` — calldata segment == decode→re-encode (byte-identical)
- `/tmp/sherwood_attack/nodetest/anchorext2.js`, `fuzzvariants.js` — real-tx edh comparisons
- `cast run --trace-printer` trace of probe tx + `reconstruct_mem*.py` (partial memory replay)

## Recommended action (for the team)

Re-verify or re-publish the actual deployed source for `0xf540`; relabel explorer verification
if it cannot reproduce the runtime; re-run the paid audits against the true bytecode before
launching v2 or continuing to hold TVL under the current audit claims.
