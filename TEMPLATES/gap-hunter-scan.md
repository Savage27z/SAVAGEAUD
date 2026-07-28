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

### Seam 4 — Three-Way
All three at once.

- [ ] A control path interacts with periphery → periphery return triggers code branch → end state violates protocol purpose

### Output
```
seam: execution×periphery / periphery×first-principles / execution×first-principles / three-way
trace: call sequence — internal step → periphery interaction → end state
violated_principle: protocol guarantee the end state contradicts
proof: concrete trace showing the seam
```

---

## Pass 2: Trust Gap (access control × economics × asymmetry)

### Seam 1 — Access × Economics
Correct access guard + correct formula — but permitted actor can systematically extract value.

- [ ] onlyKeeper / onlyRole function with sandwich-able parameters (amountOutMin = 0, no slippage protection)
- [ ] Privileged actor whose action has a front-run-able economic effect
- [ ] Role that can trigger a function with MEV-able inputs

### Seam 2 — Economics × Asymmetry
Formula whose result differs by caller class — difference is exploitable.

- [ ] Deposit uses spot price, withdraw uses TWAP (or any paired formula mismatch)
- [ ] Fee rates differ by user class without arbitrage protection
- [ ] Same operation priced differently depending on entry path

### Seam 3 — Access × Asymmetry
Privileged actor creates asymmetry between users.

- [ ] Admin setter that alters destination of in-flight economic value (setFeeRecipient redirecting unclaimed fees)
- [ ] Parameter change that retroactively affects pending operations
- [ ] Hooks/rewards where recipient is settable but past accruals do not checkpoint
