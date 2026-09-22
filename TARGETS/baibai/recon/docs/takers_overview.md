> ## Documentation Index
> Fetch the complete documentation index at: https://docs.baibai.cx/llms.txt
> Use this file to discover all available pages before exploring further.

# Direct on-chain takers

> Integrate BaiBai as an on-chain liquidity source.

DEX aggregators, routers, and bots can read a price from `BaibaiCurveBook` and execute an exact-input swap through `BaibaiEntrypoint`. The taker sends a normal on-chain transaction and approves the entrypoint to spend its input token. No separate account, off-chain quote request, or order signature is required.

## Contracts and pricing

Liquidity is published on-chain as a piecewise-linear curve. Read `entrypoint.quoteFor(base, tokenIn, amountIn, caller)` for the net quote that includes any configured fee, and use the entrypoint to execute it.

Each deployment has three upgradeable contracts:

| Contract           | Taker interface                                                                                                                                               |
| ------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `BaibaiEntrypoint` | Executes `swapExactAmountIn` and emits `Fill`. This is the ERC-20 approval target.                                                                            |
| `BaibaiCurveBook`  | Provides `quote`, `pair`, and `knot` views for pricing and depth. Discover it through `entrypoint.curveBook()`.                                               |
| `BaibaiCustodian`  | Holds pooled maker inventory and pays output directly to the recipient. Discover it through `entrypoint.custodian()`; takers do not call its payout function. |

All pairs share a quote token, readable through `quoteToken()` on the entrypoint or curve book. Each pair is identified by its base token address. For WETH-USDC, `base` is WETH; there is no separate pair ID or pool contract per pair.

A reanchor changes mid, spread, and depth without replacing knots. A shape update replaces the knots and resets the fill cursors. Every successful update increments the pair's `seq` and emits `CurveUpdated`. Each swap increments `fillSeq` and consumes base depth on the relevant side. Earlier fills can therefore change the price available to your transaction.

## Freshness

A curve expires when either its authenticated `validUntil(base)` deadline or its inclusion-based TTL expires. The TTL is read from `ttl()` and measured from `pair(base).lastUpdateAt`. A zero TTL disables only the inclusion-based limit; the authenticated deadline still applies.

After expiry, `quote()` returns zero and swaps revert with `CurveStale()`. The publisher bounds the authenticated deadline by the contributing maker feeds, so a delayed publication cannot renew old quotes indefinitely. Read both limits from the target deployment; do not assume a fixed refresh interval or TTL.

## Execution guarantees and limits

* **Exact input, atomic settlement.** Specify `amountIn`, `minAmountOut`, and a recipient. Input is pulled from the caller into the custodian; output goes directly to the recipient. A failure reverts the entire swap, including cursor changes and transfers.
* **Shared pricing logic.** A nonzero `quoteFor` for the actual entrypoint caller matches the swap’s net pricing in the same executable state. It does not reserve liquidity or check the caller's balance, allowance, or the custodian's available inventory.
* **Per-caller taker fees.** Spire can configure a fee for an integrator’s address, with a per-pair override. The fee is retained in custody and credited to that caller’s ledger row. Ordinary callers with zero configured fee receive the full curve output. Network transaction fees still apply.
* **No partial fills or exact-output entrypoint.** Amounts beyond posted depth revert. To target an output, search exact-input quotes off-chain and enforce `minAmountOut`.
* **ERC-20 tokens only.** Use WETH for ETH exposure. The entrypoint does not wrap or unwrap native ETH.
* **One pair per call.** A router can compose multiple calls into a route.
* **No built-in transaction deadline.** Enforce one in your router if needed. Curve expiry is not a user-specified transaction deadline.

The entrypoint has no taker allowlist or combined `updateAndSwap` method.

<Columns cols={2}>
  <Card title="Quoting and swapping" icon="arrows-rotate" href="/takers/quoting-and-swapping">
    ABI, expiry checks, approvals, errors, events, and a TypeScript example.
  </Card>

  <Card title="Deployments" icon="server" href="/takers/deployments">
    Chain, token and proxy addresses, and contract discovery.
  </Card>
</Columns>
