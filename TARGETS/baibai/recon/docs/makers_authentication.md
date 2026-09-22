> ## Documentation Index
> Fetch the complete documentation index at: https://docs.baibai.cx/llms.txt
> Use this file to discover all available pages before exploring further.

# API wallets and signing

> Approve and rotate API wallets, sign actions, and coordinate nonces.

Your master wallet owns your inventory and orders. Spire must approve it before it can quote. You can sign directly with that key or approve a hot API wallet for trading. Depositing funds or approving an API wallet does not grant maker access.

## API-wallet approval

Use the Hyperliquid SDK's `Exchange.approve_agent(name)` with the master key. It creates a new key locally and sends a signed `approveAgent` to `POST /exchange`. Store the returned private key securely; the gateway never receives it. Subsequent requests signed by that key resolve to the approving master.

The response is Hyperliquid's standard shape:

```json theme={null}
{"status":"ok","response":{"type":"default"}}
```

## API-wallet replacement

An API-wallet name identifies a slot under your master. Approving a fresh key with the same name replaces the previous key in that slot. Its later requests are rejected. Existing orders remain owned by the master and can be managed with the replacement key. An unnamed approval uses the unnamed slot.

Use a fresh key for each rotation. A key cannot be shared across masters or act as both another account's API wallet and an independent master. Approvals, rotations, and operator revocations survive restarts.

## Signed actions

The adapter accepts Hyperliquid's L1 action signatures without a custom wrapper:

1. Msgpack-encode the action, preserving the order of its keys.
2. Append the nonce, vault marker, and optional expiry using Hyperliquid's encoding.
3. Hash and sign the phantom `Agent` under the `Exchange` EIP-712 domain, chain ID `1337`.

Use the SDK rather than implementing this yourself. The official Python SDK selects source `b` for custom URLs; the adapter accepts that signature, or explicit source `a`, when it resolves unambiguously to a registered identity. Never substitute Base's chain ID into the L1 signing domain.

`approveAgent` uses the separate `HyperliquidSignTransaction` domain and its signed `signatureChainId`; the SDK's `0x66eee` value is accepted. Base's settlement chain ID remains `8453`. Vault/subaccount delegation is unsupported.

## Nonces and expiry

Nonces are Unix milliseconds, unique per signing key. The gateway accepts Hyperliquid's window from two days behind to one day ahead and retains the latest 100 nonces per signer. HTTP and WebSocket actions share this window. Coordinate one nonce allocator if multiple processes use a key.

Nonce history is in memory and resets on restart. Orders and client IDs are durable; use them to reconcile uncertain requests instead of blindly replaying an old signed action. `expiresAfter` limits when the gateway may accept an action; it does not expire a resting order. Use `scheduleCancel` for that.

## Access removal

Spire can remove maker approval and cancel the master's open orders. API-wallet replacement alone does not cancel orders. Previously published on-chain exposure can still execute until replaced or expired; see [settlement and fill latency](/makers/fills-and-latency).
