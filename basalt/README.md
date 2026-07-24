# Basalt Vault

| Field | Value |
|-------|-------|
| **Chain** | Arbitrum One |
| **TVL** | $119K |
| **Listed** | July 12, 2026 |
| **Category** | Delta-neutral yield vault |
| **Strategy** | Deposit USDC → GMX GM pool (yield) + hedge BTC via Dolomite (short) |
| **Code** | github.com/andrepurr/basalt-vault (BUSL-1.1) |
| **Team** | @basalt_vault on X, 159 followers, verified, responsive |
| **Audit** | None found |

## Architecture

Each user gets their own **VaultCore clone** (ERC721 NFT) with a dedicated Dolomite isolation account. Singleton handlers execute logic via `universalCall`.

```
VaultCoreNftFactory → mints VaultCore (1 NFT = 1 user vault)
                         ↕ VaultState (per-user storage)
                         ↕ universalCall → Handler singletons
                            ├─ DepositHandler → Dolomite + GMX
                            ├─ WithdrawHandler → GMX → Dolomite
                            ├─ ManagerHandler → LTV / rebalance
                            ├─ AsyncRecoveryHandler → failed settlements
                            └─ FeeAccountingHandler → HWM fee
```

## Contracts

### Core (13 files, 1,865 lines)
| Contract | Address | Purpose |
|----------|---------|---------|
| VaultCore | `0x8cc187846e3bee690cbb37c431701c4c587550f1` | Clone implementation — execution engine |
| VaultState | `0x9be65dfdb5a108151af95524072420d5c2075ddf` | Clone storage + config |
| ManagerContract | `0x638505776382d471091f9bb8301118023d6dabb3` | Protocol-level management |
| VaultCoreNftFactory | `0x08e466fb09617d16ed27da9ea43ba601665f3b89` | Clone deployment (ERC721) |
| FeeSplitter | `0x807bc93a1a3336572b4d43065baae5bb87c5bc20` | Performance fee distribution |
| InitialCoreAddressBook | `0xcd2f28939e4b9f4d2af772137396ec42ad6d8143` | Address registry |

### Handlers (26 files, 4,149 lines)
| Contract | Address | Purpose |
|----------|---------|---------|
| DepositHandler | `0xf41150e3800f81b2a7987cf7dc84852855d669d6` | Two-stage async deposit |
| WithdrawHandler | `0x73e9395d046fbe5b8ae6bcdb4c5304bb974d1520` | Two-stage async/sync withdraw |
| ManagerHandler | `0xbc5150333eede35f511f0fca17b02a99fe29fec3` | LTV rebalance + config |
| AsyncRecoveryHandler | `0xa430d5d60d1bcb29e7e8a0a8663e644bb377fe72` | Failed tx recovery |
| FeeAccountingHandler | `0x32ccb39393427801483226531be02eaf4284d6ce` | HWM performance fee |

### Math
| Contract | Address | Purpose |
|----------|---------|---------|
| BasaltMath | `0xbbfce8b98bd817fe2059a227c32ae086b4ed0c11` | Core math library (513 lines) |

### UX Helpers
| Contract | Address | Purpose |
|----------|---------|---------|
| BasaltZapIn | — | USDC → GM swap for deposits |
| BasaltZapOut | — | WBTC → USDC swap for withdrawals |
| BasaltGmUnwrapper | — | GM → WBTC unwrap |

## Analysis Summary

| Method | Result |
|--------|--------|
| **Manual review** | Clean — well-structured, proper guard patterns |
| **Slither** | 2 HIGH (FP), 19 MEDIUM (FP) — no real issues |
| **Fork testing** | Blocked — Arbitrum RPC timeouts |

## Key Design Decisions

- **Vault isolation:** Each user gets own clone + Dolomite account — no shared pools
- **Handler upgrade:** Manager proposes → NFT owner accepts (2-key approval)
- **Deadman switch:** If manager stops, owner can take over after N blocks
- **Async ops:** Two-stage (initiate → keeper finalizes). Fail gracefully if keeper misses
- **Sync withdraw:** Possible when no debt — instant, no keeper needed
- **HWM fee:** Only charges on NEW profits above previous high water mark
- **Pricing:** Dolomite oracle (Chainlink) with 0.25% spread guard

## Checklist Items Added
- [ ] Async settlement — timeout/grace period
- [ ] Clone initialization — factory-guarded
- [ ] Handler upgrade — two-key approval
- [ ] Cross-system pricing (E8/E18/E28 conversion)

## Verdict
🟢 **Nothing exploitable found on first pass.** The code is well-structured with proper security patterns. Handler dependencies and the `universalCall` delegatecall path are by design. Fork testing will be done when Arbitrum RPC is available.
