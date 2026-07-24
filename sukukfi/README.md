# SukukFi

**Chain:** Berachain (80094)
**TVL:** $54
**Listed:** Jul 8, 2026
**Status:** 🟢 Clean — Already Code4rena audited

## Overview

RWA Lending protocol with Islamic finance mechanics (Mudarabah profit-sharing). Users deposit into multi-asset vaults (USDC.e, USDT0, HONEY) and receive yield from telecom invoice financing on-chain.

## Key Contracts

| Contract | Address | Role |
|----------|---------|------|
| duPRT token | `0xf5Bac52e31317dE901edc773fbef8f75c798f36f` | Protocol token |
| USDC.e vault | `0x1B610abd3dFA170fdC579c48da700721...` | Multi-asset vault |
| USDT0 vault | `0x3d6D8D7e66594f3cFbbF2c65dcE305e...` | Multi-asset vault |
| HONEY vault | `0xdc9D7e60f3091029FA2479919325385a...` | Multi-asset vault |

## Analysis Summary

- **Code base:** WERC7575 multi-asset vault system, ERC-7540 async request→fulfill→claim, UUPS upgradeable
- **Security:** Already completed Code4rena audit + post-audit fix report
- **Novelty:** Islamic finance mechanics, permit-based transfers, KYC enforcement

## Verdict

Already professionally audited by Code4rena. No value-add from solo review.

## Source

`code/` — Source contracts pulled for review
