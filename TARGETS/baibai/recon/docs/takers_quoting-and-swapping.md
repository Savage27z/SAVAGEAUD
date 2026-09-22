> ## Documentation Index
> Fetch the complete documentation index at: https://docs.baibai.cx/llms.txt
> Use this file to discover all available pages before exploring further.

# Quoting and swapping

> Read the MM curve, approve the entrypoint, and execute an exact-input swap.

Read net prices with `entrypoint.quoteFor` and send swaps to the entrypoint. The curve book’s `quote` exposes the full curve output before caller-specific fees. Discover the book with `entrypoint.curveBook()`. All amounts are integer token atomic units: WETH uses 18 decimals and USDC uses 6. `base` identifies the pair; `tokenIn` selects its direction.

| Input              | Output             | Curve side        |
| ------------------ | ------------------ | ----------------- |
| Shared quote token | Base token         | Asks (`side = 0`) |
| Base token         | Shared quote token | Bids (`side = 1`) |

## Read ABI

```solidity theme={null}
interface IBaibaiCurveBook {
    struct Side {
        int16 spreadBps;
        uint16 depthBps;
        uint256 filled;
        uint8 knotCount;
    }
    struct PairView {
        uint64 seq;
        uint64 fillSeq;
        uint64 lastUpdateAt;
        uint80 mid;
        uint256 qUnit;
        Side ask;
        Side bid;
    }

    function quote(address base, address tokenIn, uint256 amountIn)
        external view returns (uint256 amountOut);
    function pair(address base) external view returns (PairView memory);
    function knot(address base, uint8 side, uint256 index)
        external view returns (uint48 q, uint48 extra);
    function ttl() external view returns (uint64);
    function validUntil(address base) external view returns (uint64);
    function quoteToken() external view returns (address);
    function cUnit() external view returns (uint256);
}
```

`quote(base, tokenIn, amountIn)` returns zero for the contract's pricing failures: an unknown base or input token, zero input, an expired curve, disabled or exhausted depth, or output that rounds to zero. Treat zero as **do not route**. Handle RPC and execution errors separately; a failed RPC call is not a valid zero quote.

The curve book quote is the gross amount; `entrypoint.quoteFor` with the actual caller gives the net swap amount in the same executable state. It checks neither the caller's balance and allowance nor the custodian's available output liquidity. Simulate the actual swap before sending it.

## Check freshness at one block

Read `pair(base)`, `ttl()`, `validUntil(base)`, and `quoteFor(...)` at a single block number, using that block's timestamp. A curve is live only if:

1. `pair.qUnit != 0`: the base has been listed.
2. `block.timestamp <= validUntil(base)`: the authenticated publication deadline has not passed.
3. `ttl == 0 || block.timestamp <= pair.lastUpdateAt + ttl`: the inclusion-based TTL has not passed.
4. The required side has nonzero `knotCount` and `depthBps`, and your amount returns a nonzero quote.

`ttl == 0` does not disable `validUntil`. At either deadline equality is allowed; expiry begins after the deadline. A quote can expire between reading and execution, even if `seq` and `fillSeq` are unchanged.

`seq` increments on each accepted curve update. `fillSeq` increments on each swap for that base. Either changing can alter your quote. Use `minAmountOut` to bound execution. A router requiring the observed curve state can additionally read `pair(base)` within its transaction and reject a different `(seq, fillSeq)`; it must still handle expiry. Keep the base token with `fillSeq`, because the counter is per pair.

## Depth and local pricing

Each side contains up to 36 knots. `knot(base, side, index)` returns cumulative base size `q` in units of `pair.qUnit`, and cumulative extra quote cost in units of `cUnit()`. Asks add the extra cost to the spread-adjusted mid line; bids subtract it.

For an enabled side, its base capacity and remaining depth are:

```text theme={null}
maxBase = floor(lastKnot.q * pair.qUnit * side.depthBps / 10000)
remainingBase = max(0, maxBase - side.filled)
```

Check `knotCount` before reading the last knot. Reanchors may shrink depth below the existing fill cursor; remaining depth is then zero. On asks, this is the maximum remaining base output. On bids, it is the maximum remaining base input. Fills that exceed available depth revert; there are no partial fills.

`mid` is expressed in quote atomic units per `10^18` base atomic units. The side's mid line is `floor(mid * (10000 + spreadBps) / 10000)`. For exact results, use the `quote` view: segment interpolation, rounding, and ask-side cost inversion are part of pricing. A spot price multiplied by size is not an executable quote.

## Swap ABI and approvals

```solidity theme={null}
interface IBaibaiEntrypoint {
    function curveBook() external view returns (address);
    function custodian() external view returns (address);
    function quoteToken() external view returns (address);
    function quoteFor(address base, address tokenIn, uint256 amountIn, address taker)
        external view returns (uint256 amountOut, uint256 fee);
    function swapExactAmountIn(
        address base,
        address tokenIn,
        uint256 amountIn,
        uint256 minAmountOut,
        address to
    ) external returns (uint256 amountOut);

    event Fill(
        address indexed base,
        uint64 indexed fillSeq,
        address indexed taker,
        address tokenIn,
        uint256 amountIn,
        uint256 amountOut,
        uint256 fee
    );
}
```

Approve the **entrypoint** to spend at least `amountIn` of `tokenIn`. If a router calls the entrypoint, the router is the payer and must hold the input and grant that approval.

Wait for approval to confirm, then obtain a fresh quote and simulate the swap. The entrypoint checks the recipient, consumes the curve, checks `minAmountOut`, pulls input from `msg.sender` into the custodian, pays output from the custodian to `to`, and emits `Fill`. Any failure reverts every step. The recipient must be nonzero; the entrypoint is non-reentrant.

The call has no deadline argument. A router can enforce its own deadline before calling. Curve expiry alone does not stop a delayed transaction from executing against a later refreshed curve that meets `minAmountOut`.

## TypeScript example

This browser-wallet example uses `viem`. Pass your EIP-1193 wallet provider, Base RPC URL, and the verified entrypoint and WETH addresses from the [deployment record](/takers/deployments). It buys WETH with 10 USDC and permits 30 basis points of slippage. Choose the amount and slippage for your integration.

```typescript theme={null}
import {
  createPublicClient, createWalletClient, custom, getAddress, http,
  parseAbi, parseEventLogs, type Address, type EIP1193Provider,
} from 'viem';
import { base } from 'viem/chains';

const entrypointAbi = parseAbi([
  'function curveBook() view returns (address)',
  'function quoteToken() view returns (address)',
  'function quoteFor(address base, address tokenIn, uint256 amountIn, address taker) view returns (uint256 amountOut, uint256 fee)',
  'function swapExactAmountIn(address base, address tokenIn, uint256 amountIn, uint256 minAmountOut, address to) returns (uint256 amountOut)',
  'event Fill(address indexed base, uint64 indexed fillSeq, address indexed taker, address tokenIn, uint256 amountIn, uint256 amountOut, uint256 fee)',
  'error ZeroAddress()',
  'error InsufficientOutput(uint256 amountOut, uint256 minAmountOut)',
  'error UnknownToken()',
  'error ZeroAmount()',
  'error CurveStale()',
  'error BeyondDepth()',
  'error InsufficientLiquidity(uint256 requested, uint256 available)',
]);
const curveBookAbi = parseAbi([
  'struct Side { int16 spreadBps; uint16 depthBps; uint256 filled; uint8 knotCount; }',
  'struct PairView { uint64 seq; uint64 fillSeq; uint64 lastUpdateAt; uint80 mid; uint256 qUnit; Side ask; Side bid; }',
  'function ttl() view returns (uint64)',
  'function validUntil(address base) view returns (uint64)',
  'function pair(address base) view returns (PairView)',
  'function quote(address base, address tokenIn, uint256 amountIn) view returns (uint256 amountOut)',
]);
const erc20Abi = parseAbi([
  'function decimals() view returns (uint8)',
  'function allowance(address owner, address spender) view returns (uint256)',
  'function approve(address spender, uint256 amount) returns (bool)',
]);

export async function buyWeth(
  provider: EIP1193Provider, rpcUrl: string,
  entrypoint: Address, weth: Address,
) {
  const client = createPublicClient({ chain: base, transport: http(rpcUrl) });
  const wallet = createWalletClient({ chain: base, transport: custom(provider) });
  const [rpcChain, walletChain] = await Promise.all([
    client.getChainId(), wallet.getChainId(),
  ]);
  if (rpcChain !== base.id || walletChain !== base.id) {
    throw new Error('RPC and wallet must both use Base mainnet');
  }
  const [account] = await wallet.requestAddresses();
  if (!account) throw new Error('No wallet account');
  const curveBook = await client.readContract({
    address: entrypoint, abi: entrypointAbi, functionName: 'curveBook',
  });
  const usdc = await client.readContract({
    address: entrypoint, abi: entrypointAbi, functionName: 'quoteToken',
  });
  // Independently verify these tokens against the published deployment record.
  const decimals = await client.readContract({
    address: usdc, abi: erc20Abi, functionName: 'decimals',
  });
  if (decimals !== 6) throw new Error('Example expects a 6-decimal quote token');
  const amountIn = 10_000_000n; // 10 USDC
  const allowance = await client.readContract({
    address: usdc, abi: erc20Abi, functionName: 'allowance',
    args: [account, entrypoint],
  });
  if (allowance < amountIn) {
    const { request } = await client.simulateContract({
      account, address: usdc, abi: erc20Abi, functionName: 'approve',
      args: [entrypoint, amountIn],
    });
    const hash = await wallet.writeContract(request);
    const receipt = await client.waitForTransactionReceipt({ hash });
    if (receipt.status !== 'success') throw new Error('Approval reverted');
  }

  // Read after approval, using one block for the quote and both expiry checks.
  const block = await client.getBlock();
  const blockNumber = block.number;
  const [pair, ttl, validUntil, [amountOut, fee]] = await Promise.all([
    client.readContract({ address: curveBook, abi: curveBookAbi,
      functionName: 'pair', args: [weth], blockNumber }),
    client.readContract({ address: curveBook, abi: curveBookAbi,
      functionName: 'ttl', blockNumber }),
    client.readContract({ address: curveBook, abi: curveBookAbi,
      functionName: 'validUntil', args: [weth], blockNumber }),
    client.readContract({ address: entrypoint, abi: entrypointAbi,
      functionName: 'quoteFor', args: [weth, usdc, amountIn, account], blockNumber }),
  ]);
  const stale = block.timestamp > validUntil ||
    (ttl !== 0n && block.timestamp > pair.lastUpdateAt + ttl);
  if (pair.qUnit === 0n || stale || amountOut === 0n) {
    throw new Error('No executable quote');
  }
  const minAmountOut = amountOut * 9_970n / 10_000n;
  if (minAmountOut === 0n) throw new Error('Minimum output rounds to zero');
  const { request } = await client.simulateContract({
    account, address: entrypoint, abi: entrypointAbi,
    functionName: 'swapExactAmountIn',
    args: [weth, usdc, amountIn, minAmountOut, account],
  });
  const hash = await wallet.writeContract(request);
  const receipt = await client.waitForTransactionReceipt({ hash });
  if (receipt.status !== 'success') throw new Error('Swap reverted');
  const fills = parseEventLogs({
    abi: entrypointAbi, eventName: 'Fill',
    logs: receipt.logs.filter(log => getAddress(log.address) === getAddress(entrypoint)),
  });
  const fill = fills.find(log =>
    getAddress(log.args.base) === getAddress(weth) &&
    getAddress(log.args.taker) === getAddress(account));
  if (!fill) throw new Error('Expected Fill event missing');
  return { hash, quotedFee: fee, fill: fill.args, gasUsed: receipt.gasUsed };
}
```

Simulation cannot reserve a quote. Wallet confirmation, another fill, or a new block can change execution. If simulation fails because the curve moved or expired, obtain a fresh quote. If submission status is unknown, resolve that transaction's receipt or nonce before sending another swap.

## Errors and recovery

| Error                                    | Meaning                                                                         | Response                                    |
| ---------------------------------------- | ------------------------------------------------------------------------------- | ------------------------------------------- |
| `ZeroAddress()`                          | Recipient is zero.                                                              | Correct the recipient.                      |
| `UnknownToken()`                         | Base is zero, unlisted, or the quote token; or input is neither base nor quote. | Verify the deployment and pair.             |
| `ZeroAmount()`                           | Input amount is zero.                                                           | Supply a positive atomic-unit amount.       |
| `CurveStale()`                           | Source deadline or inclusion-based TTL elapsed.                                 | Wait for a fresh curve and quote again.     |
| `BeyondDepth()`                          | Disabled/exhausted depth, oversized input, or zero rounded output.              | Reduce the amount or choose another route.  |
| `InsufficientOutput(uint256,uint256)`    | Output is below `minAmountOut`.                                                 | Requote; do not blindly remove the minimum. |
| `InsufficientLiquidity(uint256,uint256)` | Custodian's available output inventory is too small.                            | Skip the route until liquidity returns.     |

Token transfers may also revert for insufficient balance or allowance. ERC-20/SafeERC20 errors and `ReentrancyGuardReentrantCall()` can propagate. Do not call `curveBook.consume` directly: it is restricted to the entrypoint.

## Receipts, fees, and gas

Decode `Fill` only from the configured entrypoint address. Its indexed fields are `base`, `fillSeq`, and `taker`; its data fields are `tokenIn`, `amountIn`, `amountOut`, and `fee`. `taker` is the entrypoint caller, so it is the router address when a router pays. `to` is not in `Fill`; the custodian's `PaidOut` event and output token transfer identify the recipient.

Keep the transaction hash, base, and `fillSeq` for reconciliation. Token implementations may emit additional logs, so do not assume a fixed receipt log count. Track chain reorganizations according to your integration's confirmation policy.

An owner-configured caller fee is applied to output: `fee = ceil(curveOut × bps / 10000)` and `amountOut = curveOut - fee`. The fee is retained in the custodian and credited off-chain to the caller’s ledger row. Maker attribution uses the full curve output. Curve spread, price impact, and network fees remain costs. Gas depends on how many knots the walk crosses and the current fill cursor; estimate it for the actual calldata and payer on the target chain.

## Fees

Use `quoteFor(base, tokenIn, amountIn, taker)` on the entrypoint with the address that will call `swapExactAmountIn`. It returns net `amountOut` and `fee`; passing the zero address returns the raw curve quote. A router’s caller is the router itself, not its user or output recipient.

`takerFeeBps(taker, base)` returns the effective basis points. A per-pair entry, including explicit zero, overrides the caller’s default. The maximum configured fee is 1000 bps. `minAmountOut` checks the net output. At atomic-unit dust sizes the rounded fee can consume the full output; require a positive minimum output to reject that case.

The `Fill` event after the fee upgrade includes a final `uint256 fee` field. Indexers scanning across the upgrade must also decode the older six-argument event as fee zero. Track `/v0/fees` cumulative `accrued` amounts for billing; current balances can also reflect other account activity.
