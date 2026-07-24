# SAVAGE Audit Operations

**Maintainer:** 𝖲𝖠𝖵𝖠𝖦𝖤 (@Savage27z)

A living audit operations repo. Any agent can pick this up cold and continue the work.

## Quick Start

New to this repo? Read `CLAUDE.md` first.

## Structure

```
audit/
├── CLAUDE.md            # Agent context — read this first
├── QUICKSTART.md        # Cold pickup guide
├── METHODOLOGY.md       # How we audit — target selection → reading → proving → reporting
├── CHECKLIST.md         # Vulnerability classes checked on every target (improves over time)
├── RULES.md             # Non-negotiable rules
├── CHAIN_INFO.md        # RPCs, explorers, chain IDs per chain
├── CHANGELOG.md         # Version history
├── FINDINGS.md          # Central findings index
├── TEMPLATES/           # Finding/report/target-summary templates
└── TARGETS/             # All targets (symlinks + READMEs)
    ├── quiver-protocol/ # ✅ Robinhood Chain
    ├── slvr/            # ✅ Robinhood Chain
    ├── index/           # ✅ Robinhood Chain
    ├── moonvault/       # ✅ Robinhood Chain
    ├── openoracle/      # ✅ Base
    ├── windfall-lotto/  # ✅ Polygon
    ├── basalt/          # ✅ Arbitrum (symlink)
    ├── cleave/          # ✅ Ethereum (symlink)
    ├── obsdn/           # ✅ Monad (symlink)
    ├── sukukfi/         # ✅ Berachain (symlink)
    ├── arcis/           # ✅ Base (symlink)
    ├── sentry/          # ✅ Robinhood Chain (TMAAR applied, Macro-style)
    ├── minepea/         # ✅ Robinhood Chain (full combined stack applied)
    └── ...              # Next target goes here
```

## Current Status

| # | Target | Chain | TVL | Listed | Status | Verdict | Date |
|---|---|---|---|---|---|---|---|
| 1 | Quiver Protocol | Robinhood Chain | $3.1K | Jul 21 | ✅ Complete | 🟢 Informational only | Jul 21 |
| 2 | SLVR GridLottery | Robinhood Chain | — | — | ✅ Complete | 🟢 Clean | Jul 22 |
| 3 | The Index | Robinhood Chain | — | — | ✅ Complete | 🟢 Clean | Jul 22 |
| 4 | Moonvault | Robinhood Chain | $580 | Jul 22 | ✅ Complete | 🟢 Clean (Beefy fork) | Jul 22 |
| 5 | Basalt Vault | Arbitrum | $119K | Jul 12 | ✅ Complete | 🟢 Clean | Jul 23 |
| 6 | OBSDN | Monad | $220K | May 26 | ✅ Complete | 🟢 Clean — report shared | Jul 22 |
| 7 | Cleave | Ethereum | $76 | Jul 1 | ✅ Complete | 🟢 Clean | Jul 23 |
| 8 | SukukFi | Berachain | $54 | Jul 8 | ✅ Complete | 🟢 Clean (C4 audited) | Jul 23 |
| 9 | openOracle | Base | $3.5K | — | ✅ Complete | 🟢 Clean | Jul 24 |
| 10 | Arcis Protocol | Base | $120 | Jun 29 | ✅ Complete | 🟢 Clean | Jul 23 |
| 11 | Windfall Lotto | Polygon | $1.4K | Jul 24 | ✅ Complete | 🟢 Clean | Jul 24 |
| 12 | Sentry | Robinhood Chain | $31K | Jul 2 | ✅ Complete | 🟢 Clean | Jul 24 |
| 13 | MinePea | Robinhood Chain | $5.5K | Jul 23 | ✅ Complete | 🟢 Clean | Jul 24 |
| 14 | Ravenhood | Robinhood Chain | — | Jul 23 | ✅ Complete | 🟢 Clean | Jul 24 |
| 15 | Peeps | Robinhood Chain | $26K | Jul 23 | ✅ Complete | 🟢 Clean | Jul 24 |
| **16** | **HoodBets** | **Robinhood Chain** | **$803** | **Jul 3** | **✅ Complete** | **🟢 Clean** | **Jul 24** |
| **17** | **Hood Index** | **Robinhood Chain** | **$75** | **Jul 17** | **✅ Complete** | **🟢 Clean** | **Jul 24** |
| **18** | **STEEL** | **Robinhood Chain** | **$911** | **Jul 24** | **✅ Complete** | **🟢 Clean** | **Jul 24** |
| | **Next target** | TBD | — | — | ⏳ Ready when you are | — | — |

## Get Started

```bash
# Read the agent context first
cat CLAUDE.md

# Read the methodology
cat METHODOLOGY.md

# Check what's been done
cat CHECKLIST.md

# Hunt for the next target
# → Search DefiLlama + Twitter for fresh unaudited protocols
# → Filter: <$200K TVL, <30 days old, EVM, non-DEX, reachable team
# → Present 1 option to user
```

## Conventions

- **Finding templates:** `TEMPLATES/finding.md`
- **Target summary template:** `TEMPLATES/target-summary.md`
- **Multi-pass mandatory:** At least 2 focused reads with different attack angles
- **All targets live under TARGETS/:** root-level dirs have symlinks there
- **Reporting:** User handles disclosure. You prepare the report.
- **Nothing reportable = say so.** Never inflate severity.
