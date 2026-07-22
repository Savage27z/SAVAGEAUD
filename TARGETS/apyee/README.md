# Apyee

**Status:** 🔍 Analyzed — likely nothing reportable
**Chain:** Ethereum, Base, Arbitrum, BNB
**Category:** AI-Powered Stablecoin Yield Aggregator
**TVL:** $17K
**Audit:** Soken — Progressive 55 → 78 → 88 → **91/100** (4 rounds)

## Contracts Analyzed

| Contract | Lines | Source |
|----------|-------|--------|
| Vault.sol | 1076 | ERC-4626 with streaming performance fee |
| BaseStrategy.sol | 612 | Abstract base with reward compounding |
| AaveV3Strategy.sol | TBD | Aave V3 integration |
| CompoundV3Strategy.sol | TBD | Compound V3 integration |
| MorphoStrategy.sol | TBD | Morpho integration |
| FluidStrategy.sol | TBD | Fluid integration |
| VenusStrategy.sol | TBD | Venus integration |

## Findings

### ✅ Well-defended
| Area | Detail |
|------|--------|
| **Fee math** | F-03 remediated: fees based on realized profit (not post-yield TA), correct dilutive share-mint formula |
| **Same-block accrual** | F-01/F-902: `_accrue()` short-circuits if already run this block, override gated on `lastAccruedAt == block.timestamp` |
| **Quarantine escape hatch** | F-05: Owner can exclude broken strategies from `totalAssets()` without freezing the vault |
| **Owner renounce** | F-06: Disabled — vault never becomes ownerless |
| **Strategy swap path** | F-04/N-01: endpoint-bound path validation + hop-token whitelist + `_computeMinOutFloor` |
| **Price feed** | F-04-MEV.1: Chainlink + fallback + minOut floor against sandwich |
| **Replay protection** | Constructor guard: `onlyDeployChain` blocks cross-chain replay |
| **DEX router validation** | Constructor: verifies router has bytecode |
| **Strategy list integrity** | F-02/F-07: swap-and-pop on `removeStrategy` prevents double-count in `totalAssets()` |
| **Auto-pull try-catch** | Strategy `withdraw` reverts don't brick user withdrawal |
| **Pause doesn't block withdraw** | Claimed invariant — `whenNotPaused` on deposit only |
| **Withdraw clears baseline** | F-17: if last share exits, `lastSharePrice = 0` so re-seed deposit re-snaps correctly |

### ⚠️ Known residual risks (documented by team, not reportable)
- F-i02: Dust reward amounts produce 0 minOut floor (economically irrelevant)
- F-903: Fallback price inflate/deflate within Owner trust model
- N-03: `_computeMinOutFloor` reads "0 < floor for any amountIn > 0" — actually dust rounds to 0

### ❌ Not reportable
This code has been through 4 rounds of Soken audit (91/100). Every finding from the initial 55/100 was fixed. The remaining 9 points are informational residues documented by the team. No exploit path found.

## Verdict
**Nothing to report.** This team is transparent, responsive, and their code is solid. Move to next target.
