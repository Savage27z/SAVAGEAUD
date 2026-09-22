> ## Documentation Index
> Fetch the complete documentation index at: https://docs.baibai.cx/llms.txt
> Use this file to discover all available pages before exploring further.

# Errors and recovery

> Batch errors and recovery after rejected or uncertain order requests.

The order adapter uses Hyperliquid's response shapes. Inspect every batch entry, including when the top-level status is `ok`.

```json theme={null}
{"status":"ok","response":{"type":"order","data":{"statuses":[{"resting":{"oid":123}},{"error":"Insufficient spot balance"}]}}}
```

The first entry succeeded and the second failed. A modification rejected during validation leaves its original order open. If a replacement was accepted and then canceled, filled, or replaced before the durable reply, its entry reports `Order no longer resting`. Query `orderStatus` by client ID before deciding what to send next. Successful cancels return `"success"` in the corresponding `statuses` entry.

Errors affecting the whole action use:

```json theme={null}
{"status":"err","response":"Description of the failure"}
```

| Situation                                       | Recovery                                                                               |
| ----------------------------------------------- | -------------------------------------------------------------------------------------- |
| Off-grid price or size                          | Correct it to the market grid; the gateway does not round                              |
| Insufficient spot balance                       | Reduce aggregate exposure or wait for a deposit to become available                    |
| Duplicate client order ID                       | Query the existing order before deciding what to send                                  |
| Unknown/already closed order                    | Reconcile `openOrders` and `orderStatus`                                               |
| Marketable or unsupported order type            | Use a resting `Gtc` or `Alo` limit order                                               |
| Invalid nonce/signature                         | Fix the signing domain, clock, or shared nonce allocator                               |
| Unregistered or retired API wallet              | Check master admission and API-wallet replacement                                      |
| Order no longer resting                         | Query order status and fills; another accepted action or fill may have superseded it   |
| Unconfirmed action outcome or transport timeout | Query by client order ID; do not blindly repeat the order                              |
| Order state persistence pending                 | Retry the read with backoff; do not submit a replacement until reconciliation succeeds |

Cancel responses describe gateway state. Older on-chain publications can still execute until replaced or expired. Continue tracking fills for canceled and replaced IDs.

While a maker has pending order changes, `orderStatus`, `openOrders`, `frontendOpenOrders`, and `historicalOrders` return HTTP `503` with `Order state persistence pending`. WebSocket info requests return the same message as a post error. This response does not mean the order is absent. Keep retrying the query with backoff; normal order reads resume when the change is durable or authoritative recovery has resolved it. Other makers remain queryable.

Invalid or unsupported `/info` requests return HTTP `422`. Unsupported WebSocket requests/subscriptions return an error response or channel. Book price aggregation, aggregated fill history, and unsupported Hyperliquid trading/funding actions fail explicitly.
