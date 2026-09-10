# Vulnerability Checklist

Check every target against this list. Update as new vulnerability angles are discovered.

## ✅ Checked on Every Target

### Access Control
- [ ] `onlyOwner` / modifiers on every state-changing function
- [ ] Initializers guarded (can't be front-run or re-called)
- [ ] Role assignment — can non-admins grant themselves roles?
- [ ] Proxy admin — who controls upgrades?
- [ ] Immutability — can the contract be upgraded or parameters changed?

### Reentrancy
- [ ] ReentrancyGuard on external-facing state-changing functions
- [ ] CEI (Checks-Effects-Interactions) pattern
- [ ] Cross-function reentrancy (state read before write)
- [ ] Read-only reentrancy (view function returns inconsistent state)
- [ ] Callback tokens (ERC-777/ERC-1363) — can token transfer trigger reentrancy?

### Math & Accounting
- [ ] Rounding direction — does it favor the user or the protocol?
- [ ] First-depositor inflation (seed to dead address?)
- [ ] Donation attacks — can PPS be inflated without minting shares?
- [ ] Fee-on-transfer / rebasing token compatibility
- [ ] **Prepaid rounding dust** — when user deposits are divided across rounds/blocks via integer division, is the rounding surplus recoverable by the user? (See MinePea AutoMiner — dust trapped when all rounds execute and `stop()` doesn't refund)
- [ ] Division by zero guards
- [ ] Integer overflow (pre-0.8 Solidity)
- [ ] Share ratio manipulation — can the P/N ratio be skewed?

### Randomness / Oracles
- [ ] On-chain randomness source (predictable?)
- [ ] Oracle manipulation (flash loans + spot price)
- [ ] Stale price data
- [ ] TWAP manipulation feasibility
- [ ] **Price deviation checks** — are BOTH directions protected? (one-directional check = vulnerability, see MinePea Treasury)
- [ ] **Swap price limit** — is there a `sqrtPriceLimit` on swaps? `MIN_SQRT_PRICE + 1` = no effective limit
- [ ] **Permissionless price-sensitive ops** — can anyone trigger operations that depend on oracle/price data?
- [ ] **Pin/window mechanisms** — time-bounded operations verified on-chain (call with boundary timestamps to confirm revert behavior)
- [ ] **Historical price fallback** — does the oracle support `priceAt(timestamp)` for accurate historical data?
- [ ] **Permissionless oracle game theory** — can a reporter manipulate settlement windows? Can dispute economics be gamed?
- [ ] **Settlement-by-absence** — what happens if no one disputes within the window? Is there a fallback?

### Upgrades
- [ ] Storage collision risk
- [ ] Uninitialized implementation (can it be self-destructed?)
- [ ] Timelock on upgrade path

### External Calls
- [ ] Unchecked return values
- [ ] Arbitrary call targets
- [ ] Gas exhaustion via external calls
- [ ] Returndata bomb protection
- [ ] SafeERC20 used for token transfers
- [ ] **Raw ETH `.call` in callback functions** — if the callback isn't `nonReentrant`, a `.call{value: X}("")` inside it lets the recipient re-enter the contract before state finalization (see MinePea GridMining `quiverCallback` → `_fulfillRandomness` → `_safeTransferETH(feeCollector, ...)`)
- [ ] Callback ignored on failure — does settlement depend on callback outcome?

### MEV / Front-running
- [ ] Slippage protection on user entry points
- [ ] Deadline/timelock on user actions
- [ ] Sandwich vulnerability on AMM interactions

### Gambling / Game-Specific
- [ ] Randomness timing — can outcome be predicted before bet closes?
- [ ] Round transition — can bets be placed after close?
- [ ] Winner selection — manipulable weighted selection?
- [ ] Jackpot triggers — can jackpot be forced or prevented?

### Async Operations (Keeper-Driven)
- [ ] Two-stage settlement — can a user's funds be stuck between stages?
- [ ] Keeper griefing — can keeper skip execution to cause losses?
- [ ] Keeper trust — what can a malicious keeper do within bounds?
- [ ] Deadline/grace period — what happens after timeout?
- [ ] **Access-controlled endpoints** — can a non-keeper trigger settlement functions?

### Clone / Factory Systems
- [ ] Clone initialization — can clones be front-run or self-destructed?
- [ ] Storage collision between implementation and clone
- [ ] Factory access control — who can mint new clones?

### Handler / Module Architecture
- [ ] Handler upgrade path — can a malicious handler be installed?
- [ ] Cross-handler state consistency
- [ ] Router/call dispatch — can arbitrary handler calls be injected?
- [ ] `delegatecall` / `universalCall` paths — can arbitrary code execution be injected?

### Sequencer / Operator Trust
- [ ] **Single-EOA sequencer key** — can a compromised sequencer drain funds? Can they match orders at manipulated prices?
- [ ] **Sequencer role separation** — is there a separate key for matching vs settlement vs withdrawal?
- [ ] **Off-chain matching** — can the sequencer front-run user orders? Can orders be censored?

### General
- [ ] Keeper dependency — what happens if keeper stops?
- [ ] Emergency pause — can funds be withdrawn while paused?
- [ ] Self-destruct / force-feeding risks
- [ ] Recoverable funds — stuck tokens rescue path
- [ ] **No-owner / fully permissionless** — verify game theory is sound without admin oversight

### Trust Model (TMAAR) — Macro-inspired
- [ ] **Actors enumerated** — every role (owner, user, vault manager, resolver, relayer, bridge) documented with trust level
- [ ] **Assumptions explicit** — every "we assume X" has a "what if X fails?" answer
- [ ] **Accepted risks documented** — what the protocol says is out of scope (not assumed, said)
- [ ] **Owner power enumerated** — what exactly can owner do? Timelock? Multisig? Single key?
- [ ] **Dependency trust** — every external dependency (bridge, oracle, relayer) has documented failure mode

### Bridge / Cross-Chain — Macro-inspired
- [ ] **Source verification** — bridged tokens verify origin chain and contract (prevent fake token injection — see Sapience C-4)
- [ ] **CREATE3 salt uniqueness** — deterministic addresses include source token address in salt
- [ ] **Bridge pause mechanism** — can bridge be paused if remote chain has issues?
- [ ] **Replay protection** — cross-chain messages unique per chain, can't be replayed
- [ ] **Settlement finality** — does bridge wait for sufficient confirmations?

### Signatures & EIP-712 — Macro-inspired
- [ ] **Domain separator uniqueness** — does domain separator include contract address and chain ID? (prevents replay across wallets/chains — see Compound H-1)
- [ ] **Dynamic params hashed** — EIP-712 requires `keccak256` hashing of dynamic types before encoding (see Compound M-1)
- [ ] **Session key revocation** — can session keys be revoked on-chain before expiry? (see Sapience M-2)
- [ ] **Nonce management** — sequential vs random nonces. Can collisions prevent user from making multiple txs? (see Sapience M-3)
- [ ] **msg.value in signature** — is ETH amount part of the signed message? If not, can attackers grief with 1 wei? (see Compound M-2)

### Recurring Patterns from the Aug–Sep 2026 Exploit Wave
*(See POSTMORTEMS/pattern-trace-2026-09.md for full mapping + sources)*

**Authz / state (Provenance, Term)**
- [ ] **Default-state authz** — for every access predicate, test with a fresh/empty account: predicate MUST be false when the caller has done nothing (Provenance: `0 == 0` self-admin; "hold 100% of supply" where supply = 0)
- [ ] **Stale/informational fields in guards** — any storage field not updated on ALL lifecycle paths (non-fixed markers, cached supply) must never gate authz; read the live source of truth instead
- [ ] **Quorum/participation denominator** — measured against the right total (active/wrapped vs total shares); can the entire electorate be cornered cheaply? (Term: ~0.5 ETH = 90% voting power)

**Balance mirrors & sync (Cosmos EVM cluster)**
- [ ] **Two sources of truth** — where a balance/supply is mirrored (bank↔EVM, wrapper↔underlying, locked↔spendable), audit the SYNC arithmetic: unguarded subtraction = underflow to 2²⁵⁶; overflow transfers redistribute real balances
- [ ] **Mirror invariant** — mirror == authoritative after every state-changing op, including delegate/lock/stake/transfer-in paths; test sync with boundary deltas (1 wei over/under)
- [ ] **Address-assumes-status** — can a precomputed future address be converted into a privileged account type (vesting) before the contract exists there?

**Lending params (Moonwell, Tectonic)**
- [ ] **Caps count every balance-arriving path** — direct ERC-20 transfer to the market/token contract bypasses deposit-path caps but still counts as collateral (Moonwell: 53.4M MAMO transferred in, not supplied)
- [ ] **CF sized to depth, not price** — collateral factor × real DEX depth: would $2M move price 40x? (then CF must be tiny); cross-check vs feed deviation bounds
- [ ] **Exchange-rate self-debt** — can one actor's borrows inflate the numerator of the token they post as collateral (Compound-v2 family rate = (cash+borrows−reserves)/supply)?
- [ ] **Whole-market single-call exits** — per-market cash caps on `borrowMax()`-style sweeps

**Verifier/quorum logic (KelpDAO, AFX, Harmony)**
- [ ] **Single-verifier trust** — 1-of-1 DVN/relayer/watcher = single point of failure; dispute windows are useless vs compromised signers
- [ ] **Quorum counts enabled signers** — empty/nil signer bitmaps and all-zero aggregate sigs must be rejected (Harmony); threshold met by few hot keys = key risk, not contract risk
- [ ] **Dedup keys bound to signed data** — receipt spent-markers must derive from fields covered by the signature, not unauthenticated fields (Harmony cross-shard replay)

**Entropy / infra (Coldcard)**
- [ ] **No entropy fallback** — security-critical randomness must fail closed, never route to a PRNG (Coldcard: `#ifndef` on a macro defined-as-0)
- [ ] **Dependency module versions** — pin + verify shared/upstream module versions and advisory status (Cosmos EVM: fix on main May 13 ≠ fixed in prod; silent backport + vague notes = countdown)

## 📝 Added per Target

| Target | New insights / checklist items added |
|--------|--------------------------------------|
| Quiver Protocol | Rounding quantification (1 wei max) |
| SLVR | Randomness safety buffer, Fenwick tree integrity |
| Index | Router safety invariants, returndata bomb protection |
| Moonvault | Standard Beefy fork, no novel findings |
| Basalt Vault | Cross-system pricing (E8/E18/E28), async settlement grace, universalCall delegatecall path, clone factory initialization |
| Cleave | Oracle pin window verification (time-bounded operations), historical TWAP fallback safety, permissionless pin as feature not bug |
| OBSDN | Single-EOA sequencer key risk, sequencer role separation, off-chain matching trust model, multi-collateral pricing, async settlement in perp DEX |
| openOracle | Permissionless oracle game theory, settlement-by-absence, self-dispute economics, no-owner architecture, callback gas grief protection |
| SukukFi | Already Code4rena audited — no new checklist items from solo review |
| Macro Library (Sapience-1) | Payout proportional to wager share (not 1:1), settlement check before mint, withdrawal overflow guard, bridge CREATE3 salt origin check |
| Macro Library (Sapience-1) | Session key on-chain revocation, permissionsHash enforcement, random nonces over sequential |
| Macro Library (Compound-1) | EIP-712 domain separator per-wallet, dynamic type hashing in structHash, msg.value signature inclusion |
| Macro Library (Silicon-2) | Staker reward distribution correctness, NFT staking state consistency, marketplace listing integrity |
| Sentry | Launchpad factory — proxy upgrade path (TransparentUpgradeableProxy + separate ProxyAdmin as contract), LP permanent lock (no withdraw/transfer), TsunamiPoolManager trust for initial pricing, fee routing split (65/35), try/catch pool creation safety, reentrancy guard on all external functions |
|| MinePea | Full-stack gamified mining — Pyth VRF integration, 60s round game loop, cross-contract mint-before-settlement-flag fragility, AutoMiner executor centralization (Random/All strategies), short 60s TWAP on Treasury buybacks with no swap price limit (`MIN_SQRT_PRICE+1`), one-directional TWAP deviation check (only blocks overpriced buys), quiverCallback re-entry vector via feeCollector raw `.call`, AutoMiner rounding dust trap in stop(), CEI pattern verified across all 5 contracts |
| Ravenhood | Simple deflationary treasury — Vault `claimBurn()` has no slippage protection (`amount0Min: 0`), no on-chain buyback automation (off-chain only), Vault owner ≠ DAO wallet (two trust anchors), StakingPool `emergencyRewardWithdraw()` CEI ordering zeros user pending rewards, RVH token ownership renounced (supply permanently fixed) |
|| Peeps | Bonding curve launchpad with native token ($PEEPS) — LP Fee Vault `onERC721Received` auto-registers arbitrary NFTs (mapping corruption via crafted `data`), router/migrator single points of centralization, sell can reverse graduation phase, factory parameters start unset at construction, curve math verified sound |
|| HoodBets | Prediction market — resolver centralization (single address decides ALL outcomes), no refund deadline for unresolved resolver markets, fee-on-buy reduces effective pool 6%, buyShares lacks nonReentrant, trading halt locks users 30min before settlement |
|| Hood Index | Immutable MAG7 index — ERC-4626 vault with hard-coded 10bps fee cap, no upgradeability, no admin withdrawal, 1% effective slippage gap on Uniswap swap, caller-provided swap routes (MEV-directable), max 80h staleness window on NAV |
|| STEEL | Gamified mining fork — owner redirects staker rewards (changeable veSteel address), jackpot odds from same drand randomness, auto-subscribe grief via permissionless keeper, carry accumulators unbounded, integer division dust in auto-subscribe escrow |
|| Run Money | **New checklist item (Math & Accounting → Share ratio manipulation, part 2):** when a function freezes a snapshot into storage on one state transition (e.g. `flag: false→true` stores `currentBalance` into a mapping and adds it to a running total), always check the REVERSE transition (`true→false`) subtracts the SAME STORED SNAPSHOT — not a fresh re-read of the live/current value. A fresh re-read on the reverse path is a near-invisible bug (both branches "look" symmetric at a glance, same variable name used both places) that corrupts a SHARED total from ordinary usage, no attacker required, and can silently underflow-revert or zero out accounting for every other party sharing that total. Grep for any `mapping(id => uint) frozen; total += x; ... total -= y;` pattern and verify `x` and `y` are the literal same read, not independently-computed "current state."
|| Run Money | **New checklist item (Math & Accounting → Share ratio manipulation):** a value-weighted distribution (yield/rewards split proportional to a balance) that snapshots the weight from a LIVE, freely-mutable balance at a single unprotected instant — with no minimum holding period, no time-weighted averaging, and no re-validation before payout — lets anyone temporarily inflate that balance right before the snapshot, then withdraw immediately, and keep the oversized weight for the rest of the period. Check for this pattern anywhere a `mapping(epoch/round => weight)` is set once from `currentBalance` inside an admin/oracle-triggered function, with a separate free `withdraw()` that doesn't touch the snapshot. Doesn't require a flash loan if the snapshot window is wide (e.g. weekly epochs) — just capital for however long it takes to get caught by one triggering call.
|| death.fun | **New checklist item (Signatures & EIP-712):** when multiple functions in the same contract follow a "backend signs a message, user submits it" pattern, check that EVERY such function binds `msg.value` into its signed hash if it's `payable` and the value matters (not just the deposit-creating one) — an inconsistency between two structurally similar functions (one binds it, one doesn't) is a real anti-pattern to grep for. Also check EVERY signed-message function for a used-signature/nonce tracking mechanism — a missing deadline-only gate (no consumption) means any valid signature is replayable an unlimited number of times within its window, not just a single-use mismatch. **New chain-tooling item:** zkSync-family L2s (Abstract, zkSync Era itself, etc.) compile to zkEVM bytecode via zksolc — standard Foundry fork execution can't run it; verify via `foundry-zksync` or fall back to source-level + live read-only verification (see CHAIN_INFO.md → Abstract).
| death.fun | **New checklist item (Reachability reasoning — this one cost a retraction, read it):** three separate traps, all hit on the same finding. **(1) On a native-AA chain, `tx.from` is the ACCOUNT, never the signer** — session keys, relayers and paymasters all produce transactions that look like the user's, so `tx.from == subject` proves *whose account*, never *who ordered it*. 7,329 on-chain calls "from players" looked like proof of player-submission and were not; the real answer required reading the client for signature handling. **(2) A negative string-grep is not proof.** Searching the bundle for `serverSignature` returned 20 hits, all inside ABI definitions, zero in behaviour — decent, but it would miss a signature returned under a different field name. The conclusive check is what the client *destructures out of the response*: here `let { preliminaryGameId } = await res.json()` reads exactly one key, so a signature cannot be received. Look for the response-body destructuring, plus a `*_pending` status poller — that shape ("client asks, something else signs and submits, client polls") is the fingerprint of backend-submitted calls. **(3) "The feature gets used a lot" ≠ "an outside party can reach it."** A session-key grant (`valueLimit: Unlimited`) for a function proves the *server wallet* is permitted to call it; it is not a capability handed to the player, and the signature still only exists on the server. Rate *external reachability*, not usage frequency — they are different axes and conflating them flips Likelihood from Low to High wrongly. |
| death.fun | **New checklist item (tooling — false positives in your own detector):** an automated "did I find a signature?" scanner whose field-name pattern includes a key from its own log schema (e.g. `"note":` in the capture format) will fire on its own output and report a finding live that is not. A detector that can't stay quiet is worse than none, because it manufactures exactly the escalation the retraction was meant to prevent. Scan only app-origin payloads (response bodies + inbound websocket frames), exclude your own RPC reads, and pin BOTH a negative control and a positive control (plant a real 65-byte signature and a real function selector — confirm it fires) in a self-test before trusting a "clean" result. Also leave the compiler/consumer codegen script deterministic: encode the same calldata twice and assert byte-identity. |
|| Moocon (Solana, in progress) | **Non-EVM recon pattern**: closed-source Anchor program with no on-chain IDL — pull the `programData` account raw bytes (owner = BPF Upgradeable Loader) and extract printable ASCII runs; Anchor/Borsh compile every instruction name, account name, and `require!()` error string as a literal, recovering the full instruction/account/error surface without any decompilation. Then cross-check which pubkeys sit at which byte offsets in live state accounts (`getProgramAccounts` + raw `getAccountInfo`) against known addresses (upgrade authority, keeper bot) — this can PROVE centralization facts (e.g. upgrade authority == round-authority field) without needing the source at all. Also: block-explorer instruction-name decoding (Solscan) can be flat wrong for unverified programs — always verify against raw `getTransaction` `logMessages`.
|| DefiLords | ERC-4626 vault suite — yield reserve must be EXCLUDED from totalAssets() (double-counting), accRewardPerShare must update BEFORE minting fee shares (phantom rewards), deployIdle must exclude yield reserve from deployable amount, use revert not assert() in vault solvency checks (gas-efficient recovery), adapter switch must withdrawAll() first (crash share price otherwise)
|| death.fun | **New checklist item (tooling — a clean result is only evidence if the detector can fire, and only for the shapes it parses):** the same pre-reveal probe reported "no leak" twice for two different reasons. First it was a false positive (its pattern matched its own log schema). Then, after that fix, it was a **false negative**: its parser read only `{currentGame}/{game}/{games[0]}`, so when the app returned the decisive data nested at the top level as `{currentRow, nextRow}` it never looked there and still said "clean". **Two rules: (1) every negative-result detector ships with synthetic POSITIVE fixtures proving it fires — if you cannot make it fire on a planted leak, its "clean" is worthless; (2) enumerate every response SHAPE the app can return for that endpoint (poll vs action-response vs websocket frame vs settlement) and cover each one, or state explicitly which shapes were not covered.** Prove the fix too: re-run the new fixtures against the old detector from `git show HEAD:…` and record that it FAILS (v1 5/6 vs v2 6/6). |
|| death.fun | **New checklist item (provably-fair / verifiability claims — check the tool, not just the mechanic):** when a protocol ships a "provably fair — verify it yourself" verifier, the highest-value cheap check is to push the protocol's OWN on-chain commitments through the protocol's OWN verifier code before auditing anything else. Two independent failure modes found in one pass: **(a) constant drift** — the published verifier hard-coded `HOUSE_EDGE = 0.05` while the deployed app committed with `.04`, *and* the verifier hashed raw floats while the app rounded to `1e8` before hashing, so the verifier reproduced **0 of 706** standard real games (a false fraud signal pointed at their own users); **(b)** ~~commitment coverage — 143 settled games committed `rowConfig: []`~~ **RETRACTED: those were a different game mode, where `rows: []` is the documented-correct format (their own verifier: `// Use 0 for games without rows (like dice)`). See the classification row below.** Always ask: *does the committed payload actually constrain the outcome, and does the tool reproduce it?* Do it against production data at scale — and compute it in the target's own language (see the float row below). The verified positive here is worth as much as the defect: 706/706 standard games reproduce, commit-to-play board identity holds 706/706, and a pick-vs-reconstructed-skull test over 706 real games has **0 contradictions**. |
| death.fun | **New checklist item (CLASSIFY YOUR POPULATION BEFORE YOU ANALYSE IT — this one produced a false finding and a retraction):** one settled-games dataset silently contained **three different game modes**, and I ran all of it through the death_race algorithm. 706 were death_race; 143 were a mode with no rows (where `rows: []` is the correct commitment, not a bug); 49 were a coordinate-grid mode. **`gameType` was not in the on-chain struct, so the dataset looked homogeneous and I never asked whether it was.** The tell was sitting in plain sight the whole time: pick indices of 9–12, when death_race rows have at most `MAX_TILES = 7` tiles so indices cap at 6. **Rules: (1) before analysing a population, prove it is ONE population — histogram the inputs and look for bimodal/out-of-range clusters; (2) treat an out-of-range value as a CLASSIFICATION signal, not as noise or as evidence of a bug; (3) if the record type has no type field, derive the mode from behaviour (value ranges, data shapes — flat ints vs nested pairs) before running any mode-specific algorithm.** A wrong classify step turns "these 143 games are a different game" into "these 143 games prove nothing" — same data, opposite conclusion. |
| death.fun | **New checklist item (JS targets: do hash work in JS, not Python):** reproducing a commitment from a JavaScript codebase requires JS float semantics. Python `round(o*1e8)/1e8` + `json.dumps` disagrees with JS `Math.round(o*1e8)/1e8` + `JSON.stringify` on **55 of 706** games here (different half-rounding rule, different float-to-string), which produced a bogus "651/706 reproduce" and a bogus "55 games where the committed board ≠ the board played". Both were language artifacts, not chain facts. **Any hash-reproduction or commitment-verification claim about a JS target must be computed with node using the target's own arithmetic**, and a Python/JS spread is itself a signal you are comparing the wrong things. Also: a hash comparison is binary — a 92% match is not "close", it is 92% wrong. |
| death.fun | **New checklist item ("the client is the only bound I can find" ≠ "there is no server-side bound" — this nearly shipped a Critical on an argument from absence):** the create-game body is client-built (`{betAmount, rowConfig: rows.map(e=>e.tiles)}`), the only bound found anywhere in the client was a UI toast, the on-chain history showed all 370 sampled death_race boards inside `[2,7]`, and the contract validates *nothing* — so `rowConfig` looked unvalidated and `tiles=0` would make `sha256(seed-rowN) % 0 → NaN`, i.e. a guaranteed win. **It was fully validated server-side.** One authenticated request settled it: the server returns a per-element zod schema error — *"Each row must have at most 7 tiles"*, *"at least 2 tiles"*, *"expected int, received number"*, *"Must have exactly 25 rows."* **Rules: (1) absence of evidence in the client, in on-chain history, and in the contract is NOT evidence that the server is missing a check — mark it OPEN, never Critical-if; (2) with an authenticated session, PROBE THE ENDPOINT: a schema-driven 400 enumerates the real validation in one call, which is worth more than any amount of client-side reading; (3) on-chain history is a terrible oracle for this — legal values only prove nobody tried, illegal values may belong to a different code path (see the classification row above).** |
| death.fun | **New checklist item (reproducing an authenticated endpoint: get the request SERIALISER right, or you will misread a "field not received" error as "field not validated"):** this app sends bodies wrapped in **superjson** (`{"json":{…},"meta":{"values":{"betAmount":["bigint"]}}}`) because `betAmount` is a bigint. Posting plain JSON produced `400 … "betAmount":{"_errors":["expected bigint, received undefined"]},"rowConfig":{…"expected array, received undefined"}` — which reads as *"neither field is validated"* and is in fact *"your body was never parsed"*. The same wrapper appears in the RESPONSES (`{"json":{…}}`), which is the tell. **Rules: (1) when a client uses a custom serialiser (superjson, BigInt/Date markers, `{"json":…}` envelopes), sniff the response shape and mirror it in the request; (2) if a required field reports `undefined` rather than a type error, suspect the envelope, not the schema; (3) always send a deliberately-invalid-but-well-formed control (here: valid board with `betAmount = 1 wei` → *"Bet is below the minimum"*) to prove your request actually reaches field-level validation before you conclude anything from a rejection.** |
| death.fun | **New checklist item (opening a session without a browser — the full decision tree, so it is not re-walked):** when login is a hard blocker, work DOWN this list and record which rung closed it. **(a) Does the app ship its own auth?** Often no — here the `/api/v1/auth/nonce\|verify-signature\|token` PKCE flow in the bundle belonged to a third-party SDK (Terminal) pointing at a different server; grep for the base URL before assuming ownership. **(b) Read the IdP's PUBLIC app config.** `GET https://auth.privy.io/api/v1/apps/<appId>` returns the real `wallet_auth` / `email_auth` / `guest_auth` / `captcha_enabled` / `*_oauth` flags — it cost 30 seconds and immediately killed four routes (needs a browser User-Agent; a Python UA gets Cloudflare 1010). The app id itself is inlined in the client bundle as `NEXT_PUBLIC_*`. **(c) Check the cookie name empirically**: inject the token under candidate names and look for any response that ISN'T the generic "missing token" error — `privy-id-token` gave a 500 while every other name gave `missing jwt`, i.e. the name was right and the token type was wrong (access token vs ID token — Privy stores both). **(d) Accept the wall.** Here the captcha host is genuinely IPv6-only with no IPv4 origin (**522 on every Cloudflare edge**; the IPv6 address maps to an IPv4 whose edge serves a valid cert and then fails), so no browser on the host can pass it — and defeating a captcha is out of scope regardless. **(e) The cheapest unblock is one cookie value from a human**, not a whole probe script — you then run everything yourself and can iterate. |

## death.fun wave — added 2026-09-10 (F07)
- **Free enum oracle**: to test whether a value is accepted WITHOUT creating the resource, send it with a
  value that trips a LATER validator, then read WHICH field the error lands on. An error on a later field
  proves the earlier field passed. Used to map the live game-mode surface ($0) and to find the stored
  `version` of a finished game (brute-force the one value that yields a DIFFERENT error depth).
- **Validation order is itself evidence.** On `select-tile` the check order is schema → game lookup →
  `tileIndex` bound → version; the bound fires for every version value, which proves it precedes version.
  Establishing order is what let the pick-path tests run against a *finished* game for free instead of a live one.
- **A hash that doesn't match the commitment is not automatically a finding.** `commitmentHash` (API) ==
  on-chain `gameSeedHash` == verifies against the revealed seed. The create response's separate `hash` is
  neither. Confirm WHICH value the verifier consumes before calling a mismatch a fairness break.
- **Per-mode commitment row shape** — get the JSON key order right or you will manufacture a false
  MISMATCH: death_race `{tiles, deathTileIndex, multiplier}`; laser_party `{tiles, dimension, deathTileIndex,
  multiplier}`; both under `{version, rows, seed}`.
- **Guessable ≠ exploitable.** `version` is a small counter (1 + actions) but equality-enforced, so knowing
  it grants nothing. Check the comparison, not just the entropy.
