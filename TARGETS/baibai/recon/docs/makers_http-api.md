> ## Documentation Index
> Fetch the complete documentation index at: https://docs.baibai.cx/llms.txt
> Use this file to discover all available pages before exploring further.

# Public data API

> Shared market metadata, inventory, fills, decompositions, and checkpoints.

The read API serves market metadata, your limits, fills, decompositions, and checkpoints. All bodies are JSON. Reads need no authentication in v0.

<Note>
  **The read API speaks integer ticks and lots**

  The WebSocket wire uses decimal strings (`"2500.1"`); the read API exposes the integer representation those decimals convert to exactly: `ticks = price / tick_size`, `lots = size / lot_size`. With `tick_size = "0.01"`, a price of `250010` ticks is `"2500.10"`. Token *amounts* (fills, balances) are decimal strings in token units everywhere.
</Note>

## `GET /health`

Returns `200` with a JSON body when the platform is up.

## `GET /v0/pairs`

The tradable pairs and their grids:

```json theme={null}
[{"name": "WETH-USDC", "base_token": "WETH", "quote_token": "USDC",
  "tick_size": "0.01", "lot_size": "0.0001", "ttl_ms": 8000, "heartbeat_ms": 1000}]
```

`base_token` and `quote_token` in this endpoint are **symbols**, not contract addresses. Obtain token addresses and decimals from the verified [deployment manifest](/takers/deployments).

## `GET /v0/book/{pair}`

The merged post-admission book, i.e. the aggregate of all makers' accepted quotes and the thing being published on-chain:

```json theme={null}
{"pair": "WETH-USDC", "seq": 812, "age_ms": 143, "feed_live": true,
 "bids": [[249990, 20]], "asks": [[250010, 20]]}
```

Levels are `[ticks, lots]`. `feed_live` says whether a maker with standing quotes currently has an open feed session; `age_ms` is the age of the freshest feed behind the levels. Handy for checking that your quotes were admitted and seeing how your book merges with everyone else's.

## `GET /v0/makers/{maker}/limits`

Your risk limits and quotable inventory:

```json theme={null}
{"inventory": [{"token": "0x…", "amount": "12.5"}]}
```

Inventory tracks your [deposits](/makers/funds) and attributed fills, less withdrawal reservations. The platform enforces inventory backing; it has no separate per-fill or total-notional caps. Set strategy limits in your maker.

The full response also includes lowercase `maker` and an atomic `ledger` object. Before quoting, require `ledger.ready: true` and sufficient `inventory`. Inspect `ledger.reason` when it is false; stale or unconfirmed inventory is not safe quoting capacity.

`ledger.balances` lists each served token with exact decimal-string `balance`, `reserved`, `available`, and `net_capital`. `available = max(balance - reserved, 0)`; production `inventory` reflects these available amounts. The ledger also includes `deployment_id`, `inventory_revision`, `durable_inventory_revision`, `next_block`, `scanned_block_hash`, `observed_head`, `observed_head_timestamp_ms`, `last_successful_scan_ms`, and per-pair `fill_seqs`. These describe one completed durable generation. The separate `watcher` object reports the current scan target.

Do not treat `GET /health` as an inventory-readiness check. A missing canonical state, startup catch-up, an integrity halt, a failed write, or ledger data older than five seconds can make `ledger.ready` false while the process remains reachable.

### Funding counters for P\&L

Each `ledger.balances` row includes signed `net_capital`: deposits minus executed withdrawals in token units since `ledger.capital_flow_start_block`. Fills and reservations do not move that counter. The balance, counter, origin and ledger cursor are one durable snapshot. On first connection, record the counter with your initial account value. Thereafter, exclude changes in capital from trading P\&L; value base-token cash flows at your chosen mark when observed. An upgraded ledger may start these counters after its original deployment, so do not treat them as lifetime totals. A changed origin requires explicit reconciliation, not a silent reset.

## `GET /v0/fills?pair={pair}`

Recent on-chain fills, newest last:

```json theme={null}
[{"fill_seq": 4213, "pair": "WETH-USDC", "timestamp_ms": 1787664000500,
  "taker_side": "buy", "amount_in": "7.500401", "amount_out": "0.003"}]
```

`fill_seq` is the on-chain fill counter, strictly ascending within the market, and the key for decompositions and [fill frames](/makers/fills). Note the amounts here are the whole on-chain trade, not your leg. The feed retains at most 256 rows per pair and has no pagination; persist your own history. Each row also has `taker` (the caller, or `null` for rows recorded before fees) and `fee: {taker, token, amount}`. For pre-fee rows, `fee.taker` is also `null` and `fee.amount` is a decimal-string zero. The fee is denominated in the output token. `amount_out` is the taker’s net receipt; maker attribution uses the full curve output, `amount_out + fee.amount`.

## `GET /v0/fills/{fill_seq}/decomposition`

The attribution result for one fill, i.e. how the trade split across makers. `fill_seq` counts per market, so name the market with `?pair=WETH-USDC`; you may omit it only on a gateway that serves a single market.

```json theme={null}
{"fill_seq": 4213, "pair": "WETH-USDC", "curve_seq": 812,
 "legs": [{"maker": "<maker address>", "price_ticks": 250010, "size_lots": 20,
           "amount_in": "5.0002", "amount_out": "0.002"},
          {"maker": "<maker address>", "price_ticks": 250020, "size_lots": 10,
           "amount_in": "2.5002", "amount_out": "0.001"}],
 "residual": "0.000001", "rounding": "0",
 "compression_residual": "0.000001", "status": "final"}
```

Each leg is one maker at that maker's streamed price. `residual` is the signed compression gap that [Spire covers](/makers/fills-and-latency#staleness-and-the-residual). Its quote-unit value includes token rounding: `residual = rounding + compression_residual`. Maker totals plus signed residual reconcile to the full curve amounts (`amount_out + fee.amount` on the output side). The decomposition also includes `fee: {taker, token, amount}`; this amount belongs to the taker’s ledger row and is separate from maker legs. For the order adapter, a maker’s legs split further into the order fills reported by `userFills`.

Check `status` explicitly. `"pending"` returns empty legs and zero residual when no attributed result is available, including an unknown sequence; it does not guarantee that the sequence will appear. `"final"` identifies a completed result. Discover actual sequences through `/v0/fills` or on-chain events.

## `GET /v0/checkpoints/latest`

The latest published ledger checkpoint; see [Deposits & withdrawals](/makers/funds#checkpoints):

```json theme={null}
{"id": 17, "timestamp": 1787664000, "ack_fill_seqs": {"WETH-USDC": 4213},
 "balances": [{"maker": "0x…", "balances": [{"token": "0x…", "amount": "10250.75"}]}]}
```

`ack_fill_seqs` is the highest fill in each market these balances include.

## `GET /v0/fees`

Returns `takers`, one row for each taker credited a fee. Each row contains `taker` and `fees: [{token, accrued, balance}]`, with exact decimal-string amounts. `accrued` is the cumulative credited fee and `balance` is the address’s current ledger balance in that token.

Bracket billing periods with two reads of `accrued`. The current balance also includes withdrawals, deposits, and maker legs if that address trades as a maker; it is not a fee-only counter. Fee income does not increase `net_capital`. Payout uses the ordinary custody withdrawal flow, subject to control of the credited address.
