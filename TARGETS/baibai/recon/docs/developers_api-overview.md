> ## Documentation Index
> Fetch the complete documentation index at: https://docs.baibai.cx/llms.txt
> Use this file to discover all available pages before exploring further.

# API Overview

> BaiBai REST API for gasless swaps

## Base URL

```text theme={null}
https://app.baibai.cx/api/v1
```

<Info>
  Use this REST API for BaiBai integrations.
</Info>

## Rules

* Base only for now: `chainId: 8453`.
* Gasless EIP-712 orders only.
* Traditional/non-gasless orders are coming soon.
* Amounts are token base units as decimal strings.
* Use ERC-20 tokens with Permit2.
* Native ETH is not a gasless order token. Use WETH in quote and order requests; callers handle wrap/unwrap transactions.

Base WETH: `0x4200000000000000000000000000000000000006`

## Endpoints

| Method | Path                   | Purpose                             |
| :----- | :--------------------- | :---------------------------------- |
| `GET`  | `/tokens?chainId=8453` | List supported tokens.              |
| `POST` | `/quote`               | Get a quote and EIP-712 typed data. |
| `POST` | `/orders`              | Submit a signed gasless order.      |
| `GET`  | `/orders/{orderId}`    | Get order status.                   |

## List Tokens

`GET /tokens?chainId=8453`

```json theme={null}
[
  {
    "chainId": 8453,
    "address": "0x833589fCD6EDb6E08f4c7C32D4f71b54bdA02913",
    "symbol": "USDC",
    "name": "USD Coin",
    "decimals": 6,
    "logoURI": "https://..."
  }
]
```

Use token decimals to convert user-facing amounts into base units before calling `/quote`.

## Quote

`POST /quote`

### Request

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

| Field                 | Required   | Description                                                  |
| :-------------------- | :--------- | :----------------------------------------------------------- |
| `chainId`             | Yes        | Base mainnet: `8453`.                                        |
| `from`                | Yes        | Owner address that will sign the order.                      |
| `receiver`            | No         | Recipient of the buy token. Defaults to `from`.              |
| `sellToken`           | Yes        | ERC-20 sell token. Use WETH instead of native ETH.           |
| `buyToken`            | Yes        | ERC-20 buy token. Use WETH instead of native ETH.            |
| `kind`                | Yes        | `sell` for exact-input or `buy` for exact-output.            |
| `sellAmountBeforeFee` | For `sell` | Exact sell amount in base units.                             |
| `buyAmountAfterFee`   | For `buy`  | Exact buy amount in base units.                              |
| `slippageBps`         | No         | Slippage in basis points. Defaults to `50`; max `2000`.      |
| `routingPreference`   | No         | `auto`, `preferBaiBai`, or `onlyBaiBai`. Defaults to `auto`. |
| `signingScheme`       | Yes        | Must be `eip712`.                                            |

For exact-output quotes, use `kind: "buy"` and `buyAmountAfterFee`.

### Response

```json theme={null}
{
  "id": "baibai_quote_123",
  "from": "0x1111111111111111111111111111111111111111",
  "expiration": "2026-06-13T18:35:18.814Z",
  "quote": {
    "sellToken": "0x833589fCD6EDb6E08f4c7C32D4f71b54bdA02913",
    "buyToken": "0x4200000000000000000000000000000000000006",
    "receiver": "0x1111111111111111111111111111111111111111",
    "sellAmount": "1000000",
    "buyAmount": "250000000000000",
    "minBuyAmount": "248750000000000",
    "validTo": 1781375718,
    "feeAmount": "0",
    "kind": "sell",
    "partiallyFillable": false,
    "signingScheme": "eip712"
  },
  "permit2": {
    "allowanceTarget": "0x000000000022D473030F116dDEE9F6B43aC78BA3",
    "spender": "0xbf8E65Fe0711F6B2424372A65070b7A4F2B26567",
    "typedData": {
      "domain": {
        "name": "Permit2",
        "chainId": 8453,
        "verifyingContract": "0x000000000022D473030F116dDEE9F6B43aC78BA3"
      },
      "primaryType": "PermitWitnessTransferFrom",
      "types": { "...": "EIP-712 types" },
      "message": { "...": "Permit2 witness message" }
    },
    "witnessTypeString": "OrderWitness witness)"
  }
}
```

| Field                     | Description                                          |
| :------------------------ | :--------------------------------------------------- |
| `id`                      | Quote ID to submit after signing.                    |
| `expiration`              | ISO timestamp when the quote expires.                |
| `quote.sellAmount`        | Max sell amount in base units.                       |
| `quote.buyAmount`         | Expected buy amount in base units.                   |
| `quote.minBuyAmount`      | Minimum buy amount after slippage.                   |
| `quote.validTo`           | Permit deadline in Unix seconds.                     |
| `permit2.allowanceTarget` | Permit2 contract to approve with the sell token.     |
| `permit2.spender`         | BaiBai settlement spender in the Permit2 typed data. |
| `permit2.typedData`       | EIP-712 payload to sign exactly as returned.         |

<Note>
  Approve `permit2.allowanceTarget`, not `permit2.spender`. `spender` is included in the EIP-712 signature.
</Note>

## Quote Expiry

Before signing, verify the quote is still fresh:

```ts theme={null}
const nowSeconds = Math.floor(Date.now() / 1000);
const isFresh =
  Date.parse(quote.expiration) > Date.now() + 10_000 &&
  quote.quote.validTo > nowSeconds + 10;
```

If the quote is expired or close to expiry, request a fresh quote. This matters when the user must wrap ETH, send an approval transaction, or takes time to confirm a signature.

## Quote Controls

`routingPreference` is optional:

| Value          | Meaning                                                                                                            |
| :------------- | :----------------------------------------------------------------------------------------------------------------- |
| `auto`         | Default. Choose the best available route. May use BaiBai Prop AMM liquidity, external liquidity, or a split route. |
| `preferBaiBai` | Prefer BaiBai Prop AMM liquidity when it is competitive with the best available route.                             |
| `onlyBaiBai`   | Only quote BaiBai Prop AMM liquidity. If BaiBai has no route or enough liquidity, the quote fails.                 |

Examples:

```json theme={null}
{ "routingPreference": "auto" }
```

```json theme={null}
{ "routingPreference": "preferBaiBai" }
```

```json theme={null}
{ "routingPreference": "onlyBaiBai" }
```

Use `auto` for best execution unless your integration intentionally wants to bias routing.

## Submit Order

`POST /orders`

### Request

```json theme={null}
{
  "quoteId": "baibai_quote_123",
  "signature": "0xabcdef...",
  "clientOrderId": "wallet-session-123"
}
```

| Field           | Required | Description                                                                          |
| :-------------- | :------- | :----------------------------------------------------------------------------------- |
| `quoteId`       | Yes      | Quote ID from `/quote`.                                                              |
| `signature`     | Yes      | EIP-712 signature over `permit2.typedData`.                                          |
| `clientOrderId` | No       | Integrator-provided idempotency key. Max 128 chars; letters, numbers, `:`, `_`, `-`. |

If a request with the same `clientOrderId` was already accepted for the same owner, BaiBai returns the existing order instead of creating a duplicate. Use the same `clientOrderId` when retrying after network failures.

### Response

```json theme={null}
{
  "orderId": "baibai_order_123",
  "quoteId": "baibai_quote_123",
  "status": "pending"
}
```

## Get Order

`GET /orders/{orderId}`

```json theme={null}
{
  "orderId": "baibai_order_123",
  "quoteId": "baibai_quote_123",
  "status": "filled",
  "sellToken": "0x833589fCD6EDb6E08f4c7C32D4f71b54bdA02913",
  "buyToken": "0x4200000000000000000000000000000000000006",
  "sellAmount": "1000000",
  "buyAmount": "250000000000000",
  "executedSellAmount": "1000000",
  "executedBuyAmount": "250000000000000",
  "txHash": "0x1234..."
}
```

| Status    | Meaning                              | Terminal |
| :-------- | :----------------------------------- | :------- |
| `pending` | Order accepted and executing.        | No       |
| `filled`  | Order completed.                     | Yes      |
| `failed`  | Order failed.                        | Yes      |
| `expired` | Quote/signature expired before fill. | Yes      |

Poll every 1-2 seconds, then back off to every 5 seconds for longer-running orders.

## Native ETH

Use WETH in quote and order requests.

### Swapping from ETH

Request an indicative WETH quote before the user wraps:

```json theme={null}
{
  "chainId": 8453,
  "from": "0x1111111111111111111111111111111111111111",
  "sellToken": "0x4200000000000000000000000000000000000006",
  "buyToken": "0x833589fCD6EDb6E08f4c7C32D4f71b54bdA02913",
  "kind": "sell",
  "sellAmountBeforeFee": "1000000000000000000",
  "signingScheme": "eip712"
}
```

Then wrap ETH to WETH, approve Permit2, check quote expiry, sign, and submit. If wrapping or approval takes too long, request a fresh WETH quote.

### Swapping to ETH

Quote WETH as the buy token, submit the order, then unwrap WETH after the order fills.

## Rate Limits

Rate-limited responses use HTTP `429` and include these headers:

| Header                  | Description                                        |
| :---------------------- | :------------------------------------------------- |
| `x-ratelimit-limit`     | Request limit for the route/window.                |
| `x-ratelimit-remaining` | Remaining requests in the current window.          |
| `x-ratelimit-reset`     | Reset timestamp in milliseconds.                   |
| `retry-after`           | Seconds to wait before retrying. Present on `429`. |

## Errors

Errors use this envelope:

```json theme={null}
{
  "error": {
    "code": "BAD_REQUEST",
    "message": "Native ETH is not supported for gasless orders. Use WETH (0x4200000000000000000000000000000000000006) and wrap or unwrap in the caller."
  }
}
```

Common HTTP statuses:

| Status | Code             | Retry?                               | Notes                                                                           |
| :----- | :--------------- | :----------------------------------- | :------------------------------------------------------------------------------ |
| `400`  | `BAD_REQUEST`    | No, unless quote/signature is stale. | Invalid input, unsupported token, native ETH, expired quote, invalid signature. |
| `404`  | `NOT_FOUND`      | No.                                  | Unknown order ID.                                                               |
| `429`  | `RATE_LIMITED`   | Yes.                                 | Wait for `retry-after`.                                                         |
| `500`  | `INTERNAL_ERROR` | Yes, with backoff.                   | If submit status is unknown, retry with the same `clientOrderId`.               |

Examples:

```json theme={null}
{
  "error": {
    "code": "BAD_REQUEST",
    "message": "Unsupported token."
  }
}
```

```json theme={null}
{
  "error": {
    "code": "BAD_REQUEST",
    "message": "Quote expired. Request a fresh quote."
  }
}
```

```json theme={null}
{
  "error": {
    "code": "BAD_REQUEST",
    "message": "Invalid signature."
  }
}
```

```json theme={null}
{
  "error": {
    "code": "RATE_LIMITED",
    "message": "Rate limit exceeded for quote.once."
  }
}
```

## cURL Happy Path

```bash theme={null}
API=https://app.baibai.cx/api/v1
OWNER=0x1111111111111111111111111111111111111111
USDC=0x833589fCD6EDb6E08f4c7C32D4f71b54bdA02913
WETH=0x4200000000000000000000000000000000000006

curl -sS "$API/tokens?chainId=8453" | jq

curl -sS -X POST "$API/quote" \
  -H 'content-type: application/json' \
  --data "{\
    \"chainId\":8453,\
    \"from\":\"$OWNER\",\
    \"receiver\":\"$OWNER\",\
    \"sellToken\":\"$USDC\",\
    \"buyToken\":\"$WETH\",\
    \"kind\":\"sell\",\
    \"sellAmountBeforeFee\":\"1000000\",\
    \"slippageBps\":50,\
    \"routingPreference\":\"auto\",\
    \"signingScheme\":\"eip712\"\
  }" | tee /tmp/baibai-quote.json | jq

# Sign .permit2.typedData with the owner's wallet, then submit:
QUOTE_ID=$(jq -r .id /tmp/baibai-quote.json)
SIGNATURE=0x...
CLIENT_ORDER_ID=$(uuidgen)

curl -sS -X POST "$API/orders" \
  -H 'content-type: application/json' \
  --data "{\
    \"quoteId\":\"$QUOTE_ID\",\
    \"signature\":\"$SIGNATURE\",\
    \"clientOrderId\":\"$CLIENT_ORDER_ID\"\
  }" | tee /tmp/baibai-order.json | jq

ORDER_ID=$(jq -r .orderId /tmp/baibai-order.json)
curl -sS "$API/orders/$ORDER_ID" | jq
```

## OpenAPI

<Card title="Download OpenAPI" icon="file-code" href="https://docs.spire.dev/openapi/baibai.yaml" />

## Related Docs

<Columns cols={2}>
  <Card title="Aggregators Integration" icon="route" href="/developers/aggregators-integration">
    Quote, sign, submit, status, routing, and retry concepts.
  </Card>

  <Card title="Wallet Integration" icon="wallet" href="/developers/wallet-integration">
    Wallet-side Permit2, signing, polling, and ETH/WETH examples.
  </Card>
</Columns>
