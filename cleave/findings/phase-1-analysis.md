# Cleave — Phase 1: Architecture & Contract Analysis

## How Cleave Works

Cleave splits 1 asset into two tokenized positions:

**Split** — Deposit 1 ETH → mint P tokens (Earn) + N tokens (Boost)
**Merge** — Return P + N tokens → withdraw 1 ETH (before maturity)
**Redeem** — After maturity, oracle tells the price → P gets capped return, N gets the rest

Collateral is always 1:1 with the token pair. No margin, no liquidations.

### Example (ETH series with $2000 strike)
- Deposit 1 ETH at strike $2000
- **P (Earn):** gets ETH if price < $2000 at maturity, or $2000 worth of ETH if price > $2000 (capped upside)
- **N (Boost):** gets $0 if price < $2000, or (price - $2000) worth of ETH if price > $2000 (leveraged upside)

So P = covered call seller, N = call buyer. The two always add back to 1 ETH worth.

## Contract Architecture

```
SplitFactory (immutable)
  └── createSeries() → Series (CREATE2)
       ├── SplitToken P (Earn)
       ├── SplitToken N (Boost)
       ├── IPriceOracle (external)
       └── Collateral (ETH or ERC-20)
```

### SplitFactory
- **Immutable** — no upgrade path, no admin keys
- Creates one Series per unique (collateral, strike, maturity, oracle) tuple
- Tracks all series in an array + mapping
- Uses CREATE2 for deterministic addresses

### Series
- Standard ERC-4626-like vault logic but for split/merge/redeem
- **ReentrancyGuard** on all mutative functions
- **SafeERC20** for token transfers
- Has a maturity timestamp — operations split/merge before maturity, redeem after
- Stores oracle address — calls `getPrice()` from `IPriceOracle` interface

### SplitToken (P and N)
- Simple ERC-20 with `mint()` and `burn()` — only the Series contract can call these
- No transfer restrictions, standard ERC-20

## Key Functions

### split(amount)
Before maturity. Deposit `amount` of collateral → mint P + N tokens at 1:1 ratio.
Each P or N token represents 1 unit of the split position.

### merge(pAmount, nAmount)
Before maturity. Return P + N tokens → withdraw collateral.
Requires equal amounts of P and N.

### redeem(pAmount, nAmount)
After maturity. Oracle price determines payout.
- If price ≤ strike: P gets all (up to strike value), N gets 0
- If price > strike: P gets strike value, N gets remainder

### addCollateral(amount) / removeCollateral(amount)
Adjust position by adding/removing collateral. Used before maturity.

## Trust Model

| Trust Assumption | Verdict |
|---|---|
| **Oracle returns correct price at maturity** | ⚠️ No admin keys to override bad oracle data |
| **Immutable contracts = no patch possible** | ⚠️ If a bug is found, there's no upgrade — funds locked until maturity |
| **No owner/admin keys** | ✅ No rug, no parameter changes |
| **ReentrancyGuard on mutative functions** | ✅ Standard protection |
| **SafeERC20** | ✅ Standard protection |

## Initial Attack Surface Areas

1. **Oracle failure** — If oracle reverts/returns zero at maturity, redeem fails. No fallback.
2. **Rounding in split/merge** — Floor division could leave stuck dust in the contract
3. **First-depositor** — Ratio manipulation if first depositor gets to set the baseline
4. **Reentrancy:** split → oracle callback? merge → token callback? redeem → token callback?
5. **Maturity edge cases** — Can you split AFTER maturity? Can you redeem BEFORE maturity?
6. **P + N token math** — Do the two pieces always sum to exactly the collateral value?
