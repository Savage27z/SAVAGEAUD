# Quickstart — Cold Agent Pickup

You're here to audit small DeFi protocols. This repo is designed so any agent can pick up where the last session left off. Read these files in order:

## 1. Start Here

| File | What it tells you |
|------|-------------------|
| `METHODOLOGY.md` | How we audit: target selection → TMAAR → recon → reading → hunting → tools → fork → report |
| `RULES.md` | Non-negotiable: TMAAR before code, no speculation, no severity inflation |
| `CHECKLIST.md` | Every vulnerability class we check on every target — updates as we learn |
| `CHAIN_INFO.md` | RPCs, explorers, and quirks for chains we work on |

## 2. Current Status

Check `README.md` for a full target table. 12 targets audited (all clean). Completed targets live under `TARGETS/`.

## 3. Your Workflow

```
Hunt targets → Present 1 to user → Get greenlight → Audit (multi-pass) → Report → Update repo
```

### Multi-Pass is Mandatory — Full Combined Stack

Every target gets the **entire methodology stack**, not a subset. Think of it as layers that all apply:

| Phase | Layer | What You Do |
|-------|-------|-------------|
| **Pre-audit** | What Changed | Read 2-3 disclosed reports for similar protocols first |
| **Phase 0: Recon** | Surface map | Trust model, external deps, entry points |
| **Phase 0.5: TMAAR** | Macro methodology | Actors, trust levels, assumptions, accepted risks. BEFORE reading code |
| **Phase 1: Read** | Feynman | "Why does this line exist?" question every function |
| **Phase 2: Hunt** | Open-Kritt multi-agent | Run 6 independent perspectives: access, reentrancy, math, oracles, upgrades, MEV |
| **Phase 3: Tools** | Slither + triage | Static analysis, categorize false positives vs leads |
| **Phase 3b: BountyForge** | 4-gate triage | Every potential finding through Reality → Impact → Dedup → Quality |
| **Phase 4: Fork** | EVM Hack Analyzer | Opcode-level replay for PoC validation. Fork tests for integration |
| **Phase 5: Deep dive** | Brute-force angles | Map entry points × bug classes, second pass from completely different angle |

**No cherry-picking. Every target gets all layers.** Never call a target "clean" after one read-through.

## 4. When You Find Something

- Assess **Impact × Likelihood** (both axes — not just severity)
- Write a finding using `TEMPLATES/finding.md`
- Save it in `<target>/findings/`
- Ask the user to prove it on a fork before reporting

## 5. When a Target Is Clean

- Write a `README.md` for the target
- Write a `TMAAR.md` for the target (template at `TEMPLATES/TMAAR.md`)
- Update the main `README.md` target table
- Update `CHECKLIST.md` with any new insights learned
- Move on. Don't manufacture findings.

## 6. Repo Maintenance

- Each target gets: `README.md`, `TMAAR.md`, code files (if pulled)
- Update `CHECKLIST.md` with every new vulnerability angle discovered
- Update `CHAIN_INFO.md` when operating on a new chain
- Keep `METHODOLOGY.md` current — this is the playbook any agent follows
- Reference Macro's public audit library (0xmacro.com/library) for similar protocol types

## 7. User Profile

- **𝖲𝖠𝖵𝖠𝖦𝖤** does depth (fork verification, PoC writing, disclosure). You do breadth (find targets, read code, flag suspicious).
- They communicate in brief signals. One-word approvals, short redirects. Don't over-deliberate.
- They defer to your judgment on target selection. Pick one and execute.
- Reports must sound human — natural language, "-" bullets, analogies over jargon.
