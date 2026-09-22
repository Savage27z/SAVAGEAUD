> ## Documentation Index
> Fetch the complete documentation index at: https://docs.baibai.cx/llms.txt
> Use this file to discover all available pages before exploring further.

# How BaiBai Works

> BaiBai combines PropAMMs, custom sequencing, and synchronous composability to deliver the best execution on Base.

## How it works

BaiBai is a PropAMM exchange built on Spire Labs' [Pylon](https://www.spire.dev/pylon).

Unlike traditional AMMs, each liquidity pool on BaiBai is a PropAMM pool where professional market makers continuously update their pricing, inventory, and risk models directly onchain. This enables tighter spreads, deeper liquidity, and better execution for traders.

## 1. High-performance blockspace for market makers

Market makers continuously adjust their quotes as market conditions change.

BaiBai provides dedicated blockspace optimized for these updates, allowing makers to refresh their liquidity at high frequency with low latency and near-zero transaction costs.

These allow market makers to continuously update quotes at high frequency.

## 2. Protection against adverse selection

One of the biggest costs for market makers is adverse selection. When the market moves, stale quotes can be exploited before they are updated, forcing makers to widen spreads and reduce available size.

BaiBai introduces programmable sequencing rules designed specifically for market making.

These include:

* Maker price updates receive execution priority
* Speed bumps for latency-sensitive toxic flow
* Selective adverse selection controls

By reducing stale quote exploitation, market makers can quote tighter spreads while showing larger size.

## 3. Smart liquidity routing

BaiBai is both a PropAMM and a smart liquidity router. Every trade first checks available PropAMM liquidity. If the requested size cannot be completely filled at the best price, BaiBai automatically routes the remaining amount to external liquidity sources.

For example:

* A BaiBai market maker fills 20% of an order at a better price than other venues.
* The remaining 80% is routed to other onchain liquidity.
* The user receives the best available execution across all available sources.

This allows users to benefit from PropAMM pricing without sacrificing access to the broader liquidity ecosystem.

## 4. Synchronous composability

Most high-performance appchains isolate liquidity from the rest of the ecosystem. BaiBai avoids this tradeoff through Pylon's synchronous composability.

Because BaiBai can synchronously interact with the underlying settlement chain within a single transaction, users do not need to bridge assets, and aggregators can access BaiBai liquidity just like any other onchain venue.

From the user's perspective, BaiBai behaves like a native part of the Base ecosystem while providing the performance and customization of a dedicated exchange.

## The result

By combining programmable market making, specialized sequencing, high-frequency quote updates, and smart routing, BaiBai delivers better execution than traditional passive AMMs while remaining fully composable with the rest of the onchain ecosystem.

Users receive tighter spreads, deeper liquidity, and consistently better prices, while market makers can deploy sophisticated trading strategies directly onchain.
