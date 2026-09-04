# SHERWOOD — Privacy Mixer + Shielded DEX (Robinhood Chain)

**Status:** 🔴 M1 (fee bypass, source-based) + 🔴 NEW 2026-09-04: **deployed bytecode ≠ verified source** (see `SOURCE_DRIFT_20260904.md`) — the live vault's code is NOT the code that was audited; third-party proofs rejected by a drifted extDataHash check. M1 unconfirmed against deployed bytecode.
**Date:** 2026-08-05 (updated 2026-09-04)
**Source:** Blockscout-verified — SherwoodVault `0xf54013b8BE8fdFcF0CD1fD727c803F16c2450736` (live, 4.2 ETH + $525 USDG ≈ $9K TVL), impl-less immutable
**Repo:** sherwood-exchange/sherwood (⚠️ STALE — repo has a newer compliance circuit; deployed is the older transaction2 design)

## What it is
Tornado Cash-style ZK mixer (Groth16, Poseidon-2 tree, Poseidon-4 commitments) + a shielded DEX:
- `transact` — deposit/withdraw/internal-transfer of notes via ZK proof
- `executeSwap` — spend an input note (withdrawal proof, recipient = vault), route through an allowlisted router (Uniswap V2/V3), measure REAL balance delta, mint output note
- Per-(asset, epoch) Merkle trees with unbounded root history (sealed epochs stay spendable)
- Non-upgradeable custody vault; SwapLogic is a staticcall-only route builder (upgradable proxy but never delegatecalled)

## Live state
- Admin: **single EOA** `0x93080bdf...` ⚠️ (controls everything: fees, routers, SwapLogic, quotes, allowlist, pause-adjacent)
- **permissionlessSwaps = 1** — ANY token can be swapped (one leg must be a quote)
- withdrawFeeBps = 50 (0.5%), swapFeeBps = 50, CONFIG_TIMELOCK = 0 (2-step but instant)
- Verifier2 = `0x3d7bea...` (7 public signals: root, publicAmount, extDataHash, 2 nullifiers, 2 outputs)
- SwapLogic proxy = `0x52445a...`, impl `0x10562a...` (impl UNVERIFIED — can't read route-building logic)
- Old vault `0xF5Ba...` dead (0.0001 ETH dust). Hook `0x071f...` empty (holds nothing).

## 🔴 FINDING — M1: Withdrawal fee bypass via internal-transfer fee-to-self (quote assets)

**Where:** `transact` (SherwoodVault.sol) — extAmount == 0 branch + `_extData.fee` payment.

**What:** A user holding a QUOTE-asset note (ETH or USDG) can exit the mixer paying ZERO protocol fee:

1. Call `transact(assetId, inEpoch, proof, extData)` with:
   - `extAmount = 0` (internal-transfer branch — deliberately skips the quote gate)
   - `fee = noteValue` (e.g. 100 USDC)
   - `feeRecipient = own address`
   - output commitments summing to 0 (burn the note)
2. Circuit: `sumIns + publicAmount === sumOuts` with `publicAmount = -fee`, so `sumOuts = 0` — the proof is satisfiable with zero-value outputs.
3. Vault pays `fee` (the full note value) to `feeRecipient` = the user.
4. Protocol fee: **$0**. Normal withdrawal path would charge 0.5% (`withdrawFeeBps`).

**Why the guard misses it:** The anti-fee-evasion design requires `_isQuote(token)` on the fee payment — the comment explicitly says this stops "pay out an entire memecoin note as a fee." But for QUOTE assets (the only assets that can be withdrawn anyway!), the check passes trivially. The internal-transfer branch was quote-unlocked for consolidation, and the fee payment reuses that unlock.

**Impact:** Protocol loses ALL withdrawal fee revenue (0.5%). No user-fund loss — the circuit range-check (248-bit) prevents `fee > noteValue` from draining the pool. This is revenue loss, not theft. Severity: **Medium** (fee evasion, protocol economic loss).

**Fix:** Gate the fee payment on `extAmount != 0` (only allow relayer fees on real deposits/withdrawals), or charge `withdrawFeeBps` on the fee amount for internal transfers.

## Observations

- **O1 — Admin = single EOA + zero timelock.** Router/SwapLogic/quote/fee changes are 2-step but `CONFIG_TIMELOCK = 0` → propose+enable in two back-to-back txs. A compromised admin key can add a malicious router and drain in-flight swaps (bounded by allowlist check + minOut, but still). Accepted centralization risk — documented in comments.
- **O2 — Deployed circuit ≠ repo circuit.** Repo has a newer compliance circuit (labels, associationRoot, depositLabel); deployed verifier has 7 signals = older transaction2 design. Deployed circuit source NOT public — the actual ZK soundness (range checks, nullifier derivation, commitment structure) cannot be independently verified from source. Big caveat for a mixer: the circuit IS the security boundary.
- **O3 — SwapLogic impl unverified.** Route building is the only external-input path that shapes the router call; impl at `0x10562a...` has no verified source. The vault re-checks `ins.router == canonical` + allowlist + approveToken/Amount + callValue==0, so a malicious logic can't redirect funds — but the calldata content itself is opaque.
- **O4 — permissionlessSwaps = 1.** Any token can be a swap target (with one quote leg). Opens the vault to arbitrary tokens/honeypots — admin chose this; documented.
- **O5 — emptyLeaf shares outPubkey with real output note.** Each swap inserts a zero-value leaf with the same pubkey as the real note, adjacent in the tree — an observer can link the two leaves from the same tx. Minor privacy leak, no fund impact.
- **O6 — `receive()` absorbs donations.** Anyone can send ETH to the vault; it sits unbacked forever. Minor.

## What I checked (clean)
- Reentrancy: all state-changing paths nonReentrant; router call inside nonReentrant; WETH wrap/unwrap fine
- Merkle tree: standard incremental Poseidon insert, unbounded root history (O(1) lookup), pair-insert with rotation — Tornado-correct
- Nullifier double-spend: checked before state change, global
- extDataHash binding: full ExtData (incl. swapParamsHash) committed to proof — relayer can't redirect swap output
- Fee accounting in executeSwap: protocol fee comes out of the user's OWN amountIn (swapAmountIn reduced), not other users' backing — traced, consistent
- Swap output note minted from MEASURED balance delta — no free value (vault balance changes by exactly the delta)
- minOut checked on NET after fee deductions — correct slippage semantics
- Router allowlist re-check after SwapLogic runs (canonical + allowlist + approve checks) — solid

## Verdict
The vault architecture is genuinely well-designed (this is the most careful mixer code I've read — the comments show deep Tornado familiarity). The one real hole is the **fee bypass (M1)**: quote-asset notes exit fee-free via internal-transfer fee-to-self. Reportable as Medium (protocol revenue loss). No critical/high fund-drain found, with the honest caveat that the deployed ZK circuit source is not public — the ultimate soundness of a mixer lives in the circuit, and that part isn't verifiable from what's on-chain.
