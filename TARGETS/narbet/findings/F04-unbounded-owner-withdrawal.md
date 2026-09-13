# F04 — `withdrawNativeFunds` is UNBOUNDED: the operator can take 100% of the pool, with no event, and it brick-blocks in-flight bets

**Target:** nar.bet BankRoll `0x71dc4a726C92E6bf506F2Afc2Cee8B63A89B29EC` (Monad mainnet, chainId 143)
**Severity:** High (operator/centralization class; up to Critical if the operator key is treated as
untrusted). **Likelihood: certain** — the function call succeeds today, it is one call, no timelock.
**Status:** reproduced on an anvil fork of mainnet with receipts. No mainnet write was made.

## The bug in one line

`withdrawNativeFunds(address to, uint256 amount)` lets the **owner** move any amount of the pool's
native MON to any address, **bounded by nothing** — not by accrued fees, not by a cap, not by the
payout obligations of in-flight bets. It is also **silent**: the drain emits zero logs.

## Receipts

Fork of Monad mainnet at block 104496600 (real code, real state), script
`recon/fork_v10_drain_ab.py`:

| step | result |
|---|---|
| pool before | **527,753.74 MON** |
| `withdrawNativeFunds(owner, 527,653.74)` | **status 0x1**, pool → **0.00 MON**, owner → 528,753.73 MON |
| logs emitted by that call | **0** |
| `calculatedIncome(owner, native)` (owner's accrued income) | **0.0 MON** |

So the owner's *accrued* income was zero while a single call moved 527,753 MON. There is no bound
tying the withdrawal to fees earned, and no bound tying it to the principal LPs contributed.

### It is not merely "owner can upgrade anyway" — it bricks live gameplay

Clean A/B in the same script, same block, same winning outcome (`_entropyCallback` with a known
winning random):

- **A — control, pool intact:** bet 100 MON → settle → **status 0x1**, player **+190.00 MON**.
- **B — owner drains the pool first:** bet 100 MON → drain (status 0x1, 0 logs) → settle the *same*
  winning outcome → the callback **reverts** (status 0x0, and the pre-check `eth_call` fails), player
  receives **+0.00**, and `GetState(player)` stays `[1e20, 349916, 0, 104496603, 1, 0]` —
  **`awaiting = 1`, i.e. the request never settles and never will.**

The payout path itself fails in isolation too: simulating `transferPayout(player, 100 MON, native)`
against the drained pool reverts with custom error `0x9b8d1cd9`.

An upgrade-based rug requires deploying malicious code (and emits `Upgraded`); this requires **one
already-present call** and tells the chain nothing.

## Why this is a defect and not just "an admin power"

- The contract is presented as a **share-based LP pool** (`userShares`, `tokenTotalShares`, a public
  `deposit`/`withdraw`). An LP's shares are a claim on the pool — but the pool can be emptied by a
  function that never checks what it is leaving behind.
- `withdrawFunds(address,address,uint256)` is the ERC-20 twin. The pair reads as *fee withdrawal*
  (the BankRoll tracks `calculatedIncome`, and `getFeeInfo` shows a 10%-to-owner split) —
  **a fee function with no fee bound**. That is the classic unbounded-admin-withdrawal class.
- The drained state is not recoverable: the pool also **cannot be refilled** (see F05 — every deposit
  reverts), so the drain is one-way for both LPs and players.

## Trust root (severity input, verified live)

- Owner `0x4aD0d8f0A100A74547e4B66C008CaE6e91Ef6d8b` is **not** an EOA: `eth_getCode` returns
  `0xef010063c0c19a282a1b52b07dd5a65b58948a07dae32b` — a **23-byte EIP-7702 delegation designator**
  (delegate `0x63c0c19a282a1b52b07dd5a65b58948a07dae32b`, 11,185 bytes of code). So it is a single key
  operating through smart-account code — **no multisig, no timelock** was observed on the drain path
  (it executed immediately).
- The same owner controls the game proxies; a *different* owner (`0xb34f876c…`) controls the three
  minimal proxies seen in recon.

## Honest caveats (for triage, not for the report)

- An owner who can upgrade the implementation can already cause any outcome. The *distinct* claims
  here are: (a) the drain needs no upgrade and emits nothing, (b) it bypasses any notion of accrued
  fees, and (c) its side effect on in-flight bets is a hard revert — a player-facing outage, not just
  an LP loss. Which of those a program accepts as "by design" is the team's call; none of them are
  documented in the app.
- No mainnet write was performed; every number above is fork state.
- MON/USD was not priced here, so the $ impact of 527,753 MON is left for the report step.

## Follow-ups this opens

1. Confirm on the live contract whether `withdrawNativeFunds` has moved funds historically
   (needs a tx index — Monadscan API key, or an archive node tx scan). The BankRoll emits no events,
   so only sender/tx tracing can answer it.
2. Same unboundedness check for `withdrawFunds` (ERC-20 twin) and `withdrawNativeFunds`' cap
   semantics across the other whitelisted tokens — no non-native token is whitelisted today.
3. Whether the games expose a payout path that reverts identically for *players* in normal operation
   (e.g. when a single bet exceeds remaining liquidity) — the `0x9b8d1cd9` error should be named.
