> ## Documentation Index
> Fetch the complete documentation index at: https://docs.baibai.cx/llms.txt
> Use this file to discover all available pages before exploring further.

# Wallet Integration

> Wallet flow for BaiBai gasless swaps

## Wallet Flow

1. List supported tokens.
2. Quote the swap.
3. Check quote expiry.
4. Check Permit2 allowance.
5. If needed, send an ERC-20 approval transaction and wait for it.
6. Ask the user to sign the returned EIP-712 typed data.
7. Submit the order with a `clientOrderId`.
8. Poll status until the order is `filled`, `failed`, or `expired`.

<Info>
  BaiBai currently supports gasless EIP-712 orders only. Traditional/non-gasless orders are coming soon.
</Info>

## Constants

```ts theme={null}
const API = "https://app.baibai.cx/api/v1";
const CHAIN_ID = 8453;
const WETH_BASE = "0x4200000000000000000000000000000000000006";
```

## Error Handling Helper

All REST errors use this shape:

```json theme={null}
{
  "error": {
    "code": "BAD_REQUEST",
    "message": "Unsupported token."
  }
}
```

Use HTTP status codes for retry behavior. `429` responses include `retry-after`.

```ts theme={null}
type BaiBaiError = Error & {
  code?: string;
  retryAfterSeconds?: number;
  status: number;
};

async function requestJson<T>(path: string, init?: RequestInit): Promise<T> {
  const response = await fetch(`${API}${path}`, {
    ...init,
    headers: {
      "content-type": "application/json",
      ...init?.headers,
    },
  });

  const body = await response.json().catch(() => ({}));

  if (!response.ok) {
    const error = new Error(
      body?.error?.message ?? `BaiBai request failed: ${response.status}`,
    ) as BaiBaiError;
    error.status = response.status;
    error.code = body?.error?.code;
    error.retryAfterSeconds = Number(response.headers.get("retry-after") ?? 0);
    throw error;
  }

  return body as T;
}
```

## List Tokens

Use `/tokens` to discover supported ERC-20 tokens and decimals.

```ts theme={null}
const tokens = await requestJson<
  Array<{
    chainId: number;
    address: string;
    symbol: string;
    name: string;
    decimals: number;
    logoURI?: string;
  }>
>(`/tokens?chainId=${CHAIN_ID}`);
```

## Quote

Amounts are token base units as decimal strings.

```ts theme={null}
const quote = await requestJson<{
  id: string;
  expiration: string;
  quote: {
    sellAmount: string;
    buyAmount: string;
    minBuyAmount?: string;
    validTo: number;
  };
  permit2: {
    allowanceTarget: `0x${string}`;
    spender: `0x${string}`;
    typedData: unknown;
  };
}>("/quote", {
  method: "POST",
  body: JSON.stringify({
    chainId: CHAIN_ID,
    from: owner,
    receiver: owner,
    sellToken: usdc,
    buyToken: WETH_BASE,
    kind: "sell",
    sellAmountBeforeFee: "1000000",
    slippageBps: 50,
    routingPreference: "auto",
    signingScheme: "eip712",
  }),
});
```

For exact-output swaps, use `kind: "buy"` and `buyAmountAfterFee`.

## Routing Preference

The optional `routingPreference` field controls how BaiBai chooses liquidity:

| Value          | Meaning                                                                                           |
| :------------- | :------------------------------------------------------------------------------------------------ |
| `auto`         | Default. Choose the best available route.                                                         |
| `preferBaiBai` | Prefer BaiBai Prop AMM liquidity when it is competitive.                                          |
| `onlyBaiBai`   | Only quote BaiBai Prop AMM liquidity; the quote fails if BaiBai has no route or enough liquidity. |

Use `auto` unless your wallet intentionally wants to bias execution.

## Check Quote Expiry

Check expiry before signing. If approval, wrapping, or user confirmation takes time, request a fresh quote.

```ts theme={null}
function quoteIsUsable(quote: { expiration: string; quote: { validTo: number } }) {
  const nowSeconds = Math.floor(Date.now() / 1000);
  const expiresAtMs = Date.parse(quote.expiration);

  return expiresAtMs > Date.now() + 10_000 && quote.quote.validTo > nowSeconds + 10;
}

if (!quoteIsUsable(quote)) {
  throw new Error("Quote expired. Request a fresh quote before signing.");
}
```

## Approve Permit2

Approve `quote.permit2.allowanceTarget`, not `quote.permit2.spender`.

```ts theme={null}
const allowance = await erc20.read.allowance([
  owner,
  quote.permit2.allowanceTarget,
]);

if (allowance < BigInt(quote.quote.sellAmount)) {
  const hash = await erc20.write.approve([
    quote.permit2.allowanceTarget,
    quote.quote.sellAmount,
  ]);

  await publicClient.waitForTransactionReceipt({ hash });
}
```

<Note>
  `allowanceTarget` is the Permit2 contract that receives the ERC-20 approval. `spender` is the BaiBai settlement spender included in the signed typed data.
</Note>

## Sign

Sign `quote.permit2.typedData` exactly as returned.

```ts theme={null}
if (!quoteIsUsable(quote)) {
  throw new Error("Quote expired. Request a fresh quote before signing.");
}

const signature = await provider.request({
  method: "eth_signTypedData_v4",
  params: [owner, JSON.stringify(quote.permit2.typedData)],
});
```

## Submit

Use `clientOrderId` to make submit retries idempotent.

```ts theme={null}
const clientOrderId = crypto.randomUUID();

const order = await requestJson<{
  orderId: string;
  quoteId: string;
  status: "pending" | "filled" | "failed" | "expired";
}>("/orders", {
  method: "POST",
  body: JSON.stringify({
    quoteId: quote.id,
    signature,
    clientOrderId,
  }),
});
```

If the network fails after submit, retry the same request with the same `clientOrderId`. BaiBai returns the existing order instead of creating a duplicate.

## Poll

Poll every 1-2 seconds, then back off to every 5 seconds for longer-running orders.

```ts theme={null}
async function waitForOrder(orderId: string) {
  let delayMs = 1_500;

  while (true) {
    const status = await requestJson<{
      orderId: string;
      status: "pending" | "filled" | "failed" | "expired";
      txHash?: string;
      executedSellAmount?: string;
      executedBuyAmount?: string;
      error?: { code: string; message: string };
    }>(`/orders/${orderId}`);

    if (status.status !== "pending") {
      return status;
    }

    await new Promise((resolve) => setTimeout(resolve, delayMs));
    delayMs = Math.min(delayMs * 1.5, 5_000);
  }
}
```

## Native ETH

Native ETH is not a gasless order token. Use WETH in quote and order requests.

* Swapping from ETH: request an indicative quote with WETH as the sell token, then wrap ETH to WETH before signing/submitting.
* Swapping to ETH: quote and buy WETH, then unwrap WETH after fill.
* The wallet/caller owns the wrap and unwrap transactions.

Base WETH: `0x4200000000000000000000000000000000000006`

### Swapping from ETH

Quote with WETH before the user wraps:

```ts theme={null}
const quote = await requestJson("/quote", {
  method: "POST",
  body: JSON.stringify({
    chainId: CHAIN_ID,
    from: owner,
    receiver: owner,
    sellToken: WETH_BASE,
    buyToken: usdc,
    kind: "sell",
    sellAmountBeforeFee: ethAmountWei,
    signingScheme: "eip712",
  }),
});
```

Then wrap, approve Permit2, check quote expiry, sign, and submit:

```ts theme={null}
const wrapHash = await weth.write.deposit({ value: BigInt(ethAmountWei) });
await publicClient.waitForTransactionReceipt({ hash: wrapHash });

const approveHash = await weth.write.approve([
  quote.permit2.allowanceTarget,
  quote.quote.sellAmount,
]);
await publicClient.waitForTransactionReceipt({ hash: approveHash });

if (!quoteIsUsable(quote)) {
  // Wrapping or approval took too long. Request a fresh WETH quote.
}
```

### Swapping to ETH

Quote WETH as the buy token, submit the order, then unwrap after it fills:

```ts theme={null}
const quote = await requestJson("/quote", {
  method: "POST",
  body: JSON.stringify({
    chainId: CHAIN_ID,
    from: owner,
    receiver: owner,
    sellToken: usdc,
    buyToken: WETH_BASE,
    kind: "sell",
    sellAmountBeforeFee: usdcAmount,
    signingScheme: "eip712",
  }),
});

const status = await waitForOrder(order.orderId);

if (status.status === "filled" && status.executedBuyAmount) {
  const unwrapHash = await weth.write.withdraw([BigInt(status.executedBuyAmount)]);
  await publicClient.waitForTransactionReceipt({ hash: unwrapHash });
}
```

## Retry Guidance

| HTTP status | Example                                             | Action                                                                           |
| :---------- | :-------------------------------------------------- | :------------------------------------------------------------------------------- |
| `400`       | unsupported token, expired quote, invalid signature | Fix input or request a fresh quote/signature.                                    |
| `404`       | unknown order ID                                    | Verify the order ID from submit.                                                 |
| `429`       | rate limited                                        | Wait for `retry-after`, then retry.                                              |
| `500`       | temporary service error                             | Retry with backoff. If submit status is unknown, reuse the same `clientOrderId`. |

## Related Docs

<Columns cols={2}>
  <Card title="Aggregators Integration" icon="route" href="/developers/aggregators-integration">
    Quote, sign, submit, status, routing, and retry concepts.
  </Card>

  <Card title="API Overview" icon="code" href="/developers/api-overview">
    Endpoint fields, examples, errors, rate limits, and OpenAPI.
  </Card>
</Columns>
