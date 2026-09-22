> ## Documentation Index
> Fetch the complete documentation index at: https://docs.baibai.cx/llms.txt
> Use this file to discover all available pages before exploring further.

# Settlement and fill latency

> On-chain execution, delayed fill reports, attribution, and reconciliation.

A taker swap can consume liquidity from several makers and several price levels. Each maker settles only its own execution, using its recorded prices and exact token amounts. An adapter changes how you submit quotes and receive reports; it does not remove the on-chain execution and attribution steps.

## Fills arrive after the chain, in seconds

A fill starts with an on-chain swap. Notification latency includes block inclusion, the platform observing the event, attribution to the recorded maker books, and delivery to your client. Plan for notifications to arrive seconds after execution rather than as an immediate exchange matching response.

The chain watcher currently polls every 500 ms. The Hyperliquid-compatible interface sends order and fill updates after their durable attribution generation commits. These intervals are not a guaranteed execution-to-notification deadline. See that adapter's [fill messages](/makers/fills) for its delivery and recovery rules.

Until a notification arrives, an earlier published curve may already have consumed some of your inventory. Manage exposure across that delay; a faster message format cannot make a fill observable before the platform has seen and attributed it.

## Confirmation and chain reorganizations

An observed and attributed fill belongs to the platform's current canonical branch. This does not mean Ethereum finality. A detected canonical-history mismatch halts inventory readiness, new publication, and withdrawal settlement until an operator reconciles the ledger and any orphaned notifications.

## How settlement is computed

1. The on-chain fill identifies the published curve, which is bound to the exact recorded maker books used to build it.
2. Attribution walks the available snapshot best price first. It tracks consumption across consecutive fills against that curve, so a later fill cannot reuse depth already consumed.
3. At equal prices, allocation is pro-rata by posted size, using largest-remainder rounding and a deterministic tie-break by maker address.
4. Each constituent leg uses that maker's streamed price. Its quote amount is floored to the quote token's smallest unit. The exact attributed token amounts, rather than a floating-point recomputation, determine your balance change.

A maker is never allocated more than the available depth in the recorded snapshot. The publisher also bounds offered liquidity by current unreserved inventory.

## Staleness and the residual

Staleness is your market risk. A leg uses the snapshot behind the curve the taker hit, not your newest update. An acknowledged cancel or replacement changes the gateway book first; an earlier publication may still execute until replaced or expired on-chain.

The difference between taker execution and maker settlement is Spire's signed residual. Spire absorbs it in both directions; it is not charged to maker legs. The public decomposition separates token rounding from the compression residual. This interface makes no promise about the residual's size.

## Auditing fills and balances

* `GET /v0/fills?pair=WETH-USDC` returns up to 256 recent on-chain fills, newest last. It is a discovery feed, not a complete historical export. Persist your own records.
* `GET /v0/fills/{fill_seq}/decomposition?pair=WETH-USDC` returns the curve sequence, all maker legs, and residual. Check `status`: `"pending"` means no attributed result is available yet; `"final"` is the completed result. Do not infer completion from whether `legs` is empty.
* `GET /v0/checkpoints/latest` returns the latest checkpoint and the highest included fill sequence per market. The configured cadence is 60 seconds on Base, and a fresh checkpoint is required before withdrawal settlement.

Between checkpoints, reconcile attributed trading flows **and** deposits and executed withdrawals. Reservations affect available quoting inventory but do not themselves move the raw ledger balance. Funding counters on [maker limits](/makers/http-api#funding-counters-for-p%26l) help separate capital movements from trading P\&L. Withdrawing ledger balances requires the [on-chain withdrawal flow](/makers/funds#withdrawing).
