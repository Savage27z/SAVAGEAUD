> ## Documentation Index
> Fetch the complete documentation index at: https://docs.baibai.cx/llms.txt
> Use this file to discover all available pages before exploring further.

# Aggregators Integration

> BaiBai quote, sign, submit flow

## Flow

BaiBai uses a gasless order flow:

1. List supported tokens.
2. Request a quote.
3. Check quote expiry.
4. Make sure the sell token is approved for Permit2.
5. Ask the user to sign the returned EIP-712 typed data.
6. Submit the quote ID, signature, and optional `clientOrderId`.
7. Poll order status until it is terminal.

```text theme={null}
GET  /tokens       -> supported tokens
POST /quote        -> quote + Permit2 typed data
eth_signTypedData  -> user signature
POST /orders       -> order id
GET  /orders/{id}  -> pending | filled | failed | expired
```

<Info>
  Only EIP-712 gasless orders are supported today. Traditional/non-gasless orders are coming soon.
</Info>

## Quote

Request quotes with token base-unit amounts as decimal strings.

```json theme={null}
{
  "chainId": 8453,
  "from": "0x1111111111111111111111111111111111111111",
  "receiver": "0x1111111111111111111111111111111111111111",
  "sellToken": "0x833589fCD6EDb6E08f4c7C32D4f71b54bdA02913",
  "buyToken": "0x4200000000000000000000000000000000000006",
  "kind": "sell",
  "sellAmountBeforeFee": "1000000",
  "slippageBps": 50,
  "routingPreference": "auto",
  "signingScheme": "eip712"
}
```

For exact-output quotes, use `kind: "buy"` and `buyAmountAfterFee`.

## Quote Expiry

Every quote has two expiry fields:

* `expiration`: ISO timestamp for the quote object.
* `quote.validTo`: Permit deadline in Unix seconds.

Before asking the user to sign, verify the quote is still fresh. If wrap, approval, or user confirmation takes time, request a new quote.

```ts theme={null}
const nowSeconds = Math.floor(Date.now() / 1000);

if (quote.quote.validTo <= nowSeconds + 10) {
  // Quote is expired or too close to expiry. Request a fresh quote.
}
```

Do not submit a stale quote. If `POST /orders` returns an expired-quote error, request a fresh quote and signature.

## Routing Controls

`routingPreference` is optional:

| Value          | Meaning                                                                                                            |
| :------------- | :----------------------------------------------------------------------------------------------------------------- |
| `auto`         | Default. Choose the best available route. May use BaiBai Prop AMM liquidity, external liquidity, or a split route. |
| `preferBaiBai` | Prefer BaiBai Prop AMM liquidity when it is competitive with the best available route.                             |
| `onlyBaiBai`   | Only quote BaiBai Prop AMM liquidity. If BaiBai has no route or enough liquidity, the quote fails.                 |

Use `auto` unless your integration has a reason to bias execution.

## Approvals

For ERC-20 sell tokens, the user must approve Permit2 before signing/submitting.

Approve `quote.permit2.allowanceTarget` for at least `quote.quote.sellAmount`:

```text theme={null}
ERC20(sellToken).approve(quote.permit2.allowanceTarget, quote.quote.sellAmount)
```

Check allowance first:

```text theme={null}
ERC20(sellToken).allowance(owner, quote.permit2.allowanceTarget) >= quote.quote.sellAmount
```

<Note>
  `quote.permit2.allowanceTarget` is the Permit2 contract that receives the ERC-20 approval. `quote.permit2.spender` is the BaiBai settlement spender included in the signed typed data. Do not approve `spender` directly for Permit2 allowance checks.
</Note>

## Signing

Sign the `permit2.typedData` object returned by `/quote` exactly as-is.

```ts theme={null}
const signature = await provider.request({
  method: "eth_signTypedData_v4",
  params: [owner, JSON.stringify(quote.permit2.typedData)],
});
```

The typed data is a Permit2 `PermitWitnessTransferFrom` signature with this BaiBai witness:

```solidity theme={null}
struct OrderWitness {
  address recipient;
  address tokenOut;
  uint256 minAmountOut;
}
```

## Submit

Submit the quote ID and signature. Include `clientOrderId` when you need idempotency across retries.

```json theme={null}
{
  "quoteId": "baibai_quote_123",
  "signature": "0xabcdef...",
  "clientOrderId": "wallet-session-123"
}
```

If a request with the same `clientOrderId` was already accepted for the same owner, BaiBai returns the existing order instead of creating a duplicate.

## Polling

Poll `GET /orders/{orderId}` until the status is terminal.

| Status    | Meaning                              | Terminal |
| :-------- | :----------------------------------- | :------- |
| `pending` | Order accepted and executing.        | No       |
| `filled`  | Order completed.                     | Yes      |
| `failed`  | Order failed.                        | Yes      |
| `expired` | Quote/signature expired before fill. | Yes      |

A practical polling cadence is every 1-2 seconds, backing off to every 5 seconds for longer-running orders.

## Native ETH

ETH is not a gasless order token. Use WETH in quote and order requests.

* Swapping from ETH: request an indicative quote with WETH as the sell token, then wrap ETH to WETH before signing/submitting.
* Swapping to ETH: quote and buy WETH, then unwrap WETH after fill.
* BaiBai does not wrap or unwrap for integrators.

Base WETH: `0x4200000000000000000000000000000000000006`

```ts theme={null}
const WETH_BASE = "0x4200000000000000000000000000000000000006";

// User selected ETH -> USDC. Quote WETH -> USDC first.
const quote = await fetch("https://app.baibai.cx/api/v1/quote", {
  method: "POST",
  headers: { "content-type": "application/json" },
  body: JSON.stringify({
    chainId: 8453,
    from: owner,
    receiver: owner,
    sellToken: WETH_BASE,
    buyToken: usdc,
    kind: "sell",
    sellAmountBeforeFee: ethAmountWei,
    signingScheme: "eip712",
  }),
}).then((r) => r.json());
```

Wrap before the user signs and submits the gasless order:

```ts theme={null}
await weth.write.deposit({ value: BigInt(ethAmountWei) });
```

After wrapping, check the quote expiry. Request a fresh quote if the original quote is expired or close to expiry.

## Retry Guidance

| Situation          | What to do                                                                               |
| :----------------- | :--------------------------------------------------------------------------------------- |
| `429 RATE_LIMITED` | Wait for `retry-after`, then retry.                                                      |
| Quote expired      | Request a fresh quote and signature.                                                     |
| Invalid signature  | Re-sign the exact latest `permit2.typedData`.                                            |
| `pending` order    | Keep polling. Do not submit a second order unless you use the same `clientOrderId`.      |
| Unknown order ID   | Verify the ID from `POST /orders`; otherwise treat it as terminal for that poll request. |

## Related Docs

<Columns cols={2}>
  <Card title="API Overview" icon="code" href="/developers/api-overview">
    Endpoint fields, examples, errors, rate limits, and OpenAPI.
  </Card>

  <Card title="Wallet Integration" icon="wallet" href="/developers/wallet-integration">
    Wallet-side Permit2, signing, polling, and ETH/WETH examples.
  </Card>
</Columns>
