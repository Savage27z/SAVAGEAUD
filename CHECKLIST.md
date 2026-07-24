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
- [ ] Division by zero guards
- [ ] Integer overflow (pre-0.8 Solidity)
- [ ] Share ratio manipulation — can the P/N ratio be skewed?

### Randomness / Oracles
- [ ] On-chain randomness source (predictable?)
- [ ] Oracle manipulation (flash loans + spot price)
- [ ] Stale price data
- [ ] TWAP manipulation feasibility
- [ ] Oracle fallback — what happens if the oracle reverts?
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
