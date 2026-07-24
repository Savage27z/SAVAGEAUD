# Moonvault

**Chain:** Robinhood Chain (4663)
**Date:** July 22, 2026
**Status:** 🟢 Clean — Nothing reportable (Beefy fork)

## Overview
Yield aggregator (Beefy Finance V7 fork). Users deposit assets, receive mooToken shares, which auto-compound through configurable strategies.

## Key Contracts
| Contract | Address | Role |
|----------|---------|------|
| MoonVaultV7 | `0x82A3A5B1652667c69328C44Fe6F24bC17F3726bB` | Main vault |

## Analysis Summary
- Standard Beefy vault pattern: deposit → mint shares → earn() sends to strategy
- Withdraw: burn shares → pull from strategy if vault balance insufficient
- Strategy upgrade with timelock (approvalDelay)
- `inCaseTokensGetStuck()` rescue function (excludes want token)

## Verdict
Standard Beefy Finance fork. Well-known audited pattern. No custom logic found.
