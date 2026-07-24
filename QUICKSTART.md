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

### Multi-Pass is Mandatory

Every target gets **at least 2 focused passes** with different attack angles:

| Phase | Method | Description |
|-------|--------|-------------|
| **0: Recon** | Surface map | Trust model, external deps, entry points |
| **0.5: TMAAR** | Trust model doc | Actors, assumptions, accepted risks (Macro-inspired). Do this BEFORE reading code |
| **1: Read** | Feynman | "Why does this line exist?" question every function |
| **2: Hunt** | 6-agent checklist | Access control, reentrancy, math, oracles, upgrades, MEV |
| **3: Tools** | Slither + triage | Run static analysis, categorize false positives vs leads |
| **4: Fork tests** | Integration + edges | Verify on a fork (user does depth on exploit PoCs) |
| **5: Deep dive** | Second pass | Fresh angle, different attack vectors from first pass |

**Never call a target "clean" after one read-through.** The user's standard is 2+ passes minimum.

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
