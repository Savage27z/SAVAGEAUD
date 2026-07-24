# OBSDN — Full Security Audit

**Target:** OBSDN — Perpetual DEX (crypto, equities, ETFs)
**Chain:** Monad (chain ID 143)
**TVL:** ~$220k USDC
**Status:** 🟢 Live since May 26, 2026
**Audit:** ❌ None submitted

**Auditor:** 𝖲𝖠𝖵𝖠𝖦𝖤
**Date:** July 22, 2026
**Phases:** 1 (Architecture) + 2 (Source Review) + On-chain verification

---

## Executive Summary

OBSDN is a well-architected hybrid perpetual DEX with clean, modular code. No critical or high-severity bugs were found in the on-chain contract logic. The primary risks are **operational/trust-based** rather than code defects.

**Verdict: 🟢 No critical/high findings. 2 medium findings (both sequencer-trust related).**

---

## Role Architecture

### ℹ️ Role Map (verified on-chain)

| Role | Holders | Type |
|------|---------|------|
| **ROOT_ADMIN** | `0x82fe7e...b826` | 🟢 4/6 Gnosis Safe |
| **SEQUENCER** | `0x5D984a...219306` | 🔴 **Single EOA** |
| **EXCHANGE_OPERATOR** | 4 addresses | 🟢 3/4 are Safe owners |
| **FEE_MANAGER** | `0x82fe7e...b826` | 🟢 4/6 Gnosis Safe |
| **OBSDNBE_GENERAL** | `0xD889c1...e081` | 🟡 Single EOA (create vaults/subaccounts) |

### Contract Upgrade Path
```
Obsdn Proxy → TransparentUpgradeableProxy
    └── Admin: 0x499d05e...5340 (ProxyAdmin contract)
         └── Owner: 0x82fe7e...b826 (4/6 Gnosis Safe)
              ├── 6 owners
              └── Threshold: 4 signatures
```

---

## Findings

### 🔴 Finding 1: Single EOA Sequencer Key [MEDIUM]

| Field | Value |
|-------|-------|
| **Severity** | Medium |
| **Type** | Operational / Key Management |
| **File** | Roles.sol, Obsdn.sol |
| **Fixed?** | Architecture, not code |

**Description:** The SEQUENCER role is held by a single EOA (`0x5D984a...219306`). This key controls:
- `matchOrders()` — match any two orders at any price
- `processWithdraw()` — process user withdrawals
- `processTransfer()` — transfer funds between accounts
- `updateFundingRate()` — set arbitrary funding rates
- `processFundingPayment()` — charge arbitrary funding payments
- `stakeVault()` / `unstakeVault()` — vault operations
- `processRegisterSigner()` / `registerChildAccountSigner()` — add signers

A compromised sequencer key = **total loss of all user funds**.

**Recommendation:** Use a multisig or threshold signing scheme for the sequencer. At minimum, add a time-delay or second key for withdrawal processing.

---

### 🟡 Finding 2: No Oracle Price Validation in Matching [MEDIUM]

| Field | Value |
|-------|-------|
| **Severity** | Medium |
| **Type** | Architecture / Price Integrity |
| **File** | Matching.sol: `matchOrders()` |
| **Fixed?** | Architecture, by design |

**Description:** The match price comes directly from the maker order (`matchPrice = maker.price`) with no on-chain check against an oracle or index price. Combined with Finding 1 (single EOA sequencer), a compromised sequencer can settle positions at arbitrary prices.

**Recommendation:** Optionally verify match price is within a band of the oracle price for non-system orders. This would protect users even if the sequencer key is compromised.

---

### 🟢 Finding 3: Negative Maker Fee Has No Floor [LOW]

| Field | Value |
|-------|-------|
| **Severity** | Low |
| **Type** | Economic |
| **File** | Matching.sol: `matchOrders()` |
| **Fixed?** | No |

**Description:** `fees.maker` is only validated with an upper bound (`_validateTradingFee` checks `fee <= maxTradingFee`). For negative fees (maker rebates), there's only a referral rebate cap — no lower bound on the maker fee itself. A sequencer could set `fees.maker = -MAX_REF_REBATE` to drain the maker rebate reserve.

**Recommendation:** Add `_validateTradingFee` check against negative `fees.maker` (e.g., `abs(fees.maker) <= maxRebate`).

---

### 🟢 Finding 4: Position Flip Math — Single Price Used [LOW]

| Field | Value |
|-------|-------|
| **Severity** | Low |
| **Type** | Economic |
| **File** | Matching.sol: `_settleQuoteBalance()`, Case 1 |
| **Fixed?** | No |

**Description:** When a position flips (long→short or vice versa), the old position is closed AND the new position is opened at the same match price. This means the entire PnL is realized at that single price point, which could be gamed if the match price deviates from the market (requires Finding 1+2).

---

### 🟢 Finding 5: Clean Code — No Reentrancy, Signature Validation, or Access Control Bugs [INFO]

| Area | Status |
|------|--------|
| ReentrancyGuard | ✅ Applied to all mutative `Obsdn` functions |
| EIP-712 signatures | ✅ Proper typed data hashing |
| Signature nonces | ✅ Per-user per-nonce tracking, no replay |
| Sequencer nonce | ✅ Strictly increasing `opNonce` |
| Withdrawal auth | ✅ User EIP-712 signature required |
| Access control | ✅ `onlyRole` guards on all sensitive functions |
| Deposit scaling | ✅ Precision-safe `floorAndUnscale` |
| SafeERC20 | ✅ Used for all token transfers |
| Math library | ✅ Safe casts, checked overflow |

---

## On-Chain Verification Summary

| Check | Result |
|------|--------|
| All proxies use TransparentUpgradeableProxy | ✅ |
| ProxyAdmin is a contract, not EOA | ✅ |
| ProxyAdmin owner = 4/6 Safe | ✅ |
| No DEFAULT_ADMIN on AccessControl (safe — uses ROOT_ADMIN instead) | ✅ |
| Collateral token = USDC (6 decimals) | ✅ |
| Protocol fee recipient matches a Safe owner | ✅ |
| 2/8 implementation contracts not deployed (SigValidator, DlnDepositAdapter) | ⚠️ Pending |
| No security audit submitted on MonadScan | ✅ Confirmed |

---

## Recommendations

### Must Fix
1. **Sequencer key → multisig or threshold scheme** — highest impact risk

### Should Fix
2. **Add optional oracle price check** in matching (defense-in-depth)
3. **Add lower bound on negative maker fees** in `_validateReferrals`

### Nice to Have
4. Deploy remaining contracts (SigValidator, DlnDepositAdapter) or mark as deprecated
5. Add on-chain read function for `getCollateralTokens` list

---

## Audit Log

| Phase | Date | Status | Details |
|-------|------|--------|---------|
| Phase 0: Recon | Jul 22, 2026 | ✅ | Contract discovery, TVL, chain info |
| Phase 1: Architecture | Jul 22, 2026 | ✅ | Trust model, upgrade path, role map |
| Phase 2: Source Review | Jul 22, 2026 | ✅ | Obsdn.sol, Matching.sol, modules |
| Phase 3: Static Analysis | Pending | ⏳ | Slither (requires local setup) |
| Phase 4: Fork Testing | Pending | ⏳ | Anvil + Monad RPC |
| Phase 5: Report | Jul 22, 2026 | ✅ | This document |
