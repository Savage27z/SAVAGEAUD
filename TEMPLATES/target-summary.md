# Target Summary Template

Use this when documenting a completed target in the repo. Save as `<target>/README.md`.

---

# Protocol Name

**Chain:** [Chain name (Chain ID)]
**Chain Explorer:** [URL]
**Date:** [Month DD, YYYY]
**Status:** 🟢 Clean / 🟡 Informational only / 🔴 Findings

**Audited commit:** `<hash>` (chain-verified)
**Final commit:** `<hash>` (after any fix round)
**Repo:** `github.com/org/project`

## Overview
2-3 sentences describing what the protocol does and why it's interesting.

## Key Contracts

| Contract | Address | Role |
|----------|---------|------|
| Main | `0x...` | Entry point |
| Other | `0x...` | Description |

## TMAAR (Trust Model, Assumptions, Accepted Risks)

### Actors & Trust Levels

| Actor | Trust Level | Notes |
|-------|-------------|-------|
| Owner/admin | [High / Medium / None] | Briefly explain what they can do |
| Users | None | — |
| [Other roles] | [Level] | [Key constraint] |

### Key Assumptions
- Assumption 1 (e.g., "Oracle always returns price within 60s window")
- Assumption 2

### Accepted Risks
- Risk 1 (e.g., "Owner can upgrade parameters within ±10%")
- Risk 2

## Exclusions
- [e.g., Deployment scripts — not reviewed]
- [e.g., Off-chain relayer — out of scope]
- [e.g., Frontend / SDK — not in scope]

## Analysis Summary

- Bullet points covering key architecture decisions
- Notable defenses found
- What was verified on-chain

## Passes Performed

| Phase | Method | Status |
|-------|--------|--------|
| 0: Recon | Surface map, trust model, deps | ✅ |
| 0.5: TMAAR | Documented actors, assumptions, risks | ✅ |
| 1: Read | Full code read (Feynman questioning) | ✅ |
| 2: Hunt | 6-agent checklist run | ✅ |
| 3: Tools | Slither + manual triage | ✅ |
| 4: Fork tests | Integration + edge cases | ✅ / ⏭️ skipped |
| 5: Deep dive | Second pass, different angle | ✅ |

## Findings

| # | Finding | Severity | Impact | Likelihood | Status |
|---|---------|----------|--------|------------|--------|
| 1 | — | — | — | — | — |

(None if clean)

## Verdict

One paragraph final assessment.
