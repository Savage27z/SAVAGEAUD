> ## Documentation Index
> Fetch the complete documentation index at: https://docs.baibai.cx/llms.txt
> Use this file to discover all available pages before exploring further.

# Curves and allocation

> How quotes become curves, maker allocation, staleness, and public data.

How maker liquidity becomes an executable curve, how fills are allocated, and which data is public. These platform mechanics apply across maker adapters.

## Maker settlement and taker execution

Takers execute against the on-chain curve. The merged book is also public through the read API. Spire merges every maker's accepted quotes, compresses the merged book into a piecewise-linear curve, and posts that curve on-chain. Takers swap against the curve. When a swap lands, the platform replays it against the exact merged book snapshot that curve was built from and pays each maker at the price that maker streamed.

Two consequences:

* Each constituent leg settles at its streamed price, with its quote amount floored to the quote token's smallest unit. The curve's price never appears in your leg.
* The difference between what the taker paid on the curve and the sum of maker legs is the residual, and it is Spire's in both directions. It is not shared with you, and it is not charged to you.

## Equal prices split pro-rata, not by time

A fill walks the snapshot best price first, and at equal price it is split pro-rata by posted size, with largest-remainder rounding and a deterministic tie-break by maker address. Being first to a price buys you nothing; posting more size at it does.

## Books are the platform's liquidity model

BaiBai records one book per maker and pair. An adapter translates the maker's quote or order messages into that book. The [Hyperliquid-compatible interface](/makers/hyperliquid-compatible#supported-orders) accepts individual orders, modifications, and cancellations. The gateway builds the per-maker book from their remaining sizes.

Attribution tracks consumption across consecutive fills against each published snapshot, so later fills cannot reuse depth already consumed. The publisher also limits offered liquidity by current unreserved inventory.

## Staleness is yours

Quotes pass through several steps: the gateway accepts your update, the publisher compresses the merged book and posts it about once per block, and the taker executes against the curve available on-chain. Maker legs are priced from the recorded snapshot behind that curve. A market move in between is your risk.

Quote expiry and liveness controls bound exposure. Your adapter's protocol guide explains how to use them. There is no last look: an acknowledged update or cancellation changes the gateway book first, and an earlier on-chain curve may remain executable until replaced or expired. Do not treat a sent-but-unacknowledged update as live.

## Fill timing

On-chain execution and attribution happen before notification delivery. Plan for the delay when managing inventory and hedging. Read [Settlement and fill latency](/makers/fills-and-latency) for the timing, confirmation, and reconciliation model; each adapter documents its own notification format.

## What is public

The read API needs no authentication. It exposes accepted quotes and ledger data as well as information derived from on-chain events:

* `GET /v0/book/{pair}`: the merged book of every maker's accepted quotes, aggregated by price. It does not name makers.
* `GET /v0/fills?pair=…`: every on-chain fill with its whole amounts, the taker's direction, and its `fill_seq`.
* `GET /v0/fills/{fill_seq}/decomposition?pair=…`: every leg of a fill, each with the maker's address, streamed price, size, and amounts, plus the residual.
* `GET /v0/checkpoints/latest`: every maker's ledger balance per token, by address.
* `GET /v0/makers/{maker}/limits`: any maker's quotable inventory and funding counters, by address.

So another maker can read which address filled what at which price, and what every address holds in the ledger. Your quotes are attributable to your address by anyone who reads the decomposition, and your deposits and withdrawals are on-chain under that address in any case. If that matters to you, quote from an address you are willing to have read this way. The Hyperliquid adapter also exposes public `openOrders` queries by master address.

## Funds move on-chain, with a delay

There is no instant withdrawal. The watcher reserves a requested withdrawal out of quoting inventory after observing its mined event, the platform settles a claim on-chain after a fresh checkpoint, and you execute the claim after the custodian's `withdrawDelay()` (600 s on Base; read the contract value before withdrawing). Deposits are credited when the platform's watcher sees the `Deposited` event, not when the transaction mines. Details in [Deposits & withdrawals](/makers/funds).

## Fees

Maker fees are negotiated with Spire on a case-by-case basis and settled separately. Reported fill amounts and balances do not deduct these charges.
