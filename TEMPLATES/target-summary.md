# Target Summary Template

Use this when documenting a completed target in the repo. Save as `<target>/README.md`.

---

# Protocol Name

**Chain:** [Chain name (Chain ID)]
**Date:** [Month DD, YYYY]
**Status:** 🟢 Clean / 🟡 Informational only / 🔴 Findings

## Overview
2-3 sentences describing what the protocol does and why it's interesting.

## Key Contracts

| Contract | Address | Role |
|----------|---------|------|
| Main | `0x...` | Entry point |
| Other | `0x...` | Description |

## Analysis Summary

- Bullet points covering key architecture decisions
- Notable defenses found
- What was verified on-chain

## Passes Performed

| Phase | Method | Status |
|-------|--------|--------|
| 0: Recon | Surface map, trust model, deps | ✅ |
| 1: Read | Full code read (Feynman questioning) | ✅ |
| 2: Hunt | 6-agent checklist run | ✅ |
| 3: Tools | Slither + manual triage | ✅ |
| 4: Fork tests | Integration + edge cases | ✅ / ⏭️ skipped |
| 5: Deep dive | Second pass, different angle | ✅ |

## Findings

| # | Finding | Severity | Status |
|---|---------|----------|--------|
| 1 | — | — | — |

(None if clean)

## Verdict

One paragraph final assessment.
