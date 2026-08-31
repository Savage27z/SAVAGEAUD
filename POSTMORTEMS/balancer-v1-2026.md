# Balancer V1 BPool — $234K Legacy Fixed-Point Rounding Exploit (Aug 31, 2026, Ethereum)

**Lesson:** Legacy versions still hold money. Balancer V1 was retired, but this BPool
(`0x2257aaac...`) still held DPI/USDC/WETH/WBTC — and the V1 math was exploitable.

## The mechanism (SlowMist root cause)

- `joinswapPoolAmountOut` lets the CALLER specify the BPT output amount, then
  `calcSingleInGivenPoolOut` reverse-computes the required input via **18-decimal
  fixed-point math**.
- Attacker **compressed WBTC reserves to dust** via public swaps (nested flash loans:
  Spark/Aave, Morpho, Uniswap V3) → the reverse-computed input **rounded down to 1
  satoshi of WBTC** — yet the FULL BPT amount was minted.
- Missing validations: **minimum effective input, minimum pool balance, and
  relative-error validation**. `MIN_BALANCE` exists but is only enforced in
  `bind`/`rebind` — not against live reserve compression.
- Result: **4,408.8 BPT minted at 1-satoshi-WBTC per join**, then proportionally
  exited to drain the pool's DPI, USDC, WETH, WBTC (~$234K).

## Receipts (verified)
- Attacker EOA: `0x338c7ec9befbb451d66fd8a468c32184f5689a41` (verified: EOA)
- Attack contract: `0x9caa8d0e44b22f50057d2f4ce0d1446529e11be3` (verified: attack tx `0x72510b25...` from attacker → this contract, status ok)
- Vulnerable pool: `0x2257aaac34bcb27900291f7b84ee2565a6cbac57` (verified: "Balancer Pool Token", contract)
- More txs: `0xeef31155...`, `0x37e47f0f...`, `0xbaedc537...`, `0xb2d84f92...`

## Checklist additions (legacy + fixed-point math)

1. **Retired versions are still targets**: any "deprecated"/"V1" contract still holding
   user funds is in scope (Balancer V1 BPool, Visor/Gamma legacy hypervisors, Ajna v1
   clones). The version label is not a security boundary.
2. **Caller-specified output + reverse-computed input**: when a function lets the caller
   pick the output amount and derives the input from a fixed-point formula, check what
   happens when the formula's inputs are compressed toward dust. Rounding to 1 wei/
   satoshi with full output minted = free money.
3. **Guard placement**: `MIN_BALANCE`-style checks enforced only at bind/rebind don't
   protect against LIVE reserve compression via public swaps. Guards must run at
   interaction time.
4. **Relative-error validation**: compare computed input vs actual pool balance; a
   tolerance/relative-error check on reverse-computed values kills dust-rounding
   exploits.
