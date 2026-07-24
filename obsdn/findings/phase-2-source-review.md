# OBSDN — Phase 2 Analysis

## Source Files Reviewed
- `Obsdn.sol` — Main entry (governance, routing, sequencer operations)
- `Matching.sol` — Order matching & settlement engine
- `BalanceModule.sol` — Deposits, withdrawals, transfers
- `OrderModule.sol` — Order signature verification & routing
- `Roles.sol` — Role definitions
- `Errors.sol` — Custom errors
- `Math.sol` — Fixed-point arithmetic

---

## Finding 1: Negative Maker Fee → Free Money from Insurance Fund [MEDIUM]

**File:** `Matching.sol`
**Line:** `if (fees.maker < 0) { spotLedger.payMakerRebate(...); fees.maker = 0; }`

The sequencer provides the `fees` struct. If `fees.maker` is negative (maker rebate), the protocol pays the rebate from the maker rebate payer account. Then `fees.maker` is set to 0, so the maker isn't charged a fee either.

**Scenario:** A sequencer could set `fees.maker = -MAX_REBATE` for their own orders, effectively getting paid from the protocol's maker rebate reserve AND paying zero fees. The `_validateReferrals` check caps the referral rebate, but the maker fee itself has no lower bound (only an upper bound through `_validateTradingFee`).

**Impact:** If the maker rebate payer account has insufficient funds, the protocol might attempt to rebate more than available → debt accrual.

**Severity:** Medium — requires malicious sequencer; limited by `MAX_REF_REBATE_RATE` on referral rebates, but the negative maker fee itself has no explicit floor.

---

## Finding 2: No Oracle Price Validation in Match Settlement [MEDIUM]

**File:** `Matching.sol`
**Lines:** `uint128 matchPrice = maker.price; ... _settleQuoteBalance(... matchPrice)`

The match price is taken directly from the maker order — there is **no check against an oracle or index price** anywhere in the settlement flow. For a perp DEX, this means positions can be opened/closed at any price the sequencer submits.

**Context:** This is standard for a hybrid DEX where the sequencer is trusted with ordering and price validation off-chain. However, if the sequencer key is compromised, an attacker can:
1. Match orders at manipulated prices
2. Cause bad debt by liquidating at favorable prices
3. Extract value from position settlement math

**Mitigation:** The `MatchExpectations` assertions (`doAssertMaker`/`doAssertTaker`) can detect post-state discrepancies, but this only works if the counterparty sets correct expectations.

**Severity:** Medium — inherent to the architecture; the multisig sequencer is a trusted role.

---

## Finding 3: Position Flip Settlement Math [LOW]

**File:** `Matching.sol`
**Function:** `_settleQuoteBalance`, Case 1 (flip)

```solidity
int128 closeAmount = position.quoteBalance + position.size.mulX18(matchPrice.safeInt128());
amountToSettle = closeAmount;
newQuote = -newSize.mulX18(matchPrice.safeInt128());
```

When a position flips (long→short or short→long), the old position is fully closed at the match price and a new position opens at the same price. This means:

- All unrealized PnL is realized at the match price
- The new position starts with `newQuote = -newSize * matchPrice`

This is mathematically correct. However, if `matchPrice` is far from the true market price (see Finding 2), the realized PnL can be wrong. The flip effectively uses the match price as both close AND open price, which can be gamed.

**Severity:** Low (architectural, requires malicious sequencer)

---

## Finding 4: No Slippage Protection in Settlement [LOW]

**File:** `Matching.sol`
**Function:** `_settleQuoteBalance`, Case 4 (partial close)

```solidity
int128 cost = Math.mulDiv(-matchSize, position.quoteBalance, position.size);
amountToSettle = cost - matchQuoteSize;
newQuote = position.quoteBalance - cost;
```

The partial close uses a **proportional cost basis** method. `cost` is the quote amount proportional to the fraction being closed. The `MatchExpectations` can catch discrepancies if set, but the default case doesn't enforce any price-based slippage.

---

## Finding 5: Cross-Contract Reentrancy Path [INFO]

**File:** `Obsdn.sol` and `Matching.sol`

The `matchOrders` flow:
1. `Obsdn.matchOrders()` calls `OrderModule.matchOrders()` with `onlyRole(SEQUENCER_ROLE)`
2. OrderModule verifies signatures via `sigValidator.isValidSig()` (external call)
3. OrderModule calls `matching.matchOrders()` with `onlyObsdn` modifier
4. Matching calls `spotLedger.settleQuoteBalance()` (external call)
5. Matching calls `perpLedger.updatePositions()` (external call)

The call chain involves multiple external contracts. `ReentrancyGuardUpgradeable` is applied at the `Obsdn.matchOrders` level, which protects the main entry. However, if any of the ledger or validator contracts are upgradeable (they are — all use proxies) and have a malicious implementation, they could reenter through the `onlyObsdn` path.

**Mitigation:** The `onlyObsdn` modifier on `Matching.matchOrders` limits entry to the Obsdn contract which has reentrancy protection. The `onlyRole(SEQUENCER_ROLE)` ensures only sequencers can initiate.

**Severity:** Informational — standard concerns with upgradeable contracts.

---

## Finding 6: Withdrawal with `try/catch` Swallows Failures [INFO]

**File:** `Obsdn.sol`, `processWithdraw`

```solidity
try BalanceModule.withdraw(IObsdn(address(this)), params) {
    emit Withdraw(..., OpStatus.Success, seqNum_);
} catch {
    emit Withdraw(..., OpStatus.Failure, seqNum_);
}
```

Withdrawals are submitted by the sequencer and failures are caught silently — only the event status changes. This means:
- A failed withdrawal still advances the nonce (the nonce check happens BEFORE the try/catch)
- The user can retry with a new nonce
- Funds are never lost — they just stay in the protocol

**Severity:** Informational — correct by design for sequencer-based withdrawals.

---

## Phase 2 Verdict

| Finding | Severity | Type |
|---------|----------|------|
| 1. Negative maker fee has no floor | MEDIUM | Economic / Sequencer Trust |
| 2. No oracle price validation | MEDIUM | Architecture / Sequencer Trust |
| 3. Position flip math | LOW | Economic |
| 4. No slippage protection | LOW | UX / Economic |
| 5. Cross-contract reentrancy | INFO | Architecture |
| 6. Withdrawal try/catch | INFO | Design Choice |

**No critical bugs found yet.** The code is clean and follows standard perp DEX patterns. All real vulnerabilities require a malicious or compromised sequencer, which is an accepted trust assumption for the hybrid model.

**Next:**
- Review `FundingModule.sol` (funding rate calculation)
- Review `AccountModule.sol` (vault/subaccount creation)
- Review `AccessControl.sol` (custom ACL)
- Fork test on Monad RPC
