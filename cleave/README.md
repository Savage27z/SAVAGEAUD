# Cleave

## Target Card

| Field | Value |
|---|---|
| **Protocol** | Cleave — Options Splitting (Earn + Boost) |
| **Chain** | Ethereum |
| **Category** | Options |
| **TVL** | ~$76 |
| **Listed** | July 1, 2026 |
| **Audit** | ❌ None (Lean 4 formal verification claimed) |
| **Status** | 🟢 Clean — nothing reportable |
| **Team** | Zeng Jiajun (@zengjiajun_eth), Tom Teman (@tomteman) |

## Contracts

| Contract | Address |
|---|---|
| SplitFactory | `0x86a64e50092155cfe63cedeba4e7cd29bf495921` |
| PinnableOracle | `0xca951892a2222650364C575e857302051528968b` |
| UniswapV3MedianOracle | `0x477a6ed629f893a33f24c31573681f6b243cbeac` |
| Series (ETH @ $1350) | `0xa226a536d325c7ca0d565f2e83d91766a4685f46` |
| Series +3 more | Factory created 5 total |

## Findings Summary

| Severity | Count |
|---|---|
| Critical | 0 |
| High | 0 |
| Medium | 0 |
| Low | 0 |
| Info | 0 |

## Notes
- Series matures **Aug 1, 2026** (8 days from now) — not yet expired
- PinnableOracle has a 6-hour pin window, then locked. Fallback to historical TWAP if not pinned.

## Audit Log

| Phase | Date | Status |
|---|---|---|
| 0: Recon | Jul 23, 2026 | ✅ |
| 1: Read | Jul 23, 2026 | ✅ |
| 2: Hunt | Jul 23, 2026 | ✅ |
