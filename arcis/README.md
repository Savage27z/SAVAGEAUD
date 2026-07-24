# Arcis Protocol

**Chain:** Base (8453)
**TVL:** $120
**Listed:** Jun 29, 2026
**Status:** 🟢 Clean — Nothing reportable

## Overview

AI Agent Treasury Infrastructure on Base. First DeFi protocol designed for AI agents (ATI standard). 7 custom contracts including vaults, identity-aware credit with 5 reputation tiers, and revenue bonds.

## Contracts

| Contract | Role |
|----------|------|
| ArcisVault | ERC-4626 yield vault (USDC → raUSDC) |
| AgentCredit | Identity-aware credit (ERC-8004, 5 reputation tiers) |
| RevenueBondFactory | Tokenized agent revenue bonds |
| IdentityRegistry | Agent reputation scoring |
| StrategyAllocator | Timelocked strategy management |
| ATIRouter | Single entry point for agents |
| StrategyAave | Aave V3 adapter |

## Analysis Summary

- **Inflation protection:** Virtual shares/assets offset prevents first-depositor attack
- **Reentrancy:** Guards on all mutative functions
- **Access control:** Clear role separation, timelocked strategy additions
- **Code quality:** Well-structured, proper security patterns

## Verdict

Clean, solid work from the team. Standard owner-controlled vault risks (pause, fee changes, strategy management) but documented as intentional design.

## Source

`code/` — contracts pulled for review
