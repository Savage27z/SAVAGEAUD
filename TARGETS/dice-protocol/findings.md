# DiceEntropy — Findings (Phase 1 source read, 2026-09-03)

**Verdict: 🟢 No critical findings — 4 low/informational observations.**
Pyth Entropy-derived commit-reveal oracle; core math (hash-chain commitments,
two-party reveal, callback w/ gas limit + retry) verified sound. Immutable, admin
separate from provider, fees to vault. Live usage: ~416+ sequences.

---

## F1 (🟡 Low-Med) — Refund vs admin-withdraw race on the shared accruedFees pool
`refundRequest` draws the refund from `_state.accruedFeesInWei` — the SAME pool
`withdrawFees` (admin → vault) drains. Refund requires
`accruedFeesInWei >= amount`:
- If admin withdraws fees while a request is stuck (delayed > refundDelayBlocks), the
  requester's refund reverts until new fees accrue.
- If request flow stops, the stuck requester's fee is **permanently un-refundable**
  (admin cannot withdraw it either — it's below the accounting line — so it just sits).
- Multiple stuck requesters race each other + the admin for pool liquidity.
No theft (fees are small: 0.000025 ETH ≈ $0.06), but it's an accounting flaw: refund
liability should be escrowed per-request or excluded from the withdrawable balance.
*Fix: track `refundableFees` separately from `withdrawableFees`; or escrow each
request's fee until reveal/refund.*

## F2 (🟡 Low) — gasLimit=0 callback path: single attempt, no retry, request cleared first
When a request has `gasLimit10k == 0` (requester passed gasLimit 0 and the provider's
defaultGasLimit is also 0), `revealWithCallback` takes the else-branch:
1. `clearRequest()` runs FIRST (request gone),
2. then the consumer callback is attempted with `gasleft()*15/16` via safe call,
3. failure is only recorded in the event (`callbackFailed=true`) — the request is
   already cleared, so **no retry is possible** and the consumer never receives the
   randomness.
The gas-limited path (gasLimit != 0) has proper retry semantics (CALLBACK_FAILED →
re-call revealWithCallback). Inconsistent: consumers who set gasLimit=0 (meaning "no
limit") get the WEAKEST delivery guarantee. A consumer callback that reverts once
(transient error, their own OOG, an upstream revert) permanently wedges the dependent
app: the random number exists only in an event.
*Fix: keep the request active on callback failure in both paths (clear only after a
successful callback or an explicit refund).*

## F3 (🟢 Info) — reveal() (no-callback) is requester-only → liveness depends on the requester
`reveal` requires `req.requester == msg.sender`; `revealWithCallback` does not.
For no-callback requests, neither the provider nor a relayer can finalize — if the
requester (EOA or app bot) is gone, the request sits until refund (6 L1 blocks ≈ 72s)
and the consumer never gets randomness. Canonical Pyth Entropy allows reveal by anyone
holding both values. Deviation is deliberate-looking but a grief/liveness note for
integrations.

## F4 (🟢 Info) — exact-fee-only payment (`msg.value == fee`)
Request requires exact msg.value == fee; no overpay/refund path. UX friction, not a
bug. Fee is flat and admin-settable (`setFee`, no cap) — admin could raise the fee
arbitrarily; consumers can't predict? (getFeeV2 is readable; fine — but no max cap
note.)

## Verified non-issues
- Commitment advancement happens inside revealHelper BEFORE the callback attempt; a
  failed-callback retry re-validates against the request-time commitment (numHashes
  stored on the request) — no double-advance, no stale-commitment acceptance.
- Short-hash request slot collisions handled via requestsOverflow; clearRequest
  resolves the right slot/overflow entry. allocRequest moves the displaced request to
  overflow before overwrite.
- Callback reentrancy: status = CALLBACK_IN_PROGRESS blocks same-request re-entry;
  refunds clear-before-send.
- advanceProviderCommitment is public but requires knowledge of unrevealed chain
  values (grief requires provider secrets).
- No bias path found: provider cannot know userRandomNumber at request (only its
  hash); user cannot influence the anchored provider chain.

## Out of scope / notes
- Provider ops = Dice's own address (provider == active revealer) — single-provider
  model; re-registration (admin `registerFor`) needed soon (chain ~90% consumed).
- `DiceState.sol` + SDK files not in the Blockscout flatten (imports unresolved) —
  storage layout inferred from usage; no contradiction found.
