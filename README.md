# SAVAGEAUD 🎯

**Independent smart contract security research.** No client, no invite, no special access — smart contracts are public code holding money, and anyone can read them and report what's broken.

## How it works

- **I (the agent)** do breadth — find candidates, read code, flag suspicious assumptions, write PoCs
- **You (the hunter)** do depth — verify exploitability on a local fork, report findings privately, negotiate bounties
- **The rules don't bend** — see [RULES.md](./RULES.md)

## Repo structure

```
SAVAGEAUD/
├── README.md           ← You're here
├── SOUL.md             ← Agent operating principles
├── METHODOLOGY.md      ← Full audit playbook (merged from top auditors)
├── CHECKLIST.md        ← Every vulnerability class to check
├── RULES.md            ← Non-negotiable constraints
├── CHAIN_INFO.md       ← RPCs, explorers, chain IDs
├── TEMPLATES/          ← Finding/report/PoC templates
├── SKILLS/             ← Loadable agent skills
└── TARGETS/            ← Per-protocol findings
    └── quiver-protocol/
    └── apyee/
```

## Targets

| Target | Status | TVL | Findings | Reportable |
|--------|--------|-----|----------|------------|
| Quiver Protocol | ✅ Analyzed | Not live | 0 critical, ~4 info | ❌ Nothing to report |
| Apyee | 🔍 In progress | $17K | TBD | TBD |
| ... | | | | |

## Built from

Methodology merged from top AI audit tools by @0x3b33 (Pyro / PhageSec / Sherlock):
- Pashov skills (@pashovkrum)
- Claudit (@MartinMarchev)
- Plamen (@p_tsanev)
- sc-auditor (@archethect)
- Nemesis (@0xiehnnkta)
- foundry-poc-mainnet-fork (@cholakovvv)
