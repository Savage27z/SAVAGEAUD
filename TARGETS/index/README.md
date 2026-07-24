# The Index

**Chain:** Robinhood Chain (4663)
**Date:** July 22, 2026
**Status:** 🟢 Clean — Nothing reportable

## Overview
Stock dividend protocol on Robinhood Chain. Hold $INDEX, earn tokenized stocks. A Uniswap v4 hook collects 3% in native ETH on every swap, which the treasury uses to buy a basket of 18 tokenized stocks distributed pro-rata to $INDEX holders every ~15 minutes.

## Key Contracts
| Contract | Address | Role |
|----------|---------|------|
| $INDEX | `0x56910D4409F3a0C78C64DD8D0545FF0705389870` | Token |
| IndexFeeHook | `0x2cD91bD228ff4c537031d6b8204782090c84c0cC` | 3% ETH fee hook |
| StockTreasury | `0x1604Ff11dFeAaC437077aEDA2FA492ac9EC804dF` | Accumulates ETH, buys stocks |
| StockDistributor | `0x2459dedb3012d1e929edd17df26620120bdf11bf` | Distributes stocks to holders |
| LpLock | `0x889069BD282f1c1C66CB853e10627595C28e71E2` | LP lock |

## Analysis Summary
- **Fee hook:** Uniswap v4 beforeSwap/afterSwap hooks for specified/unspecified ETH paths
- **Treasury:** Keeper-gated, splits ETH equally across registered stocks via v4 swaps
- **Distributor:** Paginated snapshot + pro-rata distribution with returndata bomb protection
- **Safety invariants:** Router resolved on-chain from immutable registry (10+ documented invariants)

## Verdict
Professional-grade code with explicit safety invariants. No exploit path found.
