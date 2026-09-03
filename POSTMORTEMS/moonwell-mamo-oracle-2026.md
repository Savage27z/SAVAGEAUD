# Moonwell (Base) — MAMO oracle pump 3,970%, ~$8.7–9.1M (Aug 27, 2026)

**Lesson:** A **3,970% price move on a collateral you can also buy** converts a thin
market into unlimited borrowing power when the collateral factor ignores market depth.
The second trick is the keeper for audits: the attacker **beat the supply cap by plain
ERC-20 transferring** MAMO straight into the mMAMO token contract — transfers to a
cToken-style contract are not "supply" and don't count against the cap, but they DO
count as balance for collateral math. Check every cap against every balance-changing
path, not just the deposit function.

Sources: BlockSec Aug newsletter (full breakdown), PeckShield alert (Aug 27), Moonwell
incident postmortem.

## What happened (plain English)

MAMO is a low-liquidity token listed as borrowable collateral on Moonwell's Base
deployment with a **50% collateral factor** — every dollar of price rise = 50¢ of
borrow power, and its Chainlink feed tracked a market so thin that one buyer could push
it.

1. Attacker bought ~**94.31M MAMO** across DEXes.
2. MAMO/USD feed driven from ~$0.0106 to a **peak of $0.4313 (+3,970%)**; Moonwell
   valued collateral up to ~$0.4025 (~3,698% above pre-attack).
3. Supplied 15.09M MAMO formally + **transferred 53.39M MAMO directly to the mMAMO
   contract** — bypassing the supply cap (direct transfer ≠ supply event) while still
   counting as held balance.
4. mMAMO position ≈ 55.51M MAMO → collateral worth ~$22.34M → ~$11.17M borrowing
   capacity.
5. **18 borrows totaling $11.03M**, then ~$8.73M USDC moved to Ethereum.
6. Price collapsed back; the borrowed value left as bad debt on the MAMO market.

Loss: ~$8.7M (PeckShield) / ~$9.1M (BlockSec).

## Why the oracle wasn't "hacked"

The Chainlink feed itself wasn't compromised — it was **driven**. MAMO's liquidity was
so concentrated that ~$1-3M of buys moved the aggregated price ~40x. The feed reported
a "real" but manipulated market. Classic lending-protocol gap: **collateral factor
(50%) was set for a token whose real liquid depth supported maybe a 5% factor**, and
there was no borrow/supply cap sized to the market, no deviation guardrail, and no
liquidation capacity for a 40x snap-back.

## Attack receipts

- Date: Aug 27, 2026 | Chain: Base | Market: MAMO
- ~94.31M MAMO bought pre-attack; 15.09M supplied + 53.39M direct-transferred to mMAMO
- 18 borrows ≈ $11.03M; ~$8.73M USDC bridged to Ethereum
- Sources: BlockSec newsletter (https://blocksec.com/blog/defi-security-incidents-cosmos-evm-moonwell), PeckShield X alert

## Checklist additions (lending protocols)

1. **Supply-cap bypass via direct transfer to the token contract.** Any balance that
   counts for collateral but was never "deposited" through the gated path. Test:
   transfer tokens straight to the market contract — does the cap still apply? Do
   interest/collateral math read raw balance?
2. **Collateral factor vs market depth, not vs price.** 50% CF on an asset where $2M
   moves price 40x = free money. Cross-check CF against DEX liquidity depth + the
   feed's own deviation bounds. Low-liquidity collateral deserves supply caps,
   borrow caps, and liquidation headroom sized to reality.
3. **Feed that tracks a thin market**: Chainlink aggregators follow the market; if the
   market is one pool, the feed is one pool. Treat "oracle manipulation" as a
   liquidity problem first.
4. **Snapshot the collateral ratio on the way down** — when price snaps back the bad
   debt is already booked; "liquidation capacity" must mean liquidators can actually
   sell the collateral, not that the math says they could.

## Sources
- BlockSec Aug newsletter: https://blocksec.com/blog/defi-security-incidents-cosmos-evm-moonwell
- PeckShield alert Aug 27, 2026 (PeckShieldAlert)
