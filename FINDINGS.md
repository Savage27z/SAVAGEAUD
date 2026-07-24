# Findings Index

No reportable findings on any target to date. All audits returned clean.

## All Targets

| # | Target | Chain | TVL | Findings | Verdict |
|---|--------|-------|-----|----------|---------|
| 1 | Quiver Protocol | Robinhood Chain | $3.1K | None | 🟢 Clean (rounding quantified: 1 wei max) |
| 2 | SLVR GridLottery | Robinhood Chain | $105K | None | 🟢 Clean |
| 3 | The Index | Robinhood Chain | — | None | 🟢 Clean |
| 4 | Moonvault | Robinhood Chain | $580 | None | 🟢 Clean (Beefy fork) |
| 5 | Basalt Vault | Arbitrum | $119K | None | 🟢 Clean |
| 6 | OBSDN | Monad | $220K | 5 observations (sequencer trust model) | 🟢 No critical findings |
| 7 | Cleave | Ethereum | $76 | None | 🟢 Clean |
| 8 | SukukFi | Berachain | $54 | None | 🟢 Already C4 audited |
| 9 | openOracle | Base | $3.5K | None | 🟢 Clean |
| 10 | Arcis Protocol | Base | $120 | None | 🟢 Clean |
| 11 | Windfall Lotto | Polygon | $1.4K | None | 🟢 Clean |
| 12 | Sentry | Robinhood Chain | $31K | None | 🟢 Clean |

## Process

When a finding is confirmed (fork-proven or on-chain verified):
1. Write it up using `TEMPLATES/finding.md`
2. Save to `<target>/findings/`
3. Add a row here linking to the finding
4. Ask the user to proceed with disclosure

## Methodology Sources

This repo's methodology draws from:
- **Macro (0xmacro)** — TMAAR, Impact×Likelihood, commit tracking, trust model analysis
- **BountyForge v2.0** — 4-gate finding triage (Reality → Impact → Dedup → Quality)
- **Open-Kritt / Blockian** — Multi-agent orchestration, narrow focused passes
- **EVM Hack Analyzer** — Opcode-level exploit replay for PoC verification
