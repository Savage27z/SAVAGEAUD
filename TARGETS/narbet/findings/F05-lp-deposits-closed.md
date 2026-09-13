# F05 — LP deposits are impossible on the live contract (and the BankRoll emits no events)

**Target:** nar.bet BankRoll `0x71dc4a726C92E6bf506F2Afc2CEE8b63A89B29EC` (Monad mainnet)
**Severity:** Medium (functional/availability: the LP pool is closed and one-way)
**Status:** verified on the **live chain**, not only on a fork.

## What happens

`deposit(address token, uint256 amount)` (the public LP entry point):

| call | live result |
|---|---|
| `deposit(native, 1 wei)` | `require: Staking amount exceeds limit` |
| `deposit(native, 1 MON)` | `require: Staking amount exceeds limit` |
| `deposit(native, 500 MON)` | `require: Staking amount exceeds limit` |
| `deposit(native, 1,000 MON)` | `require: Staking amount exceeds limit` |
| `deposit(native, 0)` | `require: Amount must be greater than 0` |
| `deposit(WMON, 1 MON)` | `require: not whitelist token` |

The require **order** is the decisive detail: `amount = 0` trips "Amount must be greater than 0",
while `amount = 1 wei` gets past that and trips "Staking amount exceeds limit". So the amount check
is satisfied correctly and the *limit* check then rejects **every positive value** — the limit is
effectively **zero**. There is no amount that can be deposited: not 1 wei, not 1,000 MON.

Only the native token is whitelisted (`WMON → "not whitelist token"`), so the WMON path is not an
alternative route in.

**Consequence:** the pool holds **527,753.74 MON** of LP capital and can never be added to. Combined
with F04 (an uncapped, zero-log owner withdrawal), the LP side is strictly one-way: it can be emptied
but not refilled, and nothing about it is observable on-chain.

## Supporting facts

- **The BankRoll emits no logs at all.** A chunked scan of its address over 30 days (~5.2 M blocks)
  returned **0 logs**, and the F04 drain transaction itself emitted **0 logs**. Share movements,
  deposits and withdrawals here would leave no on-chain trace.
- `unlockTimestamp(address,address)` (`0xb84e8289`, identified by dictionary match against the live
  responses) is a per-player, per-token withdrawal lock. The current owner's native entry reads
  `1777763479` (a past timestamp); other probed addresses read `0`.

## Two readings — I cannot distinguish them without source (stated plainly)

1. **Deliberate closure.** The operator set the staking limit to 0 to stop deposits (wind-down,
   migration, or risk reduction). Nothing in the app communicates this.
2. **A broken/inverted limit.** A limit that was never initialised, or a comparison written the
   wrong way round, in which case deposits have been silently impossible for as long as the limit has
   been 0 — the pool has been running on whatever liquidity it had.

Evidence favours neither conclusively. What is *not* in question is the observable state: **no one
can deposit today**, deposits of any size revert, and the failure mode is a plain `require` string
rather than a pause flag — so a user (or an integrator) sees "amount exceeds limit" for an amount of
1 wei, which is unintelligible. If it *is* deliberate, it is undocumented; if it is a bug, it has
been live and silent.

## Relation to the rest of the picture

- F04: the owner can drain 100% of the pool in one call, bounded by nothing, emitting nothing.
- F05 (this): nobody can refill it, and no event ever marks a share movement.
- F01–F03: the game-side money paths (refund, settlement, suspension) were each tested and hold up.

So the game logic looks careful while the **bankroll around it is a zero-visibility, operator-
controlled, one-way vault of 527,753 MON**.

## Suggested fix (for the disclosure step)

Bound `withdrawNativeFunds`/`withdrawFunds` by accrued fees (`calculatedIncome`) or by a
`totalShares`-denominated solvency invariant that preserves funds for in-flight bets; emit
`Deposit`/`Withdraw`/owner-withdrawal events; and make the staking limit either an explicit pause
flag with a clear message or remove the zero limit.
