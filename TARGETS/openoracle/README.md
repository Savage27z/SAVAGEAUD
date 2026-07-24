# openOracle

**Chain:** Base
**Date:** July 24, 2026
**Status:** 🟢 Clean — Nothing reportable

## Overview

Permissionless price oracle on Base. No committee of signers — reporters stake collateral on both sides of a price (bid + ask), and anyone can dispute by swapping against a bad price. If no one disputes within the settlement window, the price is confirmed. Core innovation: "absence of trade = evidence of correctness."

## Key Contracts

| Contract | Address | Role |
|----------|---------|------|
| OpenOracleSlim | Deployed | Core oracle: report → dispute → settle → withdraw |
| OpenSwapSlim | Deployed | Swap executor at oracle price |
| oracleFeeReceiver | Deployed | 50/50 fee split |

## Analysis Summary

- **Architecture:** Fully permissionless — no admin, no owner, no pause, no upgrade
- **Game theory:** Exponential collateral escalation on disputes. Self-dispute costs the delta (cheaper than external). Settlement-by-absence.
- **State-hash pattern:** Only `keccak256` hashes stored on-chain. Callers supply full preimages verified against stored hashes.
- **CEI enforced:** State written before external calls everywhere. No reentrancy.
- **Gas griefing:** Callback gas check using EIP-150 (1/64) reserve. Callback success ignored — oracle settles regardless.
- **Slippage + timing:** Price tolerance + `blocksPerSecond` check prevent manipulation during L1 congestion. `looseTiming` flag for ±1 block boundary.

## Two-Pass Audit Results

**Pass 1 (code read):** Everything clean. Defenses checked: reentrancy, access control, math, game mechanics, griefing.

**Pass 2 (focused):** Re-checked dispute economics, fee calculation, self-dispute mechanics, callback handling, 1-unit sentinel (permanent dust), fee receiver 50/50 with 1-wei rounding.

**Verdict:** Solid code. Well-structured, well-commented, sound game mechanics. The team understands DeFi security.

## Source Code

`code/src/` — 4 solidity files (oracle, swap, fee receiver, interfaces, libraries)
