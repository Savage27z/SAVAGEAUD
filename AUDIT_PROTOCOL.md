# AUDIT PROTOCOL — the standing loop

**Source:** the operator's own method, recorded verbatim 2026-09-13.
This is the **canonical workflow**. Everything else in this repo (`METHODOLOGY.md`, `CHECKLIST.md`,
TMAAR, gap-hunter passes, `fork-attack-phase`) is an implementation detail *underneath* it — not a
replacement for it, and not optional extra.

---

## Before the audit

1. Gather all info about code & integrations
2. Push this into the AI for better context
3. Ask AI to split project into sections
4. Ask AI to get invariants, actors, assumptions
5. Ask it to write all of that into a JSON file
6. Go one section at a time
7. Check every answer against the code

## During the audit

1. Find where the value moves
2. Find the main functions everything depends on
3. Pick one flow and hunt it manually
4. Walk it end to end
5. Ask what must never happen here

## After you think you're done

1. You're not done
2. Complex integrations? Do more pass
3. Heavy math? Build fuzzing around it
4. New mechanism? Go deep on invariants again
5. Grind till the end

---

## How each step is satisfied here (so the loop is executable, not aspirational)

### Before

| Step | Where it lives |
|---|---|
| 1. Gather code + integrations | `TARGETS/<n>/` (source, recovered ABI, bytecode, proxy map), `CORTEX.md` notes, DefiLlama/docs/explorer checks, `references/*-chain.md` |
| 2. Push into the AI | repo is the agent's context: `CLAUDE.md` → this file → `METHODOLOGY.md` → target dir |
| 3. Split into sections | `TEMPLATES/target-spec.json` → `sections[]` (one contract/flow per section, each owned by its own pass) |
| 4. Invariants, actors, assumptions | `TEMPLATES/target-spec.json` → `invariants[]`, `actors[]`, `assumptions[]`; narrative version in `TARGETS/<n>/TMAAR.md` (Phase 0.5, mandatory before reading code) |
| 5. **Write it all into a JSON file** | **`TEMPLATES/target-spec.json`** — this is the artifact the loop turns on. Machine-readable, one per target, updated as sections close. Without it, "section by section" degrades into aimless reading |
| 6. One section at a time | `sections[].status` moves `not_started → in_progress → closed`; a section is closed only with evidence, never with an impression |
| 7. Check every answer against the code | **Every** claim in the spec carries evidence: a file:line, a fork receipt, an on-chain read. "The code looks like" is not an answer; the rule in `RULES.md` is that no finding ships without a reproduction |

### During

| Step | Where it lives |
|---|---|
| 1. Where the value moves | `value_movers[]` in the spec — every function that moves funds/value, with its guards. On casino/DeFi this is the first pass, and on nar.bet it is what produced the findings: the money moved through `withdrawNativeFunds` and the payout path |
| 2. Main functions everything depends on | `main_functions[]` — the few entry points the whole system routes through (on nar.bet: `Play`, `_entropyCallback`, `transferPayout`, and the bankroll's owner withdraw) |
| 3. Pick one flow, hunt manually | a section, end to end, by hand — not a grep sweep |
| 4. Walk it end to end | `fork-attack-phase.md`: an authority that only *reads* never reaches the parts of a state machine that only exist while executing (nar.bet's refund gate order hid a second gate until the path was walked call by call) |
| 5. "What must never happen here?" | `TEMPLATES/target-spec.json` → `never_should_happen[]`, and each one becomes a fork attack or an invariant check. This question is where hypotheses come from |

### After

| Step | Where it lives |
|---|---|
| 1. "You're not done" | `passes[]` — a target is not closed on the first clean read. nar.bet needed 6 passes and 4 hypotheses died before the money path gave anything up |
| 2. Complex integrations → more passes | one extra pass per external dependency (oracle, relayer, bridge, proxy, upgrade path) |
| 3. Heavy math → fuzzing | fizz/Echidna/Medusa stateful suites around the math, not around the contracts in general |
| 4. New mechanism → invariants again | redo step 4 of "Before" for the new mechanism rather than bolting it onto the old invariant list |
| 5. Grind till the end | the last section and the last "what must never happen" is where the finding usually is. On nar.bet the money path only fell out after everything else had been cleared |

## Non-negotiable pairing

- Every `invariant[]` entry needs a **check**, not a sentence. An invariant with no test is a wish.
- Every `never_should_happen[]` entry needs an **attempt** on a fork.
- Every closed section needs the **evidence field filled**. A section with an empty evidence field is open.
- A target is **never** called clean while any section sits at `not_started`, or any unmapped contract
  remains (nar.bet: 9 of 19 game contracts were never mapped and that is recorded as an explicit
  coverage gap, not as a clean result).
