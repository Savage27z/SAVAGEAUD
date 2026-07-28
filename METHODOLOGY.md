# Methodology

## Cold Pickup Instructions

Any agent reading this for the first time should do the following:

1. **Read `RULES.md`** — non-negotiable constraints (5 minutes)
2. **Read `CHECKLIST.md`** — vulnerability classes to check on every target (10 minutes)
3. **Read `CHAIN_INFO.md`** — RPCs and quirks for chains you'll work on (5 minutes)
4. **Read `QUICKSTART.md`** — how this repo works and what you need to do (5 minutes)
5. **Check `README.md`** — which targets are done, which are pending
6. **Find the next target** — use DefiLlama + Twitter. One pick at a time. Show user.

**Key rule you must not break:** Every target gets at least 2 focused passes from different attack angles before you call it "clean." One read-through is never enough.

## Division of Labor

- **Agent (breadth):** Find targets, read code, flag suspicious assumptions, quantify edge cases
- **𝖲𝖠𝖵𝖠𝖦𝖤 (depth):** Verify exploitability on a local fork, write reports, disclose privately

## Workflow

### 1. Target Selection
- Search DefiLlama, DexScreener, Twitter for small fresh protocols
- Filter: <$5M TVL, <30 days old, EVM, reachable team, no published audit
- Vet team via X/Twitter (followers, posting frequency, responsiveness)
- Present options to user before diving into code

### 2. TMAAR — Trust Model, Assumptions & Accepted Risks (BEFORE code reading)

> Inspired by Macro (0xmacro) audit methodology. Understanding who/what you trust is the highest-ROI step before reading a single line of code.

Before touching the source, document the trust model in `TARGETS/<name>/TMAAR.md`:

#### Actors & Trust Level

| Actor | Trust Level | Can Do | Mitigation if Compromised |
|-------|-------------|--------|---------------------------|
| Protocol owner/admin | High / Medium / None | Upgrade, pause, withdraw | Timelock? Multisig? |
| Users | None | Deposit, withdraw, trade | — |
| Vault manager | High / Medium / None | Allocate funds | Can they steal? |
| Oracle/resolver | High (must be correct) | Settle outcomes | Dispute period? Fallback? |
| Relayer/bot | Medium / None | Submit messages, trigger actions | Can they front-run? Grief? |
| Bridge (LZ, CCIP) | High | Relay cross-chain messages | Pause mechanism? |

#### Key Assumptions

List every assumption the protocol makes. Be explicit — these are things that MUST hold for the protocol to be secure:
- Oracle always returns correct prices within X seconds
- Bridge is honest (no message forgery)
- At least one honest relayer exists
- EIP-712 signature verification is correct
- L1 sequencer is online within X minutes

#### Accepted Risks

What does the protocol acknowledge as out-of-scope?
- User runs arbitrary/unaudited scripts (if plugin system)
- MEV / sandwich attacks on public mempool
- Gas griefing via front-running
- Owner upgrades parameters within documented bounds

#### ✅ TMAAR Quality Check
- [ ] Every external dependency has an assumed trust level
- [ ] Every "we assume X" should have a "what if X fails?" answer
- [ ] Owner/admin power is enumerated — not just "can upgrade"
- [ ] Accepted risks are explicit, not buried in docs

### 3. Commit Tracking & Scope Definition

Before reviewing a target, lock in what you're checking:

- **Repo:** `github.com/org/project`
- **Audited commit:** `<commit_hash>` (from chain explorer verification)
- **Final commit (after fixes):** `<commit_hash>` (update after team responds)
- **Contracts in scope:** Full list with SHA256 hashes
- **Explicitly excluded:** Deployment scripts, off-chain infrastructure, frontend, SDK, relayer code
- **Chains covered:** Primary chain only? Cross-chain?

**Why this matters (from Macro):** Without a locked commit hash, you can't say "this bug exists at commit X" — and the team can't prove they fixed it.

### 4. Contract Analysis
- Always pull **verified source from chain explorer** (not GitHub — verify bytecode match)
- Read with these questions:
  - Who can move the money? What gates it?
  - What happens when funds cross contract boundaries?
  - Can a stranger trigger something only the team should?
- Check standard seams: access control, reentrancy, oracles, rounding, upgrades, external calls, MEV

### 5. Static Analysis
- Run Slither on every target
- Categorize findings: false positives vs leads to investigate
- Never submit raw Slither output as findings

### 4. Fork Testing
- Fork the chain locally (`anvil --fork-url <rpc>`)
- Write Foundry tests for basic integration + edge cases
- 8+ test categories: deployment, config, access control, economic invariants, edge cases, reentrancy

### 5. Proving (user's domain)
- Fork the chain locally
- Write Foundry PoC that demonstrates exploit end-to-end
- If it doesn't work on the fork, drop it

### 6. Finding Triage (inspired by BountyForge v2.0)

Before anything goes to reporting, every finding passes through 4 gates:

```
Raw Finding → Gate 0 (Reality) → Gate 1 (Impact) → Gate 2 (Dedup) → Gate 3 (Quality) → Report
```

#### Gate 0: Reality Check (30 seconds)

**Must be real** — confirmed via fork simulation or on-chain call, not speculation.

| Evidence | What Counts | What Doesn't |
|----------|-------------|--------------|
| Fork PoC | Foundry test that demonstrates the path end-to-end | "The code looks like it could..." |
| On-chain call | `eth_call` with boundary conditions proving the behavior | "This pattern is dangerous in general" |
| Code trace | Exact line numbers for the unguarded path | "I read the code and it seems like..." |

**KILL conditions** (drop the finding):
- You haven't run it. Speculation is not a finding.
- "This type of contract is often vulnerable to..." — pattern matching without testing
- Tested only with happy path — need the exploit path
- Ambiguous signal — "the response was different so there might be..."

**Demote conditions** (downgrade to note):
- Real behavior but requires specific conditions that are unlikely
- Real but only informational (no fund movement)

#### Gate 1: Impact Validation

**The Impact Litmus Test:**

> "An attacker can **______** , resulting in **______** ."

- **PASS:** "An attacker can steal all user deposits by calling `redeem()` with a crafted shares value, resulting in loss of $73K in protocol TVL."
- **FAIL:** "potentially access funds", "theoretically could", "could be used in a chain" (build the chain first)

**Impact Tiers (Macro-inspired):**

| Severity | Criteria | Examples | Action |
|----------|----------|----------|--------|
| Critical | Funds **will** be lost or permanently locked | Drain all TVL, mint unlimited tokens, brick contract | Must fix |
| High | Very bad — funds/assets at serious risk | Drain specific users, steal all fees, grief all withdrawals | Must fix |
| Medium | Severe impact but not existential | Drain dust, grief specific users, temporary DoS | Should fix |
| Low | Small risk, optional fix | Non-exploitable edge case, informational rounding | Optional |
| Code Quality | No security risk, improves DX | Inconsistent error handling, naming, conventions | Note |
| Gas Optimization | Meaningful gas savings | Redundant reads, loops, storage patterns | Note |
| Informational | Minor observation | Comment improvement, unused imports | Note |

**Common inflation to reject:**
- "Owner can steal" ⮕ design choice unless there's a trust-minimization angle (RULES.md #6)
- "Reentrancy" without a concrete fund-movement path ⮕ not a finding
- "Centralization risk" without exploitability ⮕ informational at best

**Impact × Likelihood Matrix (Macro-style):**

Every finding should be assessed on TWO axes, not just severity:

| Impact ↓ / Likelihood → | Low | Medium | High |
|-------------------------|-----|--------|------|
| **Critical** | High | Critical | Critical |
| **High** | Medium | High | Critical |
| **Medium** | Medium | Medium | High |
| **Low** | Low | Low | Medium |

**Likelihood criteria:**
- **Low** — Requires specific unlikely conditions, multiple assumptions, or extended time horizon
- **Medium** — Standard exploit conditions (public mempool, typical user behavior)
- **High** — Trivially exploitable with no prerequisites

Document both axes in every finding.

#### Gate 2: Deduplication Check

Search before reporting:
- [ ] Solodit (`https://solodit.cyfrin.io`) — 50K+ searchable smart contract findings
- [ ] Target's changelog / release notes — was this already fixed?
- [ ] GitHub Issues for target repo — search "security", "vuln", bug class
- [ ] Known issues / out of scope page

| Situation | Action |
|-----------|--------|
| Same bug, same root cause | KILL — don't report duplicates |
| Different bug on same surface | CONTINUE |
| Same bug but your PoC proves higher impact | REPORT with escalation language |

#### Gate 3: Report Quality

- **Title format:** `[Bug Class] in [Contract/Function] allows [attacker] to [action]`
- **PoC:** Copy-pasteable Foundry test. Triager runs it and sees the same result.
- **Evidence:** Transaction hash or fork output showing the exploit
- **Minimal:** Shortest sequence of calls that demonstrates impact

### 7. Reporting (user's domain)
- Short and reproducible: what the bug is, what it costs, exact code, exact command to reproduce
- "Do not trust me; run this yourself"
- Send privately. Never disclose while bug is open.

## Target Discovery Sources
1. DefiLlama API — `GET https://api.llama.fi/protocols`, filter by `listedAt > 30 days ago`, `tvl < $5M`, EVM chains, category in [Dexs, Yield, Yield Aggregator, Lending, CDP]
2. DexScreener new pairs — `GET https://api.dexscreener.com/token-profiles/latest/v1`
3. Twitter — search for launch announcements, cross-reference with project handles
4. New chain hunting — recently launched L2s/L3s have fresh unaudited protocols

## Multi-Pass Philosophy

**One pass is NOT an audit.** Every target gets multiple independent passes:

1. **Phase 0: Recon** — Threat model, surface map, trust model, external deps
2. **Phase 0.5: TMAAR** — Trust model, actors, assumptions, accepted risks (mandatory before code)
3. **Phase 1: Read** — Feynman approach: question WHY every line exists
4. **Phase 2: Hunt** — Run through 6-agent checklist systematically
5. **Phase 3: Gap-Hunter Passes** — 3 cross-lens seam scans (see below)
6. **Phase 4: Tools** — Slither + manual triage
7. **Phase 5: Fork tests** — Integration + edge cases
8. **Phase 6: Deep dive** — Second focused pass from a completely different angle

## Attack-Framing (adapted from Pashov Audit Group v3)

**You are an attacker, not a reviewer.** This is the single most important mindset shift in the methodology:

- **When you find a bug, deepen the attack** — chain it, find more victims, lower the precondition cost. Refutation belongs to the judging phase, not the hunting phase.
- **A finding is not real until traced with concrete values.** No proof means LEAD, not FINDING. Leads are not failures — they are honest calibration.
- **Catalog scanning is not the product.** Pattern catalogs (reentrancy, oracle manipulation, etc.) are reference material. A pure catalog sweep produces volume without depth.

## Gap-Hunter Methodology (from Pashov Audit Group v3)

After the standard multi-agent passes, run **3 gap-hunter passes** targeting bugs at the seams between lenses. These are bugs NO single-lens scan can find because the exploit only emerges when two or more lenses interact.

### Pass 1: Flow Gap

**Seams:** execution × periphery × first-principles

What you're hunting:
- **Seam 1 — execution × periphery:** A control path that's internally correct but whose downstream periphery call returns something that derails the trace (e.g., fee-on-transfer token, rebasing, blacklist)
- **Seam 2 — periphery × first-principles:** An external interaction safe in isolation but that defeats the protocol's stated purpose when chained (e.g., safe `safeTransferFrom` to a rebasing token violates "users always receive at least X")
- **Seam 3 — execution × first-principles:** An execution path that completes without reverting but whose end-state contradicts protocol intent (e.g., `loan.repaid == true` but `loan.collateralLocked == true`)
- **Seam 4 — three-way:** All three at once

**Look for:**
- A trace that computes a value BEFORE a periphery call and uses it AFTER
- Multi-step operations where steps are individually correct but combined end-state breaks semantics
- Callbacks/hooks that move control mid-flow, and post-callback code assumes pre-callback state
- Delta-check patterns (`received = balance_after - balance_before`) followed by `>= amount` — reverts on fee-on-transfer even on intended flows
- User-controllable identifiers keying a refund/state map without occupancy checks
- Cross-chain message handlers iterating over user-controlled lengths — bricking delivery

### Pass 2: Trust Gap

**Seams:** access control × economics × asymmetry

What you're hunting:
- **Seam 1 — access × economics:** Function with correct access guard and correct economic formula — but the permitted actor can systematically extract value (e.g., `onlyKeeper` rebalance with `amountOutMin = 0` — keeper sandwiches themselves)
- **Seam 2 — economics × asymmetry:** A formula whose result differs by caller class — and the difference is exploitable (e.g., deposit uses spot, withdraw uses TWAP = deposit cheap, withdraw expensive)
- **Seam 3 — access × asymmetry:** A privileged actor whose action creates asymmetry between users (e.g., `setFeeRecipient` redirects accrued fees instead of crediting old recipient first)
- **Seam 4 — three-way:** All three at once

**Look for:**
- Modifiers allowing a role, where the role's only action calls a function with sandwich-able params
- Paired functions where one uses spot price and the other uses averaged price
- Admin setters that affect pending/in-flight value distribution
- Fee accrual crediting "current" recipients where the set of recipients can be changed retroactively
- Hooks where the recipient is settable but past accruals don't checkpoint

### Pass 3: Numerical Gap

**Seams:** precision × invariant × boundary

What you're hunting:
- **Seam 1 — precision × invariant:** An invariant that holds under exact arithmetic but breaks under integer rounding (e.g., `totalShares == sum(userShares)` drifts silently over N deposits)
- **Seam 2 — boundary × precision:** A formula whose precision behavior changes at input extremes (e.g., `fee = (amount * rate) / SCALE` — at `amount = SCALE/rate - 1`, truncates to zero = free service)
- **Seam 3 — boundary × invariant:** An invariant enforced in the body but skipped on early-return or zero-input fast paths
- **Seam 4 — three-way:** Edge-case input → precision loss → broken invariant

**Look for:**
- Two formulas that should produce equal results but rely on different rounding directions
- An accumulator incremented by truncated quantity, later compared to un-truncated total
- `if (x > 0)` immediately followed by division by `x` that produces zero anyway
- `min`/`max` between values of different scales
- N-segment arithmetic where per-segment constraints hold but the monolithic invariant breaks
- Per-position caps in one unit checked against values computed in a different scale
- A function that approves `out + fee` but consumes `out - fee`, leaving `2·fee` residual allowance per call

### Gap-Hunter Output Format

Every gap-hunter finding must specify:
```
seam: which lenses combine (e.g., execution×periphery / access×economics / precision×invariant)
trace: the call sequence — internal step → interaction → end state
violated_principle: the protocol guarantee that the end state contradicts (flow/trust gaps)
proof: concrete numbers showing the seam (numerical gaps)
```

### vs. Standard Multi-Agent Hunting

| Feature | Standard Multi-Agent | Gap-Hunter |
|---------|---------------------|------------|
| Viewpoint | 6 independent perspectives | Cross-lens seams |
| What it catches | Bugs within a single lens | Bugs BETWEEN lenses |
| Coverage | Reentrancy, access, math, etc. | Flow interactions, trust asymmetries, numerical seams |
| Blind spot | Can't see cross-lens interactions | Can't see single-lens depth |

## Key Techniques (informed by Open-Kritt / Blockian)

### Senior Auditor's Mental Toolkit

Three mandatory tools applied continuously during every code read:

**1. Feynman Test (FIRST — use before anything else)**

When you open any new function or contract, stop and ask: "Can I explain what this does to someone who doesn't know Solidity?" Try it in plain words. The places where your explanation gets fuzzy — where you reach for Solidity jargon instead of plain meaning — are where you're papering over an assumption. That's where bugs hide.

*Example: you read `_handleFeeTransfer(zrc20, fee)` and your explanation comes out as "it transfers the fee." That's not Feynman. Feynman is: "it picks up the protocol's commission off the user's payment and moves it to the treasury wallet." Now keep going: what if the payment is in ETH and the function uses an ERC20 method? Your plain-English explanation breaks. Bug.*

**2. Socratic Questioning**

For every line of code, ask: why is this here? What does it assume? What happens if the assumption breaks? Don't accept "because that's how it's written" as an answer. Drill until you reach the implicit belief the code rests on — usually 2-3 "whys" deep.

**3. Inversion**

Every clean path gets a backward pass. After you understand what the code IS supposed to do, ask: how would I make it NOT do that? Read every check and ask "what value slips past it?" Read every state update and ask "what state am I in just before this?"

### When to Reach for Which Tool

- Opening any new function or contract → **Feynman** (always — before anything else)
- Trying to understand a line you don't yet → **Socratic**
- Something looks too clean → **Inversion**
- You reached a "bug" conclusion → Deepen the attack (chain it, find more victims, lower the precondition cost — do NOT refute it)

### Markers Protocol

When running these tools, emit markers in your output:
- `[Feynman: <name>]` — plain-English explanation
- `[Socratic: <file>:<line> — why?]` — line-level drill
- `[Inversion: <function>]` — 3 concrete attacker moves

These aren't optional. They're how the orchestrator verifies depth, not surface scanning.

### Narrow, Specific Workflows
The narrower and more specific a pass is, the better it performs. Instead of "find all vulnerabilities," run focused passes:
- "Find reentrancy paths in the deposit flow"
- "Check rounding direction in share calculation"
- "Find unprotected initializers"

### Brute Force on Entry Points
Map all entry points × bug classes, then attack each combination. More passes = more results.

### Anchored Deduplication
Process findings in small batches. Merge duplicates into canonical findings, then use those as anchors for the next batch. Keeps comparisons manageable and prevents the same bug being reported N times.

### Relative Ranking
Rating findings in isolation inflates severity. Instead ask: "Which of these two findings is more promising?" — pairwise comparison produces more reliable prioritization.

### Repeats for Enumeration
A second pass often finds entry points and attack paths the first one missed. After completing all phases, run a fresh pass from a different angle.

### On-Chain Verification of Time-Bounded Operations
Some contracts have time-windowed functions (`pin()`, `freeze()`, `commit()`) that only work within certain blocks/timestamps. **Verify these on-chain before reporting:**

1. Compute correct function selectors using `pycryptodome` (`Crypto.Hash.keccak`)
2. Call the function with boundary timestamps (far past, near past, near future, far future)
3. Confirm revert errors match expected behavior (e.g., `"OLD"`, `"FutureTimestamp"`)
4. Simulate the full settlement/operation flow using `eth_call` to verify it doesn't revert with unexpected errors
5. Test fallback paths — what happens if nobody calls the time-bounded function within the window?

Discovered during the Cleave audit: the `PinnableOracle.pin()` appeared dangerous (permissionless price override) but on-chain testing revealed a 6-hour window and a fallback to historical TWAP, making it safe.

### Multiple Models
Different models excel at different tasks. When available, use multiple model backends — one for code comprehension, another for creative exploit construction.

### Learning from Disclosed Reports ("What Changed" Method)

> *"A hunter who reads 10 disclosed reports before hunting finds 3-5x more bugs than one who starts blind."*

The "What Changed" method is the highest-ROI learning technique for smart contract auditing:

1. **Find a disclosed report** for a similar protocol or the same tech stack (EVM, same patterns like ERC-4626, same primitives like Uniswap v4 hooks)
2. **Locate the fix commit** → read the diff to understand exactly what was wrong
3. **Identify the anti-pattern** — what was the developer's mistake? (e.g., using `balanceOf` without checking if the token is fee-on-transfer)
4. **Grep your target's source** for the same anti-pattern
5. **Test every match**

**Where to find disclosed reports for smart contracts:**
- **Solodit** (`https://solodit.cyfrin.io`) — 50K+ searchable audit findings, filter by protocol type and bug class
- **Immunefi** disclosed reports — per-program hacktivity
- **Code4rena** findings repo — all past contest findings
- **Spearbit / Sherlock / Codehawks** — disclosed audit reports

**Pattern extraction framework** — for every report you read, capture:
1. What was the vulnerable endpoint/function pattern?
2. What check was MISSING?
3. What told the auditor to look there?
4. What was the fix?
5. Can you generalize this pattern?

Update CHECKLIST.md with every new anti-pattern discovered.

### Anti-Pattern Library (Live Document)

As we audit targets and learn from disclosed reports, build a shared anti-pattern library. The CHECKLIST.md is where these live — organized by vulnerability class, not by target. Every time you learn something new, add a row to the "Added per Target" table.

Examples (from BountyForge + our experience):
- **Oracle pin windows** — time-bounded functions need on-chain boundary testing before reporting (discovered: Cleave)
- **Single-EOA sequencer** — one compromised key can drain all funds (discovered: OBSDN)
- **Rounding direction** — deposit DOWN, withdraw DOWN = 1 wei max but must quantify (discovered: Quiver)
- **Staged randomness fallback** — if VRF times out, does the fallback source weaken security? (discovered: SLVR)

## Tool Integrations

### EVM Hack Analyzer

**Repo:** `sanbir/evm-hack-analyzer` — https://github.com/sanbir/evm-hack-analyzer

A fully static, in-browser EVM exploit debugger. Fork chain state, replay any transaction opcode-by-opcode, step through with source mapping, annotate vulnerabilities, and share PoCs via ZIP or IPFS. No backend required.

**Uses in our workflow:**

1. **Study historical exploits** — Before auditing a new protocol type, search for similar exploits and replay them in the analyzer. Understand *exactly* how the attack worked before you start reading target code. This feeds directly into the "What Changed" method — you'll recognize anti-patterns faster.

2. **Validate PoC findings** — During Phase 4 (fork testing), if you identify a potential exploit path, replay it through the analyzer. The opcode-level trace confirms whether your mental model of the attack is correct.

3. **Create shareable PoC artifacts** (user's domain) — Export annotated exploit traces as ZIP or IPFS pins. Teams get a self-contained replay that works without RPC or Etherscan keys.

**Requirements:**
- Archive RPC URL (Infura, Alchemy, QuickNode — must serve `eth_getBalance`/`getCode`/`getStorageAt`)
- Etherscan V2 API key (one key works for all supported chains)
- Local setup: `git clone && npm install && npm run dev`

**Ecosystem:**
- evm-hack-registry: Structured hack database
- evm-hack-poc: Community PoC archive
- crypto.training/hacks: Public browsable mirror

## Walking Away
Not every target produces a finding. After a full multi-pass analysis with nothing exploitable, say so and move on. Never inflate severity.

## Combined Methodology — Every Layer Applied

Every target gets the full stack. These aren't optional extras — they're all mandatory:

1. **Macro TMAAR** — Trust model before code reading
2. **Macro Impact × Likelihood** — Two-axis finding assessment
3. **Macro commit tracking** — Lock audited + final commit hashes
4. **BountyForge 4-gate triage** — Reality → Impact → Dedup → Quality
5. **BountyForge "What Changed"** — Read similar disclosed reports before starting
6. **BountyForge anti-pattern library** — Live CHECKLIST.md
7. **Open-Kritt multi-agent** — 6 independent perspectives per target
8. **Open-Kritt narrow passes** — Focused "find X in Y" not "find all bugs"
9. **Open-Kritt brute-force entry points** — Map all entry points × bug classes
10. **EVM Hack Analyzer** — Opcode-level PoC replay

## Repo References
- Open-Kritt orchestration engine: https://github.com/Kritt-ai/open-kritt
- Blockian (Immunefi #18): https://immunefi.com/profile/Blockian/
- BountyForge v2.0 (finding triage, disclosed report learning): https://github.com/Gabson0x/bountyforge/releases/tag/v2.0.0
|- EVM Hack Analyzer (opcode-level exploit replay & PoC sharing): https://github.com/sanbir/evm-hack-analyzer
|- **Macro (0xmacro)** — Elite boutique audit firm. Public audit library (130+ reports) with TMAAR methodology, Impact×Likelihood matrices, and detailed finding writeups: https://0xmacro.com/library
|- **Macro blog — audit methodology lessons:** https://0xmacro.com/blog/how-to-prep-for-an-audit/
