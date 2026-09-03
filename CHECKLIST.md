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
|| DefiLords | ERC-4626 vault suite — yield reserve must be EXCLUDED from totalAssets() (double-counting), accRewardPerShare must update BEFORE minting fee shares (phantom rewards), deployIdle must exclude yield reserve from deployable amount, use revert not assert() in vault solvency checks (gas-efficient recovery), adapter switch must withdrawAll() first (crash share price otherwise)
