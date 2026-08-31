# Ajna V2 — $775K Liquidation-Accounting Exploit (Aug 28-29, 2026, Ethereum)

**Lesson:** An oracleless, immutable, no-governance lending protocol was drained through
its OWN internal liquidation math — no oracle to spoof, no governance to flip. "They
force the contract to calculate a distorted price and exploit it before the transaction
ends." The attack targeted the accounting in `bucketTake`, not a price feed.

## The mechanism (three interacting properties)

Per public analysis, the liquidation code path combined:
1. **`bucketTake` can mint LP to the taker** — during a bucket take, the taker receives
   LP that is freshly minted, sized by the internal bucket pricing.
2. **`removeCollateral` can pull against that freshly minted LP** — collateral leaves
   the pool against the just-created LP.
3. **`settle` can move leftover collateral out of the pool when `quoteRepaid` is zero.**

A public, unprivileged actor minted inflated LP, pulled collateral, and left debt stuck
in auction. Pools hit (7 paired-collateral markets): syrupUSDC $173.7K, wstETH $159.8K,
rETH $127.4K + $15.6K, cbETH $124.8K + $12.1K, WBTC, WETH/USDC, sDAI. Total ~$775K —
**more than Ajna's own TVL at the time** (30-day TVL variation −54.2%).

Example (cbETH harvest tx): the ERC20Pool lost ~48.13 cbETH and gained 3.47 WETH —
~$133K collateral out vs ~$8.5K quote in.

## Timeline & context

- ~15:16 UTC Aug 28 — attack contracts deployed.
- Defimon's detection stack flagged the prepared attack **>1 hour before the first
  exploit tx**; Discord notification to the Ajna team went unactioned.
- 04:58 UTC Aug 29 — Ajna acknowledged, told users to withdraw quote tokens, repay
  loans, stop interacting.
- Ajna's own audit history contains PAST findings on "take" computations during
  liquidation and bucket-state accounting, previously deemed fixed — the class
  persisted.
- **Open item:** were the affected pools legacy July-2023 v1 clones, or January-2024
  factory deployments with the same code path? (The legacy-version question again.)

## Checklist additions (liquidation accounting — Ajna class)

1. **Every liquidation primitive that can mint LP**: `bucketTake`-style functions that
   create taker LP must have the LP value bounded by REAL collateral moved — never by
   internal price alone. Trace mint → pull → settle as one flow: can a single actor
   mint, pull, and settle in one tx for a net positive?
2. **`settle` with zero quote repaid**: leftover collateral moving out of the pool
   when `quoteRepaid == 0` is a smell. Check the condition set that permits collateral
   exit.
3. **"Price distortion before the tx ends"**: oracleless designs self-price via bucket
   state — if the attacker can move bucket/price state mid-tx (flash-loan style),
   every read of that state is manipulable. Check what the internal price is derived
   from and who can move it.
4. **Re-check "fixed" findings**: Ajna's audit history had take/accounting findings
   marked fixed — the variant survived. Same lesson as version-diff: past findings are
   a map of where the class lives, not proof it's gone.
5. **Legacy clones**: verify whether live pools are v1 clones vs factory v2 — the
   deployed code path is what matters, not the version label.

## Receipts
- Defimon pool-by-pool table: x.com/DefimonAlerts/status/2093632180656263283
- Ajna ack: 04:58 UTC Aug 29 (cryptotimes/cryptopolitan coverage)
- Attack contracts deployed ~15:16 UTC Aug 28
- Related (same alert batch): Aztec abandoned DeFi contracts drained $2.1M via
  incomplete proof verification; Lazy Summer Protocol $6.04M (Jul 6, 2026) — stale-asset
  donation bug class.
