# Cleave — Phase 0: Recon

## Quick Summary

| Field | Value |
|---|---|
| **Protocol** | Cleave — Options splitting (Earn + Boost) |
| **Chain** | Ethereum mainnet |
| **TVL** | ~$76 |
| **Listed** | ~July 1, 2026 |
| **Audit** | ❌ None — claims Lean 4 formal verification on accounting core |
| **Team** | Zeng Jiajun (@zengjiajun_eth), Tom Teman (@tomteman), Kevin Weaver (@kevin_weaver) |
| **Status** | Live ~22 days, 5 Series created, minimal use |

## Contract Surface

### SplitFactory (`0x86a64e50092155cfe63cedeba4e7cd29bf495921`)

Creates Series contracts via `createSeries()`, `createSeriesWithCollateral()`, `createAndSplit()`.
Immutable factory — no upgrades, no admin keys.

### Series (deployed by factory)

Each Series is a standalone market for one (collateral, strike, maturity, oracle) tuple.

- **split()** — Deposit collateral, mint P (Earn) + N (Boost) tokens
- **merge()** — Return P + N tokens, withdraw collateral
- **redeem()** — After maturity, redeem based on oracle price
- **addCollateral()** / **removeCollateral()** — Adjust positions

**Token P (Earn):** Capped upside — like a covered call. Gets yield/capped return.
**Token N (Boost):** Leveraged upside — like a call option. Gets remaining upside after P is paid.

### Key Properties

- ✅ ReentrancyGuard on all mutative functions
- ✅ SafeERC20 for token transfers
- ✅ Immutable — no upgrade path, no admin keys
- ✅ Lean 4 formal verification claimed on accounting core
- ⚠️ Oracle-dependent settlement — price at maturity determines P/N payouts

### Series Created (5 total, all ETH-collateral)

1. `0xa226a5...f46` — 21 days ago
2. `0xcd4485...3E6` — 20 days ago (also had a 0.001 ETH split test)
3. `0x946752...918c` — 20 days ago
4. `0x979923...8d2` — 20 days ago
5. `0xa36b95...b20` — 19 days ago

All created by `0x1154c68ebc34cd61e089b7f6beadf111dae1097e` (team deployer) except one by `0x8f63d7d...23315` (maybe a test user).

## Attack Surface

1. **Oracle manipulation** — If the oracle price feed can be manipulated at maturity, P/N payouts can be gamed
2. **Split/merge math** — Rounding direction in share calculations
3. **First-depositor** — Inflation attack on split token ratios
4. **Reentrancy** — Cross-function reentrancy between split/merge/redeem
5. **Maturity handling** — What happens if oracle fails at maturity? Grace period?
6. **Collateral safety** — Can P or N holders extract more than their share?
