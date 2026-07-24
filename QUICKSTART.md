# Quickstart — Cold Agent Pickup

You're here to audit small DeFi protocols. This repo is designed so you can pick up where the last session left off. Read these files in order:

## 1. Start Here

| File | What it tells you |
|------|-------------------|
| `METHODOLOGY.md` | How we audit: target selection → recon → reading → hunting → tools → fork → report |
| `RULES.md` | Non-negotiable: never inflate, never disclose raw Slither, test on copies only |
| `CHECKLIST.md` | Every vulnerability class we check on every target — updates as we learn |
| `CHAIN_INFO.md` | RPCs, explorers, and quirks for chains we work on |

## 2. Current Status

Check `README.md` for a full target table. Completed targets live under `TARGETS/` or at the root level (`basalt/`, `cleave/`, `obsdn/`, etc.).

## 3. Your Workflow

```
Hunt targets → Present 1 to user → Get greenlight → Audit (multi-pass) → Report → Update repo
```

### Multi-Pass is Mandatory

Every target gets **at least 2 focused passes** with different attack angles:

1. **Phase 0: Recon** — surface map, trust model, external deps
2. **Phase 1: Read** — Feynman: "why does this line exist?"
3. **Phase 2: Hunt** — 6-agent checklist (access, reentrancy, math, oracles, upgrades, MEV)
4. **Phase 3: Tools** — Slither + manual triage
5. **Phase 4: Fork tests** — integration + edge cases (user does depth)
6. **Phase 5: Second pass** — fresh angle, different attack vectors

Never call a target "clean" after one read-through. The user's standard is 4+ audit rounds.

## 4. When You Find Something

- Write a finding using `TEMPLATES/finding.md`
- Save it in `<target>/findings/`
- Ask the user to prove it on a fork before reporting

## 5. When a Target Is Clean

- Write a `README.md` for the target
- Update the main `README.md` target table
- Update `CHECKLIST.md` with any new insights learned
- Move on. Don't manufacture findings.

## 6. Repo Maintenance

- Each target gets: `README.md`, `findings/` (if any), `code/` (if pulled)
- Update `CHECKLIST.md` with every new vulnerability angle discovered
- Update `CHAIN_INFO.md` when operating on a new chain
- Keep `METHODOLOGY.md` current — this is the playbook any agent follows

## 7. User Profile

- **𝖲𝖠𝖵𝖠𝖦𝖤** does depth (fork verification, PoC writing, disclosure). You do breadth (find targets, read code, flag suspicious).
- They communicate in brief signals. One-word approvals, short redirects. Don't over-deliberate.
- They defer to your judgment on target selection. Pick one and execute.
- Reports must sound human — natural language, "-" bullets, analogies over jargon.
