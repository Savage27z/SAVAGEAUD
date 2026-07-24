# OBSDN — Security Audit

**Target:** OBSDN — Perpetual DEX for crypto, equities, and ETFs
**Chain:** Monad (chain ID 143)
**TVL:** ~$220k (USDC)
**Status:** 🟢 Live (since May 26, 2026)
**Audit:** ❌ None submitted

**Auditor:** 𝖲𝖠𝖵𝖠𝖦𝖤
**Date:** July 22, 2026
**Phase:** 1 (Architecture & Trust Review)

---

## Summary

OBSDN is a perpetual exchange on Monad using an off-chain matching / on-chain settlement model. Supports multi-collateral (USDC, BTC, ETH), cross/isolated margin, sub-accounts, vault staking, and exotic assets (stocks, ETFs).

### Key Metrics
- Cumulative volume: $3.7M
- 30d volume: $3.6M
- Open interest: $8.9k
- Revenue 30d: ~$1,195
- Deployed: 57 days ago

---

## Architecture

### 8 Contracts (all upgradeable TransparentProxies)

```
┌─────────────────────────────────────────────────────────┐
│                      PROXY ADMIN                         │
│              0x499d05e4c75d2180f1b12be4d71c55d287ce5340  │
│              (Owned by 4/6 Gnosis Safe)                  │
└──────────────────────┬──────────────────────────────────┘
                       │ upgrades
     ┌─────────────────┼────────────────────┐
     ▼                 ▼                    ▼
┌──────────┐    ┌──────────┐       ┌──────────────┐
│  Obsdn   │    │ Matching │       │  PerpLedger  │
│ (Main)   │◄──►│ (Engine) │◄─────►│ (Positions)  │
└────┬─────┘    └──────────┘       └──────────────┘
     │
     ├────────────┬───────────┬──────────────┬──────────────┐
     ▼            ▼           ▼              ▼              ▼
┌────────┐ ┌────────────┐ ┌──────────┐ ┌───────────┐ ┌──────────────┐
│SpotLed│ │VaultManage │ │AccessCtl │ │SigValidatr│ │DlnDepositAdp│
│(Balanc)│ │(Vaults)   │ │(Roles)   │ │(EIP-712)  │ │(deBridge)   │
└────────┘ └────────────┘ └──────────┘ └───────────┘ └──────────────┘
```

### Contract Details

| Contract | Proxy | Implementation | Role |
|----------|-------|---------------|------|
| **Obsdn** | `0x90c374...BE45` | `0x166670...DA95` | Main entry: deposits, withdrawals, orders, vaults, funding |
| **Matching** | `0x227adD...4C03` | `0x5BA057...60c5` | Order matching & settlement |
| **PerpLedger** | `0x336Ed4...CfC59C` | `0x48E461...1BC` | Perpetual position tracking |
| **SpotLedger** | `0x8d1565...6723` | `0x69d8d5...064b4` | Collateral balance tracking |
| **VaultManager** | `0xedF8C3...4591B` | `0xe72f23...fD79` | Vault staking operations |
| **AccessControl** | `0x8dbb54...A77d` | `0x64D00c...749C1D` | RBAC roles management |
| **SigValidator** | `0x823f79...8bba` | `0x0000...` | EIP-712 signature verification |
| **DlnDepositAdapter** | `0x871904...ab3` | `0x0000...` | Cross-chain deposits via deBridge |

### Modules (in Obsdn.sol)
- **AccountModule** — sub-accounts, signers
- **AdminModule** — pause, fee recipients, insurance fund
- **BalanceModule** — deposits, withdrawals, transfers
- **FundingModule** — funding rate updates, payments
- **OrderModule** — matchOrders integration
- **VaultModule** — vault creation, stake/unstake

---

## Trust Assumptions

### Admin Controls
| Parameter | Value | Risk |
|-----------|-------|------|
| Proxy Admin | `0x499d05...5340` | ✅ Contract (not EOA) |
| Admin Owner | 4/6 Gnosis Safe | ✅ Strong multisig |
| Deployer | EOA `0xa96a63...4603` | ⚠️ Only used for initial deploy |
| Protocol Fee Recipient | `0x62131f...F86` | ✅ One of Safe owners |
| Quote Token | USDC (6 decimals) | ✅ Standard |

### Roles (from AccessControl ABI)
- **DEFAULT_ADMIN_ROLE** — full control
- **SEQUENCER_ROLE** — process withdrawals, match orders
- **FEE_SETTER_ROLE** — set fee rates
- **Can pause sequencer ops** — emergency stop

### Critical Observations
1. **SigValidator & DlnDepositAdapter** have no implementation set (impl = `0x0000`). These may be disabled or deployed via a different mechanism.
2. **All upgrade paths lead to 4/6 multisig** — reasonable, but 4/6 means any 4 owners can collude to drain.
3. **Off-chain matching** means the sequencer controls order execution — if the sequencer key is compromised, orders can be front-run.

---

## Key Attack Surface

### High Priority
1. **Signature replay** — EIP-712 typed orders could be replayed across markets or after cancel
2. **Funding rate manipulation** — if funding rate update has weak access control
3. **Liquidation logic** — incorrect PnL calculation could cause bad debt or unfair liquidations
4. **Sequencer trust** — off-chain matching means sequencer sees all orders before broadcast
5. **Upgradeability** — though multisig-controlled, any upgrade could introduce malicious logic

### Medium Priority
6. **Multi-collateral pricing** — BTC/ETH as collateral need price feeds; oracle manipulation risk
7. **Cross-chain deposits** — deBridge integration adds bridge risk
8. **Maker rebate accounting** — negative maker fees could be gamed
9. **Vault staking math** — share calculation errors

### Low Priority
10. **Access control granularity** — verify each module function has correct role check
11. **Reentrancy** — ReentrancyGuard present but cross-contract calls create surface

---

## Phase 1 Verdict

**OBSDN passes Phase 1 (Architecture & Trust Review).**

Strengths:
- ✅ 4/6 multisig for upgrades (not a single key)
- ✅ ReentrancyGuard on mutative functions
- ✅ EIP-712 typed signatures
- ✅ AccessControl for role separation
- ✅ No audit submitted = we're not duplicating anyone

Risks requiring Phase 2 (source code review):
- ⚠️ Signature replay protection (nonces?)
- ⚠️ Funding rate calculation integrity
- ⚠️ Sequencer role privileges
- ⚠️ Cross-contract reentrancy paths

## Final Verdict 🟢

**No critical or high-severity bugs found.** 

The code is clean, well-structured, and follows standard perp DEX patterns. All findings are medium/low severity and relate to **sequencer trust** — a single EOA key controls order matching, withdrawals, and funding rate updates. If this key is compromised, an attacker can drain all user funds.

### Key Findings
| # | Finding | Severity |
|---|---------|----------|
| 1 | Single EOA sequencer key controls everything | MEDIUM |
| 2 | No oracle price validation in matching | MEDIUM |
| 3 | Negative maker fee has no floor | LOW |
| 4 | Position flip uses single price | LOW |
| 5 | Clean code — no reentrancy, sig, or access bugs | INFO |

### Role Map (verified on-chain)
| Role | Holder | Security |
|------|--------|----------|
| ROOT_ADMIN | 4/6 Gnosis Safe | ✅ Strong |
| SEQUENCER | Single EOA | 🔴 Single point of failure |
| EXCHANGE_OPERATOR | 4 addresses | ✅ 3/4 are Safe owners |
| FEE_MANAGER | 4/6 Gnosis Safe | ✅ Strong |
| Upgrade admin | 4/6 Gnosis Safe | ✅ Strong |

### Strengths
- ✅ 4/6 multisig for all admin/fee operations
- ✅ EIP-712 typed signatures with per-user nonces
- ✅ ReentrancyGuard on all mutative functions
- ✅ SafeERC20 for token transfers
- ✅ Precision-safe math library with safe casts
- ✅ Last-admin guard in AccessControl

### Recommendations
1. **Must:** Replace single-EOA sequencer with multisig/threshold scheme
2. **Should:** Add optional oracle price check in matching
3. **Should:** Add lower bound on negative maker fees

Full report: `findings/full-report.md`
Phases 1-2: `findings/phase-1-arch-review.md`, `findings/phase-2-source-review.md`
Source code: `code/`
