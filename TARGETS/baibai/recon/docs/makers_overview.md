> ## Documentation Index
> Fetch the complete documentation index at: https://docs.baibai.cx/llms.txt
> Use this file to discover all available pages before exploring further.

# Market makers

> Provide spot liquidity on Base through exchange-compatible order APIs.

BaiBai lets market makers provide on-chain liquidity through exchange-compatible order APIs. Spire operates the platform and publishes the combined liquidity as a curve on Base. Takers swap against that curve; each maker settles at the prices in its recorded book.

To get started, contact [Spire](mailto:hello@spire.dev). Maker access requires Spire's approval of your master wallet. See [Onboarding](/makers/onboarding) for current availability and endpoints.

## Integration

Spire can build adapters around the exchange APIs your systems already use, including CEX APIs. Adaptation can cover authentication, WebSocket and HTTP message formats, order or quote submission, and fill reporting. The goal is to let you reuse your existing integration. Tell us which API you use during [onboarding](/makers/onboarding) so we can agree the adapter scope.

Start with the general maker docs for [curves and allocation](/makers/trading-and-allocation), [settlement and fill latency](/makers/fills-and-latency), and [funding and withdrawals](/makers/funds). Protocol-specific instructions are grouped by adapter in the sidebar.

The **[Hyperliquid-compatible](/makers/hyperliquid-compatible)** section covers the spot order adapter. Additional exchange-compatible adapters are planned, with their own integration guides as they become available.

1. Coordinate maker access and choose an integration with Spire.
2. Fund your master wallet's inventory and wait for available funds.
3. Follow your adapter's guide to publish and manage quotes.
4. Persist fill reports, reconcile balances, and account for notification delays.
5. Use the on-chain withdrawal flow to withdraw funds.

## Trading model

BaiBai stores one book per maker and pair. Fills walk the recorded books best price first; makers at the same price share allocation in proportion to posted size. A fill can span several levels. The order adapter reports each order execution; the public attribution API also exposes exact aggregate amounts.

Taker execution uses the compressed curve. The difference between taker execution and maker settlement belongs to Spire in both directions. Makers bear market risk on their quoted prices, including changes before an earlier published curve is replaced or expires. See [Trading and allocation](/makers/trading-and-allocation).

Quoting requires no on-chain transaction or gas from you. Funding and withdrawals do. Assets share one vault, with individual balances maintained in the platform ledger; read [custody and operator powers](/makers/funds#custody-design).

Maker fees are negotiated with Spire on a case-by-case basis and settled separately. API fill amounts and balances do not include those charges.

This guide covers makers. Aggregators and other takers should start with [For takers](/takers/overview).
