# Methodology — The SAVAGEAUD Audit Playbook

Merged from top AI audit tools recommended by @0x3b33 (Pyro, co-founder @PhageSec, Lead Security Researcher @sherlockdefi). Each phase credits its source.

---

## Phase 0: Recon (from Pashov's `x-ray`)

**Goal:** Build a threat model before reading a single line of code.

1. **Identify the contract surface:**
   - All deployed contracts and their roles (vault, strategy, factory, etc.)
   - Entry points for users (deposit, withdraw, swap, claim, etc.)
   - Entry points for privileged roles (keeper, owner, guardian)
   - Upgrade/migration paths (proxies, timelocks, strategy swaps)

2. **Map the trust model:**
   - Who can move funds?
   - Who can pause/panic?
   - Who can change parameters?
   - Is the owner a multi-sig or EOA?
   - Can any role rug users?

3. **Identify external dependencies:**
   - Oracles (Chainlink, TWAP, custom)
   - Bridges
   - Other protocols integrated (Uniswap, Aave, Morpho, etc.)
   - Tokens with unusual behavior (rebasing, fee-on-transfer, pausable)

4. **Check what's already known:**
   - Has the project been audited? Read the reports.
   - What did the auditors find? What did they miss?
   - Search Solodit (via Claudit) for similar patterns.

**Output:** `TARGETS/<name>/threat-model.md`

---

## Phase 1: Read (from Nemesis — Feynman approach)

**Goal:** Question WHY every line exists. Understand the contract's assumptions before looking for violations.

1. **Start from the verified source on the chain explorer** — never from a GitHub repo that might not match what's deployed. Verify bytecode matches.

2. **Read with the three questions:**
   - **Who can move the money?** Map every function that transfers value or changes balances, and what gates it.
   - **What happens at the risky moment?** Trace every external call. What state was written before? What happens after? Can it re-enter?
   - **Can a stranger trigger something only the team should?** Missing/wrong modifiers, initializers left open, functions that assume an internal caller.

3. **For every function, ask WHY:**
   - Why does this parameter exist?
   - Why is this check here (or not here)?
   - Why this rounding direction?
   - Why this order of operations?
   - What assumption would make this safe — and what happens if that assumption is wrong?

4. **Look for state coupling** (from Nemesis):
   - State variables that are updated in one function but not in another related function
   - Asymmetric assumptions (e.g., "this is always called after that" with no enforcement)

**Output:** Annotated source with questions. `TARGETS/<name>/read-notes.md`

---

## Phase 2: Hunt (from sc-auditor — 6 parallel agents)

**Goal:** Systematically check every vulnerability class. Run these in parallel for each contract.

### Agent 1: Access Control
- Are modifiers used correctly? No missing `onlyOwner` on sensitive functions?
- Can a user call something only the owner should?
- Are role assignments protected?
- Are initializers re-callable (in upgradeable contracts)?
- Timelocks — can they be bypassed?

### Agent 2: Reentrancy (all variants)
- **Classic:** External call before state write (check CEI pattern)
- **Cross-function:** Two functions in the same contract share state, one makes an external call
- **Cross-contract:** Shared state across two contracts, one makes an external call
- **Read-only:** A view function that returns manipulated state during a reentrant call
- **Emergency exits:** Do pause/panic functions properly stop reentrancy?

### Agent 3: Accounting & Rounding
- **Rounding direction:** Who does rounding favor? User or protocol?
- **Precision loss:** Division before multiplication, truncated amounts
- **Share price manipulation:** First-depositor attacks, donation attacks, PPS inflation/deflation
- **Fee calculation:** Are fees taken from principal or yield? Can fees be bypassed?
- **Cumulative loss:** Over many transactions, does rounding create measurable value extraction?

### Agent 4: Price & Oracle
- **Spot price reliance:** Is spot price used without manipulation protection?
- **TWAP:** Is the TWAP window long enough? Can it be gamed?
- **Single oracle:** Is there a fallback if the primary oracle fails?
- **Oracle manipulation:** Can a flash loan move the price within the permitted range?
- **Calmness checks:** What defines "calm"? Can it be manipulated?

### Agent 5: Economic
- **MEV exposure:** Slippage parameters, deadlines, sandwich protection
- **Front-running:** Is there a predictable state change that can be front-run?
- **Griefing:** Can a user prevent others from using the protocol?
- **Donation attacks:** Can tokens be donated to inflate share price and steal from depositors?
- **Rebalancing value extraction:** Can a keeper/operator extract value through rebalancing?

### Agent 6: External Calls & Integrations
- **Unchecked return values:** Are external call return values checked?
- **Arbitrary call targets:** Can a user or privileged role call arbitrary addresses?
- **Fee-on-transfer tokens:** Does the contract handle tokens that take a fee on transfer?
- **Rebasing tokens:** Does the contract assume a fixed balance?
- **ERC-777 / callback tokens:** Can a token callback re-enter the contract?
- **Approvals:** Standing approvals to external contracts — can they be abused?

### Devil's Advocate (from sc-auditor)

After every finding, **try to kill it**:
- Is this actually exploitable, or just a best-practice violation?
- What are the preconditions? Are they realistic?
- Can a real user trigger this, or only a privileged role?
- Would this be caught by normal slippage/deadline checks?
- Is there a cheaper/more obvious way to exploit the same thing?

If the finding survives the Devil's Advocate, it's worth proving.

---

## Phase 3: Proving (from Plamen + foundry-poc-mainnet-fork)

**Goal:** Prove every finding on a fork, or discard it.

1. **Fork the chain:**
   ```bash
   anvil --fork-url <rpc> --fork-block-number <block>
   ```

2. **Write a Foundry test:**
   - Use real deployed addresses — no mocks, no `vm.store` cheats
   - Demonstrate the exploit end-to-end
   - Show the money moving

3. **If the test passes** → the bug is real. Write it up.
4. **If the test fails** → the finding dies here. Move on.

**Template:** See `TEMPLATES/poc-template.t.sol`

---

## Phase 4: Writing Up

**Goal:** Short, reproducible, honest.

Every finding contains:
- **Title** — what the bug is, one sentence
- **Severity** — Critical / High / Medium / Low / Gas
- **Description** — what it costs, who is affected, preconditions
- **Location** — file, function, line numbers
- **Proof of Concept** — exact command to reproduce and test output
- **Recommendation** — how to fix it

The strongest line you can give a team: *"Do not trust me; run this yourself."*

**Template:** See `TEMPLATES/finding.md`

---

## Phase 5: Reporting

1. **Send privately** — email, DM, or their security contact
2. **Include the report + PoC** — the team may bring you in to help fix
3. **Ask what they offer as a reward** — after the report lands, not before
4. **Help verify the fix** once the change is deployed

---

## Tools Reference

| Tool | When to use | How to access |
|------|-------------|---------------|
| Pashov x-ray | Pre-audit scan | `skills/` in this repo |
| Pashov solidity-auditor | Fast feedback during read | `skills/` in this repo |
| Claudit | Find similar bugs in Solodit | MCP server |
| Plamen ($30-100) | Deep autonomous audit | PlamenTSV/plamen on GitHub |
| foundry-poc-mainnet-fork | PoC template | cholakovvv/foundry-poc-mainnet-fork |
| sc-auditor | Parallel hunting + Devil's Advocate | Archethect/sc-auditor |
| Nemesis | Feynman + state audit loop | 0xiehnnkta/nemesis-auditor |
