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
| 13 | MinePea | Robinhood Chain | $5.5K | 12 observations (TWAP buyback price limit, quiverCallback re-entry, executor centralization, rounding dust) | 🟢 Clean — deep second pass confirmed |
| 14 | Ravenhood | Robinhood Chain | $0 (treasury $56K) | 8 observations (owner separation, no on-chain buyback, burn slippage, reward drain risk) | 🟢 Clean — standard patterns, well-structured |
|| 15 | Peeps | Robinhood Chain | $26K | 6 observations (LP vault mapping corruption, router centralization, graduation phase reversal, curve math verified) | 🟢 Clean — solid architecture, sound math |
|| 16 | HoodBets | Robinhood Chain | $803 | 5 observations (resolver centralization, no refund path in factory, nonReentrant missing on buyShares, dust accumulation, owner market params) | 🟢 Clean — two contracts: Chainlink parimutuel (trustless) + Factory YES/NO (centralized by design) |
|| **17** | **Hood Index** | **Robinhood Chain** | **$75** | **6 observations (no external audit, 1% slippage gap, caller-provided routes, dust accumulation, one-time-set risk, 80h staleness window)** | **🟢 Clean — best-designed protocol yet: immutable basket, hard-capped fees, no upgrade, no admin withdrawal** |

## Process

When a finding is confirmed (fork-proven or on-chain verified):
1. Write it up using `TEMPLATES/finding.md`
2. Save to `<target>/findings/`
3. Add a row here linking to the finding
4. Ask the user to proceed with disclosure

## Methodology Sources

This repo's combined methodology draws from ALL of the following — every target gets every layer:

- **Macro (0xmacro)** — TMAAR trust model, Impact×Likelihood matrices, commit tracking, public audit library (130+ reports)
- **BountyForge v2.0** — 4-gate finding triage (Reality → Impact → Dedup → Quality), "What Changed" disclosed-report learning, anti-pattern library
- **Open-Kritt** — Multi-agent orchestration engine, narrow focused passes, brute-force entry points × bug classes
- **Blockian (Immunefi #18)** — Anchored deduplication, relative ranking, repeats for enumeration
- **EVM Hack Analyzer** — Opcode-level exploit replay, historical hack study, PoC export
