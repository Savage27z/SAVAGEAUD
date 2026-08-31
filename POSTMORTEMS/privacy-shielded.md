# Privacy / Shielded Protocols + Bug-Bounty Disclosure Patterns

Sherwood-class (UTXO shielded vaults, merkle trees, note encryption) and the public
disclosure channels that reveal critical-finding internals.

## Real incidents in privacy/shielded protocols

### 1. Tornado Cash governance attack (May 20, 2023, ~$2.17M)
Malicious proposal disguised as a relayer-registry change with a hidden `selfdestruct()`
so the proposal contract could be **morphed after the vote** (updatable dependency
bait-and-switch), plus 10,000 TORN × 120 attacker addresses = 1.2M fake votes vs ~70K
legit. Executed via `delegatecall`; drained 483K TORN, DoS'd router, admin over
Tornado Nova. Immutable mixer pools (~$275M) untouched.
→ **Governance proposals are code**: updatable dependencies + hidden opcodes in
"routine" proposals. Vote simulation should include what the code CAN do later.

### 2. Tornado Cash second governance attack (Jun 25, 2026 — blocked, ~$23M at risk)
Proposal #67 (fake "0.5% fee + 90% burn"), unverified bytecode, `governance()` returned
a look-alike address (first 15 hex chars identical). Would have seized the TORN
treasury. Defeated 100%-against; attacker funded via Railgun.

### 3. Railgun GovernorRewards freeze (reported Jun 22, 2026; fixed Jul 18; ~$2.6M permanently frozen)
Permissionless `prefetchGlobalSnapshots()` checked only an **upper bound** on the
shared accounting cursor `nextSnapshotPreCalcInterval` — anyone could rewind and
re-advance it, re-running `earmark()` and pulling Treasury funds into GovernorRewards,
which has **no withdrawal path** → permanent freeze (not theft).
→ **Permissionless "helper" functions that mutate shared state** need lower-bound
checks, not just upper-bound. Frozen funds = loss of use, no exploit needed.

### 4. Tornado supply-chain note theft (Jan–Feb 2024, notes exfiltrated ~2 months)
Malicious JS in governance proposal #47 modified the IPFS UI to encode private deposit
notes as fake tx calldata and exfiltrate via hidden `window.fetch`. **Notes are bearer
credentials** — the frontend/UI is an attack surface even with sound contracts.
(Finding by Gas404.)

### 5. Tornado share-URL note leak (disclosed Feb 2020, 98 notes, no funds lost)
Share URL embedded the full private note; opening it leaked the note via HTTP
`Referer` to ~16 third-party services.

### 6. Aztec Connect claim-proof bug (disclosed Sep 12, 2023 — not exploited; ~$5M TVL at risk; $450K bounty)
Claim formula `user_output·total_input + remainder = total_output·user_input` runs mod p;
values split into 68-bit limbs but the **top limb only constrained to 68 bits** and the
**remainder had no range check**. Modular wrap → inject multiples of p → compute a
negative residual → **claim the full output in every claim = multiple-spend → drain TVL**.
→ **Circuit↔contract mismatch is where shielded-protocol criticals live**: every
prover-controlled witness feeding a public value (residuals, limbs, fee, refund,
recipient, nullifierHash) must be range-constrained INSIDE the circuit; audit EVM field
vs circuit field (mod p) overflow mismatch explicitly.

### 7. Aztec 2.0 / zk.money (disclosed Sep 2021, all patched, $0 lost)
- Pedersen hash inputs validated mod p instead of as integers → **two nullifiers per
  note** → double spend.
- Merkle root position not constrained in circuit → rogue provider inserts
  out-of-position leaf then vanishes → rollup frozen.
- Recursive proof aggregation flaw → forged double-spend proofs undetectable.
- Mersenne Twister (deterministic PRNG) → one leaked blinding factor breaks privacy.

### 8. MixBytes Tornado design-review pitfalls (apply to ANY merkle/UTXO mixer)
nullifierHash not raw nullifier (defeats mempool front-run griefing); uniqueness
enforced on-chain AND in-circuit; fee ≤ denomination range checks (EVM field mod 2²⁵⁶
≠ circuit field mod p); recipient/relayer/fee/refund bound into the proof;
root-history flooding DoS; zero-leaf/second-preimage merkle pitfalls; unconstrained
Circom `<--` signals.

## Public disclosure channels that reveal critical findings

### Immunefi Bug Fix Reviews (full technical post-mortems post-fix)
- **Wormhole Uninitialized Proxy — $10M bounty (Critical, $0 lost):** UUPS proxy whose
  implementation was **uninitialized** (prior bugfix reverted init) → anyone could
  `initialize()` it directly, set their own Guardian set, authorize an upgrade as a
  Guardian they controlled → brick the proxy → permanent lockup of all bridged funds.
  Disclosed by satya0x Feb 2022, fixed same day. → **Check implementation contracts
  are initialized; the uninitialized-proxy pattern is the template.**
  URL: immunefi.com/blog/bug-fix-reviews/wormhole-uninitialized-proxy-bugfix-review/
- **Aztec Multiple-Spend Error — $450K bounty:** the circuit bug above. → EVM-vs-circuit
  field mismatch class.
  URL: medium.com/immunefi/aztec-multiple-spend-error-bugfix-review-20074581d224

### Code4rena public reports (full findings + PoCs; C4 "High" ≈ critical impact; site shut down May 13 2026 but reports remain)
- **PoolTogether H-05 (2023-07):** permissionless `sponsor(0, victim)` silently
  re-pointed victim's `delegateOf`, zeroing delegated balance — griefing without
  approval. → zero-amount permissionless state writes.
- **BakerFi H-02 (2024-05):** **first-depositor inflation attack** — shares never
  seeded; direct ERC-20 transfers inflate totalAssets; attacker donates → next
  depositor gets 0-1 share → attacker redeems ~everything. → **RELEVANT TO ANY VAULT
  incl. shielded savings**: seed shares / burn first 1000 wei / virtual shares.
- **Next Generation H-01 (2025-01):** meta-tx forwarder took `domainSeparator` as a
  **user-supplied parameter** + no deadline → **cross-chain signature replay**.
  → relayer/meta-tx pattern family: one captured signature → unauthorized transfers on
  every deployed chain.

## Sherwood.cash relevance (our own target)

- Merkle tree + verifier + AES-GCM note encryption: apply MixBytes pitfalls (nullifier
  uniqueness, fee bounds, root flooding, second-preimage) + Aztec's limb/remainder
  range checks to the verifier.
- First-depositor inflation check on the vault's share math.
- Uninitialized-implementation check on any proxy (v2).
- Notes are bearer credentials — the app surface (UI, export, share URLs) is an attack
  surface (Tornado note theft class).
