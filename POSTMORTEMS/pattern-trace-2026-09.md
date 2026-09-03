# Pattern Trace — Aug 20 – Sep 3, 2026 exploit wave: can it happen elsewhere?

**Purpose:** take every recent exploit we've studied (Cosmos EVM cluster, Moonwell,
Tectonic, Term, Provenance, Coldcard + context: Drift, KelpDAO, AFX, Harmony), strip
each to its abstract pattern, and map where else that pattern lives — so we know what
to look for on the next target instead of waiting for the next headline.

**Method:** every incident below was verified against primary/secondary sources
(rekt.news investigations, BlockSec/PeckShield/Galaxy/Bubblemaps analyses, protocol
postmortems) before inclusion. "Live exposure" claims are architecture-based and marked
where not yet confirmed on-chain.

---

## Pattern 1 — Authz predicate satisfiable from the attacker's default state
**Incidents:** Provenance (marker admin self-grant; `0 == 0`), Term Finance (empty
electorate = cheapest possible voter pool).

**Abstract class:** an access check that compares caller state against a value that
equals the caller's *starting* state (zero balance, empty supply, no participation).
If the predicate is true when the attacker has done nothing, it's not access control.

**Where else it lives:**
- "Hold 100% of supply" style checks (Provenance's exact shape) in token wrappers,
  escrow contracts, governance bootstraps — any `balanceOf(caller) == totalSupply()`
  or `== storedSupply` where supply can be 0 (fresh deploy, unfunded marker, non-fixed
  issuance).
- Quorum/participation measured against a denominator that can shrink to ~zero while
  the value protected stays large: Aragon/ve-token DAOs where only wrapped shares vote
  (Term), NFT-gated votes, "minimum X voters" with no floor on who those voters are.
- Allowlists/snapshots read from stale storage (see Pattern 2).

**Detection in audit:**
1. For every authz branch: instantiate a fresh, empty account. Is the predicate ever
   true? (Provenance's answer was *always*.)
2. What is the cheapest possible state that satisfies it? Cost-to-pwn should be
   proportional to value protected.
3. Fuzz property: `accountControlsAllSupply`-style predicates must be false when live
   supply is zero AND when caller balance is zero.

---

## Pattern 2 — Two sources of truth for one number; the sync between them is unguarded
**Incidents:** Cosmos EVM cluster (bank locked/spendable vs EVM statedb → underflow →
overflow redistribution), Provenance (marker struct supply vs bank supply → stale read),
Harmony (shard A ledger vs shard B receipts → replay credit).

**Abstract class:** the same quantity (balance, supply, spendability) exists in two
places; one is authoritative, the other is a *mirror updated by delta replay*; the
replay math assumes deltas only come from paths the mirror knows about. Break the
assumption (delegate from locked balance; spend from a state the mirror doesn't track;
replay a receipt) and the mirror diverges — underflow/overflow/stale-value.

**Where else it lives (EVM-translatable):**
- cToken/aToken/wrapper markets where internal share ↔ external token mirrors are
  synced by mint/burn events and can be polluted by direct transfers (Moonwell P3).
- ERC-4626 vaults whose `totalAssets()` is derived from an external position
  (Strategy) the vault doesn't fully control; any "balance cache" synced from another
  contract's events (credit lines, margin, escrow).
- Lock/mint bridges: mint authorization computed as "locked total − burned total";
  anything that lets the two legs desync (fee-on-transfer on the lock leg, partial
  burns, replay).
- Vesting/locked-balance logic: locked vs liquid vs delegated tracking where one
  operation (delegate, claim, slash) updates one view but not the other.
- **Cosmos-specific live exposure:** any chain running `cosmos/evm` < v0.6.2/v0.7.2
  (or without the May backport) is exposed to the exact exploit. Cosmos Labs named six
  exploited networks; other chains running the module took "quieter losses" per
  Cosmos Labs — verify any Cosmos+EVM chain's module version + upgrade record before
  treating it as safe. The chain list is NOT fully public yet (as of Sep 3).

**Detection in audit:**
1. Draw the balance dataflow: where is each balance read from, who updates it, and
   which operations update *only one* side?
2. Grep subtraction on any balance derived from another module/contract (`sub` in
   unchecked contexts, sync functions, "write-back" helpers).
3. Invariant: mirror balance == authoritative balance after *every* state-changing
   op, including delegate/lock/stake/transfer-in paths. Fuzz the sync with
   boundary deltas (1 wei over, exactly at, under).

---

## Pattern 3 — Caps and collateral factors that ignore how balance actually arrives
**Incidents:** Moonwell (supply cap bypassed by direct ERC-20 transfer to mMAMO; 50%
CF on a 40x-pumpable asset).

**Abstract class:** (a) enforcement only on the *gated path* while collateral math
reads *raw balance*; (b) risk parameters (CF, caps) sized to price, not to market
depth or feed deviation limits.

**Where else it lives:**
- EVERY cToken-family market (Compound v2/v3 forks dominate BSC/Cronos/Base new
  listings): `balanceOf`-driven collateral + deposit-path-only caps.
- ERC-4626 vaults with deposit caps where shares/withdraw power is computed from
  balance; rebasing/fee-on-transfer collateral that inflates balance post-deposit.
- CDPs and perp margin accepting long-tail collateral with generous CFs.
- Any market where the price feed aggregates a thin venue (see Pattern 4).

**Detection in audit:**
1. Enumerate every path that increases the counted balance: deposit, direct transfer,
   donation, rebase tick, airdrop claim, fee-on-transfer bonus, self-transfer. Does
   each respect the cap? Does collateral math use tracked shares or raw balance?
2. Cross-check CF vs real DEX depth (e.g., $2M moves price 40x → CF must be tiny) and
   vs the feed's own deviation bounds.
3. Test: transfer collateral straight to the market contract — does borrow power
   increase without hitting the cap? (This exact test would have caught Moonwell.)

---

## Pattern 4 — Self-referential valuation + whole-market single-call exits
**Incidents:** Tectonic (exchange rate counts the attacker's own borrows as assets →
8x rate; then lagging feed ×195 on thin collateral; `borrowMax()` one-call sweep).

**Abstract class:** a protocol values its own liability/claim token using a formula
whose numerator the attacker can inflate by being a large fraction of the market's own
balance sheet; exit paths (max-borrow) lack per-market caps.

**Where else it lives:**
- Every Compound-v2-derived market (rate = (cash + borrows − reserves) / supply) where
  one address can own a big share of a token's supply — the entire DeFi lending
  ecosystem of forks (TONIC-family on Cronos, most BSC lending, etc.).
- ERC-4626 vaults where `totalAssets` includes loan receivables or yield positions the
  depositor can influence via self-loops; credit/line-of-credit protocols; structured
  products with internal debt tokens.
- Any lending UI with a "borrow max" convenience that sweeps a market's entire cash.

**Detection in audit:**
1. Decompose the exchange-rate/PPS formula: can a single actor inflate ANY term in the
   numerator? What fraction of a market can one address own?
2. Is there a per-market cash/borrow cap on max-borrow paths?
3. For each collateral: is its feed pushed (lagging) and its liquidity thin? A
   self-debt rate inflation + thin-collateral pump + lagging feed = Tectonic recipe.

---

## Pattern 5 — Single points of trust in verification chains
**Incidents:** KelpDAO (1-of-1 LayerZero DVN + RPC poisoning → forged packet, $290M),
AFX (5 hot validator keys cleared a 6,667/10,000 threshold, $24.15M), Harmony (quorum
counted full committee not enabled signers; nil mask accepted; unauthenticated receipt
fields → replay), Drift (admin key after 6-month infiltration, $285M).

**Abstract class:** security rests on N-of-M signers/verifiers where (a) M is small or
keys are hot, (b) the threshold logic counts the wrong set (full committee vs enabled;
empty bitmap passes), or (c) the "proof" identity fields aren't bound to the signed
data (replayable).

**Where else it lives:**
- Every omnichain/OFT token still running 1-of-1 DVN or a single relayer (LayerZero
  says it won't *sign* for new 1-of-1 configs — existing ones and other messaging
  stacks with single verifiers remain).
- Small validator-set bridges (N=3–7) with hot keys; "dispute window" designs that
  assume an honest watcher exists.
- Any BLS/ECDSA threshold check: count *enabled* signers from the bitmap, reject empty
  and nil masks, reject identity/all-zero aggregate signatures.
- Receipt/proof replay: spent-markers and dedup keys must derive only from fields bound
  to the signed header (Harmony's flaw was keying on unauthenticated `ShardID` +
  `BlockNum`).

**Detection in audit:**
1. Draw who-can-approve-what: every "if quorum says yes" — then test empty,
   duplicate, reordered, nil signer sets.
2. For every cross-chain message/receipt: what exactly is signed, and is every field
   used in dedup part of the signed data?
3. Dispute/fallback paths: what happens if the *only* verifier is wrong or down?

---

## Pattern 6 — Fail-open design in secret/entropy generation
**Incident:** Coldcard (RNG "fallback" to a PRNG seeded from public device state;
`#ifndef` on a macro defined as 0).

**Abstract class:** security-critical generation has a non-security fallback path that
activates silently; compile-time flags are existence-checked, not value-checked.

**Where else it lives:** keygen/seed code in wallets, MPC threshold-signing setups,
TEEs, hardware security modules, randomness in on-chain games with fallbacks (already
partially in our checklist under Randomness).

**Detection in audit:** any place randomness or keys are produced — verify no code path
can route to a non-cryptographic source; for C/C++/embedded: check `#ifdef/#ifndef`
semantics on macros that could be defined-as-zero; for Solidity: check
`block.prevrandao`/VRF fallback branches.

---

## Pattern 7 — Fixed-on-main ≠ fixed-in-production (disclosure is the mitigation)
**Incidents:** Cosmos EVM cluster (fix merged May 13, exploited Aug 20 — silent
backport, no advisory, halt advice 6 days late, 4+ chains drained), Coldcard (bug
shipped Mar 2021, disclosed Jul 2026).

**Abstract class:** the gap between "we fixed it" and "everyone is fixed" is itself
the vulnerability window. Severity framing + backport + coordinated halt guidance are
part of the fix, not PR.

**Detection in audit (applies to us as researchers AND to protocols we audit):**
1. When a finding touches shared/upstream infra, ask: which release branches carry the
   fix, what do the release notes say, and is the operator guidance *halt* or
   *upgrade*? Silent "important security fixes" = countdown starts when someone
   re-derives the bug publicly.
2. For protocols: dependency hygiene — pin and verify upstream module versions; a
   chain is only as patched as its shared modules.

---

## Pattern 8 — Nominal ≠ realizable (attacker profit is liquidity-bounded)
**Incidents:** Nesa ($50M nominal → $60K), KiiChain ($9.7M → $1.6M), TAC (2.986B TAC →
~$950K sold portion), whole Cosmos wave realized ~$5.72M of ~$70M nominal; Tectonic
$120M drain tx but ~$114M frozen by chain halt.

**Abstract class:** headlines use pre-exploit nominal value; actual attacker profit is
bounded by exit liquidity and by the *same* price collapse the exploit causes.
Not a vulnerability class by itself — a severity-calibration lens. When we write
findings, impact should be honest about realizable value; when we read the news, don't
multiply nominal by price.

---

## Ranking: what's most likely to show up in OUR audit targets (small, new EVM)

1. **P3 (cap/CF vs balance arrival)** — lending/4626 listings of long-tail tokens are
   our exact demographic. Highest prior.
2. **P2 (mirror/stale balance in guards)** — appears in wrappers, escrow, vesting,
   share accounting in any size protocol. The Provenance "informational field read in
   a guard" grep is cheap and high-yield.
3. **P1 (default-state-satisfiable authz)** — cheap to test (fresh-account pass).
4. **P4 (self-referential valuation)** — only when target is a lending fork; then it's
   the first thing to check.
5. **P5/P6/P7** — mostly chain/infra/hardware; context for what to distrust, not
   usually in-scope for an EVM contract pass — EXCEPT the general lessons
   (single-verifier trust, dependency versions, disclosure).

## Concrete checklist additions (merged into CHECKLIST.md separately)
- Authz predicate false for fresh/empty account; cost-to-pwn ∝ value protected
- Stale/informational storage fields must never gate authz
- Balance mirrors: sync arithmetic guarded; invariant mirror == source after every op
- Caps count every balance-arriving path (direct transfer to market contract!)
- CF sized to depth & feed deviation, not price
- Exchange-rate formula: can one actor inflate any numerator term? Per-market caps on max-borrow?
- Quorum counts enabled signers; empty/nil signer sets rejected; dedup keys bound to signed data
- No silent entropy fallbacks; #ifdef value-checked
- Dependency/module versions pinned + upstream advisory status known

## Sources
- Per-incident receipts in POSTMORTEMS/*.md (provenance, cosmos-evm, moonwell, tectonic, coldcard, term-finance entries)
- Context: rekt.news Drift/Term/Harmony/AFX/Coldcard investigations; Galaxy (KelpDAO); BlockSec Aug newsletter; PeckShield Aug recap; Cosmos Labs postmortem Aug 28; crypto.news/BeInCrypto cluster coverage; Bubblemaps Nesa trace
