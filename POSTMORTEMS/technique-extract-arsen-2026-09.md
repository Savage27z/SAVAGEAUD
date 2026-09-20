# Technique Extract — Arsen Security newsletter (Sep 2026)

**Source:** arsensecurity.substack.com (author: "Arsen", X @arsen_bt) — free posts, read 2026-09-21.
**Why filed:** the free writing contains two bug *classes* stated at mechanism level, not the usual
"learn Rust / read the docs" filler. Both transfer outside Solana. Extracted here so they land in
CHECKLIST.md rather than dying in a browser tab.

**Verification status of the author's claims — do not repeat these as fact:**
- Raydium CLMM "extra ticks account not bound to pool" case study → **VERIFIED**, matches the public
  Immunefi bug-fix review (tick manipulation). Good faith signal.
- "Chainlink CCIP $10K" → plausible; CCIP ran a CodeHawks (Cyfrin) contest. Not verified to this author.
- "LeverageX $10K" → **UNVERIFIED**. No public trace found.
- "Chorus One $8.5K" → Chorus One/Lido-for-Solana does run an Immunefi program ($100K max), so an
  $8.5K High is plausible. Not verified to this author.
- The two posts below name no client, no date, no target → treat as anonymized/teaching artifacts.
  The mechanisms are sound regardless of authorship; the attribution is not.

---

## Pattern A — Identity derived from POSITION in a list strangers can append to

**Incident (as described):** off-chain Rust service needed "how was this account created". On Solana an
account stores state, never provenance, so it queried `getSignaturesForAddress` and took `.first()`.
Anyone can push a transaction into that address history for **one lamport**. Attacker's tx becomes
first → service reads the wrong tx → backfill queue stalls (DoS, not a single stuck request).

**Abstract class:** provenance/ordering/identity read as *position within an attacker-writable
collection*. The data source is not the account's own state — it is a list a node keeps about a public
address, i.e. **user input wearing a chain-data costume**.

**EVM analogues — where this lives in our targets:**
- Indexers / relayers / keepers reconstructing "the deposit that created position X" from
  `getLogs` ordering, `txIndex`, or "first event in range" — and any address can emit into the range.
- `eth_getLogs` paginated backfills that assume log order == logical order, or that take
  `logs[0]` as the creation event. Reorg handling compounds it.
- Off-chain oracles/cron jobs deriving "latest" or "original" from a sorted external list
  (subgraph results, `orderBy` APIs, third-party order books) that anyone can write into.
- On-chain: arrays/queues where the first element is treated as canonical while being pushable by
  third parties (public `push` on a "history" array). `.first()` and `.last()` are both wrong; only
  *explicitly keyed* lookup is right.

**Also from the post (keep):** `getSignaturesForAddress` caps at 1000 — so `.last()` after the fix
returned the oldest of the *page*, not the oldest ever. "Fix the ordering" is not the same as
"fix the identity."

**Detection:**
1. Grep every indexer/off-chain reader for `.first()`, `.last()`, `[0]`, `orderBy`, `sort`.
2. For each: **who else can write into that collection?** If anyone → the value is attacker input.
3. Preferred fix shape: put the answer in the state itself (mode/flag in the account/PDA, or an
   explicit on-chain mapping) instead of reconstructing history. Deleting the traversal beats
   ordering it correctly.

---

## Pattern B — Structural commitment "verified" by substring search

**Incident (as described):** Bitcoin light client's merged-mining (aux-pow) path. Four steps: parent
block unseen → coinbase proven into parent merkle root (**the only real check**) → `chain_root`
*computed* from submitter-supplied child hash + chain id + merkle proof → `.contains()` on the hex
rendering of `script_sig`. The searched field is the one a miner fills in by hand. Miner embeds their
own commitment plus the honest one → the same parent block attests to two child blocks.

**Abstract class:** a check that asks *"is this value present anywhere?"* when the spec demands
*"is this value at this offset, exactly once, after the marker?"* Finding a value ≠ validating where
it sits. The check runs, passes all honest tests, and is the wrong *kind* of check — which is why
review misses it: it looks exactly like the right kind.

**Second defect in the same line (separate bug, cheap to grep):** comparison was string-to-string
between two renderings (`.to_hex_string()` vs `.to_string()`), and Bitcoin stores hashes
little-endian while display prints reversed → the check **also rejected honest submitters**. A
verification that is wrong in both directions.

**EVM analogues:**
- `string`/`bytes` commitment checks via `contains`-style logic, `indexOf`, `toHexString` compares,
  and any ABI-encoded blob searched as a substring.
- Bridge / light-client / oracle headers where the attestation field is submitter- or
  relayer-writable (calldata, extraData, scriptSig-equivalents, `bytes extra` args, user-supplied
  proofs) and only a presence check is applied.
- Offset-free decoding: `abi.decode` on attacker-shaped blobs without asserting layout, magic bytes,
  or single-occurrence. Duplicate-key / duplicate-entry acceptance.
- Type/render mismatches: comparing `bytes32` to a string, `address` case/checksum compare,
  endianness on packed commitments, `abi.encodePacked` collisions.

**Detection:**
1. Grep: `contains(`, `indexOf`, `includes(`, `toHexString`, `to_string`, `String`, `toString`,
   and any `abi.encodePacked(` on user-influenced values.
2. For every commitment check: bytes↔bytes? offset specified **and enforced**? marker checked?
   occurrence-count == 1 enforced? who writes the searched field (if a relayer/miner/submitter →
   attacker input)?
3. Fuzz property: same field carrying two valid commitments must be rejected. If the harness can't
   construct that, the check is unverified by construction.

**Realistic fix shape (per the post):** parse the structure at the spec'd offset and reject
duplicates. Access control (only-relayer-can-submit) is a *door*, not a *lock* — record which one
shipped, because bounty triage treats them differently.

---

## How this maps to our own funnel question
The author's *thesis* (Solana = same skill, thinner reviewer pool, better rate) is independently
supported: public Rust/SVM contests show pools comparable to EVM ($107K Jupiter Lend, $104.5K
Meteora, $203.5K Solana Foundation on Code4rena) while Solana-native reviewer supply is visibly
tighter, and Rust audit pricing runs ~20–40% above Solidity for equal scope. That is a real supply
gap, not a pitch.

The workshop (28 Sep, Google Meet, ~30 min, free) is the top of a cohort-funnel. Our read: the free
posts are the product; the funnel is the upsell. Take the two patterns above, skip the course.

## Sources
- https://arsensecurity.substack.com/p/how-to-get-wrecked-via-solana-rpc (Aug 31, 2026)
- https://arsensecurity.substack.com/p/the-proof-the-miner-writes-himself (Sep 7, 2026)
- https://arsensecurity.substack.com/p/ignore-85-of-the-code-if-you-want (Feb 8, 2026) — Raydium CLMM case study
- https://immunefi.com/blog/bug-fix-reviews/raydium-tick-manipulation-bugfix-review/ (cited by the above)
- https://code4rena.com/audits (Solana/Rust pool sizes)
- https://chorus.one/articles/announcing-100k-bug-bounty-program-with-immunefi
