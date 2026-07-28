# Gap-Hunter Scan

Run after standard multi-agent passes. Each gap-hunter pass targets bugs at the SEAMS between lenses — bugs no single-lens scan can find.

**Key rule:** Do NOT report bugs a single-lens scan would catch (reentrancy, missing modifier, etc.). Only report bugs that REQUIRE 2-3 lenses to see.

---

## Pass 1: Flow Gap (execution × periphery × first-principles)

### Seam 1 — Execution × Periphery
A control path that is internally correct but whose downstream periphery call returns something that derails the trace.

- [ ] Trace computes value BEFORE periphery call, uses it AFTER (fee-on-transfer, rebasing, sync state)
- [ ] Flow depends on periphery returning specific structure (bool, length, decimals) that non-standard contracts may not
- [ ] Delta-check: received = balance_after - balance_before followed by >= amount — reverts on fee-on-transfer
- [ ] Callbacks/hooks moving control mid-flow — post-callback code assumes pre-callback state

### Seam 2 — Periphery × First-Principles
External interaction safe in isolation but defeats protocol stated purpose when chained.

- [ ] safeTransferFrom to token that violates protocol guarantee (rebasing, blacklist, double-entry)
- [ ] User-controllable identifier (externalId, nonce) keying refund/state map without occupancy check
- [ ] Cross-chain message handler iterating over user-controlled length — bricking delivery

### Seam 3 — Execution × First-Principles
Execution path completes without reverting but end-state contradicts protocol intent.

- [ ] Multi-step operation where steps are individually correct but combined end-state breaks semantics
- [ ] Position update triggers funding settlement using new size against old rate (or vice versa)
- [ ] Shared state written by X, read as ground truth by Y — attacker bridges contracts to convert phantom state to real claims
