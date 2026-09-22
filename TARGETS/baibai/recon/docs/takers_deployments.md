> ## Documentation Index
> Fetch the complete documentation index at: https://docs.baibai.cx/llms.txt
> Use this file to discover all available pages before exploring further.

# Deployments

> Base contract addresses, tokens, and contract discovery for on-chain takers.

## Base mainnet

| Network      | Chain ID | Pair      |
| ------------ | -------- | --------- |
| Base mainnet | 8453     | WETH-USDC |

Use these proxy addresses for the WETH-USDC integration:

| Contract                                              | Verified proxy address                                                                                                |
| ----------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------- |
| `BaibaiEntrypoint` — swaps and ERC-20 approval target | [0x98c1D9E102Eb2806D902b13186BDc7892aC4fFBa](https://basescan.org/address/0x98c1D9E102Eb2806D902b13186BDc7892aC4fFBa) |
| `BaibaiCurveBook` — pricing and depth                 | [0x604d9b9eB1e1571C78661a6C1088427EC9c8c6E5](https://basescan.org/address/0x604d9b9eB1e1571C78661a6C1088427EC9c8c6E5) |
| `BaibaiCustodian` — maker inventory                   | [0xAaC48FEB93c5C97E0fb3c7C57E1633922A4ACDa3](https://basescan.org/address/0xAaC48FEB93c5C97E0fb3c7C57E1633922A4ACDa3) |

| Token        | Address                                                                                                               | Decimals |
| ------------ | --------------------------------------------------------------------------------------------------------------------- | -------- |
| WETH — base  | [0x4200000000000000000000000000000000000006](https://basescan.org/address/0x4200000000000000000000000000000000000006) | 18       |
| USDC — quote | [0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913](https://basescan.org/address/0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913) | 6        |

Use the [read ABI](/takers/quoting-and-swapping#read-abi) with the curve book proxy and the [swap ABI](/takers/quoting-and-swapping#swap-abi-and-approvals) with the entrypoint proxy. Implementation contracts are not routing or approval targets.

## Discover and verify the contracts

Configure the **proxy** addresses above and check the following on Base:

| Read                             | Contract                  | Check                                                                     |
| -------------------------------- | ------------------------- | ------------------------------------------------------------------------- |
| `eth_chainId`                    | RPC                       | Must be `8453` for Base mainnet.                                          |
| `curveBook()`                    | Entrypoint                | Discover the pricing proxy.                                               |
| `custodian()`                    | Entrypoint                | Discover the inventory vault proxy.                                       |
| `quoteToken()`                   | Entrypoint and curve book | Must agree with the published quote token.                                |
| `entrypoint()`                   | Curve book and custodian  | Must point back to the configured entrypoint.                             |
| `curveBook()`                    | Custodian                 | Must match the pricing proxy.                                             |
| `decimals()`                     | Each ERC-20               | Interpret input and output in token atomic units.                         |
| `pair(base).qUnit`               | Curve book                | Nonzero means the base has been listed; it does not prove live liquidity. |
| `ttl()` and `validUntil(base)`   | Curve book                | Read both expiry bounds.                                                  |
| `quote(base, tokenIn, amountIn)` | Curve book                | A zero result means do not route that amount.                             |

Use the base token published for the deployment. Listing is persistent after the first shape update, so an old `qUnit` or `CurveUpdated` event alone is not evidence of a currently executable curve. Check freshness and quote the amount you intend to trade.

## Before enabling a route

Confirm the published chain and proxy addresses, read the linked contracts, and simulate a funded swap from the actual payer with the required approval. Check both trade directions, receipt decoding, stale-curve handling, and the maximum amounts your router will send. Measure gas on the target deployment; development measurements are not production gas limits.

See [Quoting and swapping](/takers/quoting-and-swapping) for the exact ABI and transaction flow.
