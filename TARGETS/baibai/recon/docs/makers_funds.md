> ## Documentation Index
> Fetch the complete documentation index at: https://docs.baibai.cx/llms.txt
> Use this file to discover all available pages before exploring further.

# Deposits & withdrawals

> Inventory crediting, withdrawal reservations and delays, and operator powers.

Coordinate [onboarding](/makers/onboarding) with Spire before funding. Maker approval gates quoting; the deposit contract itself is permissionless.

Deposits and withdrawals are the only on-chain transactions you ever make. Everything in between (quoting, fills, balance accrual) is off-chain and costs you no gas.

Funds sit in the custodian contract (`BaibaiCustodian`, address provided at onboarding): a single vault, separate from the pricing logic, behind a withdrawal delay. The vault keeps no per-maker balances. Your running balance lives in the platform ledger, published as [checkpoints](#checkpoints); the only per-maker state on-chain is a settled withdrawal claim.

## Depositing

Your deposit is what backs your quotes. A book whose total exposure exceeds your deposited inventory is rejected with `inventory_exceeded` at admission. The platform tracks each maker's inventory separately. Tokens are pooled on-chain; the contract does not enforce a separate balance for each maker.

The flow is standard ERC-20, from the wallet that owns your maker account:

```solidity theme={null}
IERC20(token).approve(custodian, amount);
IBaibaiCustodian(custodian).deposit(token, amount);   // emits Deposited(you, token, amount)
```

`deposit` is stateless on-chain: tokens move into the vault and `Deposited` is emitted, nothing is stored. The platform's chain watcher picks up the event and credits your ledger balance, and from then on the inventory is quotable. Deposit both tokens of a pair if you want to quote both sides: asks are backed by your base-token balance, bids by your quote-token balance.

<Warning>
  **The ledger trails the chain**

  The watcher normally polls every 500 ms. A deposit becomes usable after its event is verified and the resulting ledger generation is durable. Wait for [`GET /v0/makers/{maker}/limits`](/makers/http-api) to show both `ledger.ready: true` and the expected available balance. Mining alone does not make the deposit quotable.
</Warning>

<Warning>
  **Deposit from your maker address only, and only served tokens**

  The ledger credits `msg.sender`. A deposit sent from any other address credits that address, not your maker account. Never transfer tokens directly to the custodian; use `deposit()`. And deposit only the base and quote tokens of pairs this deployment serves (use the token addresses in the deployment manifest; `/v0/pairs` reports symbols): the contract accepts any ERC-20, but the ledger ignores `Deposited` events for tokens no served pair trades, so such a deposit is never credited.
</Warning>

Your current quotable inventory and limits are readable at [`GET /v0/makers/{maker}/limits`](/makers/http-api). The inventory there is your ledger balance minus anything reserved for a pending withdrawal (below).

## Withdrawing

Withdrawal is three steps: you request, the platform settles your claim on-chain, and after a delay you execute. The contract enforces a delay after settlement. It does not verify that the off-chain watcher has processed every fill or that a checkpoint is correct.

### Step 1: request

Per token, full or partial, from your maker address:

```solidity theme={null}
IBaibaiCustodian(custodian).requestWithdraw(token, amount);
// emits WithdrawRequested(you, token, amount)
```

`requestWithdraw` writes no state and starts no clock. It only emits `WithdrawRequested`; the contract does not check that you have a balance (it holds no balances to check). The platform's watcher sees the event and reserves the requested amount out of your quoting inventory: a partial request leaves the remainder quoting, and your limits drop by the requested amount as soon as the watcher has seen the block.

### Step 2: the platform settles

The reservation also reduces an existing book, even if you are only sending heartbeats. Settlement waits for the watcher to observe that older published exposure has been replaced, including any prepared publication that could still land. A stalled publisher, stale ledger, or integrity halt can therefore delay settlement. The contract delay has not started during this wait.

The platform answers each request by writing your claim on-chain. It cuts a fresh checkpoint of its current ledger first, then a curve-book poster calls:

```solidity theme={null}
function settleWithdraw(address maker, address token, uint256 amount, uint256 expectedPrevious, uint256 basis) external;
// emits WithdrawSettled(maker, token, amount, basis, readyAt)
```

Only a poster can call this; you never do. `amount` is your total requested-but-unexecuted amount for that token, clamped to your ledger balance: if you request more than you hold, the claim is written for what you hold and the excess reservation is released. Settlement writes `readyAt = block.timestamp + withdrawDelay()` and emits `WithdrawSettled` with that `readyAt`. The delay runs from settlement, not from your request.

The settle worker polls every second and the watcher normally every 500 ms. Healthy requests can settle within seconds, but these intervals are not a settlement deadline. Any positive token amount may be requested; zero reverts. Once safe settlement is possible, an unfunded request is answered with a zero claim, releasing its reservation.

Watch for it either way:

* Read the claim: `custodian.claim(maker, token)` returns `(uint256 amount, uint64 readyAt)`. `amount == 0` can mean no settled claim, a zero or canceled claim, or an already executed claim. Use events to distinguish them.
* Or index `WithdrawSettled(address indexed maker, address indexed token, uint256 amount, uint256 basis, uint64 readyAt)`. `basis` is internal bookkeeping the platform uses to reconcile its own reservations; ignore it.

Settlement is set-not-add. If you send a second `requestWithdraw` for the same token while a claim is pending, the platform re-settles the claim to the new total and `readyAt` restarts for the whole amount. Top up a pending request only if you accept the clock restarting.

### Step 3: execute

After `readyAt`, from the same address:

```solidity theme={null}
IBaibaiCustodian(custodian).executeWithdraw(token);
// transfers the claim to you, emits WithdrawExecuted(you, token, amount)
```

`executeWithdraw` pays the whole settled claim to `msg.sender` and clears it. Before the platform has settled, it reverts with `NoClaim()`. Between settlement and `readyAt` it reverts with `ClaimNotReady(uint64 readyAt)`, carrying the timestamp to wait for. The watcher sees `WithdrawExecuted`, debits your ledger balance, and releases the reservation.

Settled claims stop backing swaps: the custodian's `availableLiquidity(token)` is its holdings minus the sum of settled claims, and a swap cannot spend it.

### The delay

`withdrawDelay()` is readable on the custodian. The Base deployment uses 600 s (10 minutes); read the contract value before withdrawing. The custodian owner can change it with `setWithdrawDelay`; a change applies to claims settled after it, and already-settled claims keep their `readyAt`.

## Checkpoints

`GET /v0/checkpoints/latest` returns the ledger's latest published state:

```json theme={null}
{"id": 17, "timestamp": 1787664000, "ack_fill_seqs": {"WETH-USDC": 4213},
 "balances": [{"maker": "0x…", "balances": [{"token": "0x…", "amount": "10250.75"}]}]}
```

`ack_fill_seqs` names, per market, the highest fill these balances include. Checkpoints are published on a fixed cadence (60 seconds on Base) and freshly before withdrawal settlement. Reconcile balance changes against [attributed trading flows](/makers/fills-and-latency#how-settlement-is-computed), deposits, and executed withdrawals. A trading-only interval equals the sum of your attributed legs. The sum of maker balances should be covered by the custodian's actual token holdings, which anyone can read.

Checkpoints are public and list every maker's balances by address. See [Trading and allocation](/makers/trading-and-allocation#what-is-public).

## Custody design

A few facts about the contracts, for evaluating counterparty risk. This describes what the shipped contracts allow, not what Spire intends to do with them.

Custody and pricing are separate contracts. The vault (`BaibaiCustodian`) holds the funds; the pricing and settlement logic (`BaibaiEntrypoint`, with the curve in `BaibaiCurveBook`) is separate. All three are UUPS proxies. Upgrading pricing is an implementation swap on the entrypoint; it never moves funds and never requires makers to migrate.

The vault grants no allowances. Swap output leaves the vault only through `payOut(token, to, amount)`, which only the configured entrypoint may call, and which reverts if `amount` exceeds `availableLiquidity(token)` (holdings minus settled claims). There is no per-swap approval and no per-swap cap: what bounds the entrypoint is that it is the only caller and that settled claims are carved out. A compromised or maliciously upgraded entrypoint could pay out everything not reserved by a settled claim.

The owner can change the contracts. The owner (a two-step `Ownable2Step` account) can upgrade the custodian, the entrypoint, and the curve book, add or remove posters on the curve book, and set `withdrawDelay` to any value including zero for future settlements. There is no pause switch and no outflow cap in the shipped contracts. The withdrawal delay therefore bounds how fast a settled claim pays out; it does not bound what an owner with upgrade authority can do. The Base deployment uses a dedicated 1-of-1 Safe owner and a separate EOA poster, with no general owner timelock. Verify identities in [Deployments](/takers/deployments).

Posters write claims but cannot redirect them. `settleWithdraw` is poster-only and can write any maker's claim to any amount the vault's holdings cover, but `executeWithdraw` pays only `msg.sender`, so a claim is always paid to the maker it names. A wrong claim can be lowered or cancelled by a later settle (lowering always succeeds); the delay is the window in which that happens.

Stale prices fail closed. If the platform stops refreshing the on-chain curve, `quote()` returns zero and swaps revert once the curve TTL passes. No feed means no executable price, rather than a stale price trading against pooled inventory.

## Fees

Maker fees are negotiated with Spire on a case-by-case basis and settled separately. The fill amounts and balances reported by the API do not include those charges.
