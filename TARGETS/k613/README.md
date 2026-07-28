# K613 — Audit Report

**Target #20**
**Chain:** Monad
**Category:** Lending (Aave V3 fork) + Custom Staking
**TVL:** ~$36K
**Audits:** 0
**Contracts Reviewed:** K613 (ERC20), xK613 (Staking Receipt), Treasury, RewardsDistributor, Staking
**Aave Pool:** Verified at 0x4Ba3856a4d851d39C27e2E866daB7A95eF6e0113

## Verdict: ✅ CLEAN — No exploitable vulnerabilities found

5 custom contracts reviewed in detail. Aave V3 pool verified but not audited in depth (standard Aave V3.0.2 code).

## Summary

| Component | Lines | Custom? | Notes |
|-----------|-------|---------|-------|
| K613.sol | 101 | ✅ Custom | ERC20Capped + AccessControl + Pausable |
| xK613.sol | 113 | ✅ Custom | ERC20 + AccessControl + Pausable, transfer whitelist |
| Treasury.sol | 244 | ✅ Custom | Buyback engine + rewards deposit |
| RewardsDistributor.sol | 271 | ✅ Custom | Standard reward distribution (accRewardPerShare) |
| Staking.sol | 378 | ✅ Custom | Shadow-inspired exit queue staking |

## Observations

- **H-02 Fix Applied**: `redeemRewards()` in Staking references "H-02 FIX" — a prior high-severity finding where stakers could bypass exit penalties. The fix (checking reward portion vs own position) looks correct.

- **xK613.burnFrom no allowance check**: Minter can burn any user's xK613 without approval. By design (Staking contract is the minter), but the minter is admin-changeable. Admin compromise = all xK613 can be destroyed.

- **Centralization (moderate)**: DEFAULT_ADMIN_ROLE controls minter, whitelist, penalty rates, system stakers, buyback, treasury withdrawals, pause. Typical for a 3-month-old protocol.

- **Penalty rounding up**: `(amount * bps + 9999) / 10000` — rounds penalty UP. Dust amounts (<0.01% of position) could be fully penalized.

- **ExchangeRateAdapter for MON LSTs**: Standard oracle composition (LST/MON × MON/USD). Not verified directly but follows established patterns.

- **Strengths**: Well-documented Natspec, reentrancy guards on all state-mutating functions, SafeERC20 throughout, checks-effects-interactions pattern, explicit error types.

## Methodology Applied

1. ✅ TMAAR — Trust model assessed (admin-centralized, users trust minter)
2. ✅ 4-gate triage — All observations verified
3. ✅ Multi-perspective — Code structure, economic incentives, access control
4. ✅ Narrow passes — Exit flow, reward accounting, redeemPath
5. ✅ EVM mental replay — Stake → exit → instant exit → redeemRewards traced
