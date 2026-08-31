# Tectonic (Cronos) — $120M Price-Pump + Exchange-Rate Inflation (Aug 30, 2026)

**Lesson:** The "official" number was wrong ($74-75M per CertiK/PeckShield) — the real
take was **$120.4M in a single `borrowMax()` call**. And it was **not** an oracle trick
in one block: it was a **self-inflating collateral exchange rate** (Compound v2
`exchangeRate = (cash + totalBorrows − reserves) / totalSupply`) chained with a
**thin-liquidity price pump** on a **lagging pushed feed**. The attacker never beat an
oracle — he *bought* the price and waited for the feed to catch up.

Sources: GoPlus Security alert, BlockWatchdog full reconstruction (from Cronos archive
state — public explorer down, chain halted), our on-chain verification of the ETH side.

## Attack timeline (all times UTC, Aug 30)

- **Aug 18 14:47** — attacker EOA `0x4266a0e6a0f0ef90abcff3bb089932ca0cce3652` deploys
  the unnamed vault `0x085f3115ca368aa262246d22f9476e1e2c87e8be` (12 days early).
- **Aug 28–30** — ~5,000,950 USDC bridged to Cronos in $100–500K tranches via
  `0xcdfba496180865a71266608ade6b21ab1f788888`.
- **12:38:56** — orchestrator `0xd3aac8a1a9e412e2c590463a8b6f90125e23f1f3` + borrower
  `0x2dc6a36f4e5eeefe112c01569de96dea496bb618` deployed (same tx).
- **12:39ish — setup tx** `0x0fce5ae8d2eeb82c838e750d0e25af1564a2c7d05bf843dd1cfea102ce587d06`
  (33.2M gas, 677 logs):
  1. Deposit 5M USDC as tUSDC (CF 0.8 → ~$4M borrow power).
  2. Borrow the ENTIRE tTONIC market: 3.844T TONIC (~$4.08M at real price $1.0622e-8).
  3. Re-deposit that TONIC through the second contract.
  4. After ~12 loops, stop minting — just send TONIC to the tTONIC contract as a plain
     ERC-20 transfer (refills cash, no accounting event), borrow again.
  - **98 iterations.** End: parent debt 376.5T TONIC; child collateral 309.2T tTONIC
    (= 335.7T TONIC). TONIC total supply is 500T → the collateral claim was **67% of
    every TONIC in existence**, 14.7× all TONIC in DEX pools (~$0.5M across both sides).
  - tTONIC totalSupply: 60.06T → 369.26T in ONE tx.
- **THE SECOND INFLATION:** Compound v2 counts outstanding borrows as market assets →
  the attacker's own unbacked 376.5T TONIC debt landed in the numerator of the token he
  posted as collateral → **tTONIC exchange rate 1.354e9 → 1.0857e10 (8×)**. ~95% of the
  tTONIC market's balance sheet was the attacker's own debt.
- **12:40:39 / 12:41:29 / 12:45:25** — selector `0x7b9f30b8` ×3: borrow USDC + CRO
  against inflated collateral, buy TONIC on VVS, DONATE it back to the tToken contract
  (first attempt reverted; adjusted and retried). Fed 3,509,440 USDC + 28,163,915 CRO
  (~$5.24M, all borrowed from Tectonic itself) into the pools.
- **TONIC oracle price** (`0xd360d8cabc1b2e56ecf348bff00d2bd9f658754a`):
  $1.0622e-8 → $6.8593e-8 → $9.1889e-7 → $2.0763e-6 — **×195.5 in ~4 minutes**. "Flat
  between updates, then jumps: a pushed feed that follows the manipulated DEX price
  with a lag."
- **Collateral value:** $3.56M (12:38:56) → $23.0M (12:40:39) → $314.4M (12:45:25) →
  $710.4M (12:49:39). At CF 0.2 → $142M borrow power.
- **THE DRAIN — one call:** `0xddc9dc47d330116332ae687ba939f6d6196c4cc5950b2cdb04ae826520eeca20`,
  selector `0x26faf313` = **`borrowMax()`** — borrowed the ENTIRE cash of every market,
  matching each market's cashPrior to the unit:
  USDT $45.6M + USDC $55.2M + WBTC $7.7M + WETH $4.7M + CDCBTC $2.6M + LCRO $2.1M +
  WCRO $1.0M + CDCETH $1.0M + XRP $0.38M = **$120,375,285**. Stables split exactly
  75/25 between `0x7d4e...` and the vault; everything else 100% to the vault.
- **Cronos halts** (~block 90,907,150). At halt:
  - `0x7d4e7e5dcb0ccc66b4f0f8b0f30da5078ad4f2dc` — $60,115,712
  - `0x085f3115...` (unnamed vault) — ~$42,410,000 (13.98M USDC, 9.81M USDT, 92 WBTC,
    1,765 WETH, 32.9 CDCBTC, 349 CDCETH, 23.1M LCRO, 24.3M WCRO, 120.6K XRP)
  - `0x215adfc8...` — $7,770,094 USDC
  - Ethereum `0xc404160b79bd8905061a1caecbeca2eeab3f72dd` — **2,592.215 ETH ≈ $6.39M**
    (VERIFIED by us via eth_getBalance, Aug 31)
- ~$6M bridged to Ethereum pre-halt and swapped to ~2,600 ETH; rest frozen by the halt.

## Why "IT WAS NOT AN ORACLE TRICK IN ONE BLOCK" matters

The classic oracle attack = manipulate a spot price and borrow against it in the SAME
block before the oracle updates. Tectonic's feed is **pushed** (updates lag the DEX
price). The attacker's play exploited exactly that:
1. **Don't manipulate the feed in one block** — inflate your collateral's *exchange
   rate* first (the self-debt trick — a pure contract-logic bug in how the market
   values itself), which requires no oracle at all.
2. Then pump the DEX price with borrowed funds, and **wait** for the lagging feed to
   ratchet the collateral value up ×195.
3. Then `borrowMax()` every market's cash.

The exchange-rate inflation was the foundation; the price pump was the amplifier.

## Checklist additions (lending protocols — matches our Tier-2 thesis)

1. **`exchangeRate = (cash + totalBorrows − reserves) / totalSupply`** — borrows count
   as assets. If an actor can become a large fraction of a market's balance sheet, they
   control their own collateral's exchange rate. Check: is the rate bounded? Are
   self-borrow/supply loops capped? What fraction can one address own of a tToken?
2. **Loop-borrow with plain transfers**: after enough mint loops, cash can be refilled
   by direct ERC-20 transfers (no accounting event) — check borrow-against-cash paths
   that don't require new supply events.
3. **Thin-liquidity collateral + pushed/lagging feed**: if a collateral token has
   ~$0.5M of DEX liquidity and its feed follows the DEX with a lag, a $5M pump moves
   the "price" ×195. Flag: low-liquidity collateral, feed architecture (pushed vs
   on-demand), deviation lag.
4. **`borrowMax()` style whole-market drains**: one call that sweeps every market's
   cash — audit the max-borrow path for per-market cash limits.
5. **Reconcile severity numbers yourself**: CertiK/PeckShield said $74-75M (75% slice
   of two stables); the drain tx shows $120.4M and market balances fell $119.1M. On-
   chain totals beat press numbers.
6. **Chain halt as the circuit breaker**: Cronos halting froze ~$114M of the $120M —
   a validator-level emergency stop is sometimes the only real backstop.

## Receipts
- Drain tx (Cronos): `0xddc9dc47d330116332ae687ba939f6d6196c4cc5950b2cdb04ae826520eeca20`
- Setup tx: `0x0fce5ae8d2eeb82c838e750d0e25af1564a2c7d05bf843dd1cfea102ce587d06`
- ETH swap tx: `0xf1b9a3e6acc4f37568eba8f13907edde259cde25f96e20daf6eac41157c81c46`
- Attacker EOA: `0x4266a0e6a0f0ef90abcff3bb089932ca0cce3652`
- Orchestrator / borrower: `0xd3aac8a1...` / `0x2dc6a36f...`
- Unnamed vault: `0x085f3115ca368aa262246d22f9476e1e2c87e8be` (deployed Aug 18)
- Aggregation: `0x7d4e7e5d...`, `0x215adfc8...`
- ETH profit wallet: `0xc404160b79bd8905061a1caecbeca2eeab3f72dd` (2,592.215 ETH ✓)
- Tweets: GoPlus `2094268398662537542`, BlockWatchdog `2094245690847215803`
