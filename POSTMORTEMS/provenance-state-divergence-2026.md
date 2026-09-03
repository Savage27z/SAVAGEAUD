# Provenance (Cosmos SDK) — Zero-Equality Access Bypass, 82 markers / ~$500K (Aug 25, 2026)

**Lesson:** ToB's framing is the keeper — **an authorization predicate must never be
satisfiable from the attacker's default state.** Provenance's marker module checked
"caller controls 100% of supply" as `caller_balance == marker.stored_supply`, but for
non-fixed markers the stored supply field **always stays 0** (bank module is the real
source of truth, never written back). So the check became `0 == 0` → **true for any
caller holding zero tokens**. Anyone could self-grant `ACCESS_ADMIN + ACCESS_MINT +
ACCESS_WITHDRAW` on 82 live mainnet markers in **two transactions**.

Sources: Trail of Bits tweet `2092209135651557648`, blog post
https://blog.trailofbits.com/2026/08/25/state-divergence-enables-unauthorized-access/

## What a marker is

Provenance's fungible-token primitive. Each marker controls a denom, an access list
(who can mint/burn/withdraw/deposit/administer), a stored supply field, and an escrow
balance (can hold ANY asset, not just its own denom). Markers are either
`supply_fixed` (hard cap) or **non-fixed** — for non-fixed markers the bank module is
the source of truth and the marker struct's supply field is informational and never
updated after activation. That divergence is the bug.

## The bug (plain English)

`AddAccess` lets someone change a marker's admin list if ANY of:
1. They're the marker's manager and it's Finalized, OR
2. They already have ACCESS_ADMIN, OR
3. **They hold 100% of the marker's circulating supply** ← the check that broke

The supply check read the marker's **stored** supply field (always 0 for non-fixed
markers) instead of the live bank-module supply:

```go
supply := m.GetSupply()   // stale field → 0
return supply.Equal(coin(m.GetDenom(), callerBalance))  // 0 == 0 → true
```

Attacker balance 0, stored supply 0 → `0 == 0` passes. The "only a full-supply holder"
guard was **unconditionally true for anyone with no tokens** — i.e., satisfiable from
the default state. Classic authz failure mode: comparing against a value that always
equals the attacker's starting condition.

## Exploit — two transactions, no capital

1. `MsgAddAccessRequest`: self-grant `ACCESS_ADMIN + ACCESS_MINT + ACCESS_WITHDRAW`
   on any vulnerable marker.
2. Either `MsgMintRequest` (print tokens of the denom to any address) or
   `MsgWithdrawRequest` (drain whatever the marker's escrow holds — escrow can hold
   assets of ANY denom, e.g. nhash on a token marker).

## Impact (confirmed on mainnet at discovery)

- **82 active markers** had stored supply 0 while carrying real circulating supply or
  escrowed assets — all exploitable, spanning multiple independent parties.
- **Escrow withdrawal (the money path):** markers escrowing nhash (Provenance's base
  token) ≈ 30 × 10¹⁵ nhash ≈ **~$500K** at discovery prices. The three biggest are
  chain governance programs:
  - `grant0051` (Provenance Foundation grant program) — 19.23e15 nhash
  - `provenance.validator.incentive.program` (validator incentive fund) — 8.56e15 nhash
  - `grant0077` (Foundation grant program) — 2.49e15 nhash
- **Supply inflation (74 markers):** bridged stables/wrapped (`uusd.trading`,
  `uusdc.figure.se`, `nbtc.figure.se`), consortium deposits (`cusd.deposit`), tokenized
  mortgage participations (`cguaranteedrateomni`, `chomebridgeomni`), yield tokens
  (`nuva.ylds`, `uylds.fcc`). KYC-restricted tokens → solvency/integrity attack;
  non-restricted coin types → direct inflation.

## The fix — why the first patch wasn't enough

- **Mitigation v1.28.0 (PR #2627, commit `c81fd65`): zero-guard.** `AddAccess` check
  returns false when stored supply is nil/zero. Blocked the reported attack (all 82
  markers had stored supply 0) but **did not fix the divergence** — the comparison
  still read the stale field, so it still passed whenever the stale field was
  non-zero and balance happened to match.
- **Full fix v1.29.0 (PR #2734): one line.** `supply := m.GetSupply()` →
  `supply := k.bankKeeper.GetSupply(ctx, m.GetDenom())`. Both sides of the comparison
  now come from the bank module.
- **Zero-guard kept on purpose:** a freshly deployed, unfunded marker has live supply
  of 0 too — without the guard, an attacker could self-admin a marker before it's
  funded. `accountControlsAllSupply` returns false whenever live supply is zero,
  regardless of balance.

## Transferable lessons (Cosmos SDK + EVM both)

1. **`balance == supply` authorization is a footgun** when either side can be zero.
   Predicates must fail closed from the attacker's default state — never be
   satisfiable by doing nothing.
2. **Two sources of truth for one quantity = divergence.** Marker struct supply vs
   bank-module supply; token `totalSupply()` vs sum-of-balances vs stored state. If a
   state field is "informational" for some lifecycle states, every read of it in a
   security predicate is a bug candidate. Hunt: grep authz checks for reads of
   stored-supply / cached fields that are only kept current for one flavor of the
   object.
3. **Admin-self-grant as the pivot**: the bug isn't a drain by itself for every
   marker — it's a universal key. Pair it with mint or escrow-withdraw (escrow can
   hold arbitrary assets → cross-denom theft). Always ask "what can this access
   level do" after finding an access-bypass, not just "can I drain this one pool".
4. **Escrow/treasury markers holding base token = prize.** Three governance escrows
   (validator incentives + grants) were the highest-value targets — funds parked with
   no active owner watching.
5. **The "informational field" smell**: any comment saying a field is informational /
   not canonical / only for display → verify it isn't read in a guard.
6. **Property worth fuzzing:** `accountControlsAllSupply` should be true ONLY when
   live supply > 0 AND caller holds all of it. A stateful fuzzer that mints, transfers,
   and creates empty markers would hit both failure modes (stale field AND
   zero-supply fresh marker) automatically.

## Receipts
- Tweet: Trail of Bits `2092209135651557648` (Aug 25, 2026)
- Blog: https://blog.trailofbits.com/2026/08/25/state-divergence-enables-unauthorized-access/
- Mitigation PR #2627 (`c81fd65`) — zero-guard, v1.28.0
- Full fix PR #2734 — read live bank supply, v1.29.0
- Reported Apr 1, 2026 → mitigated May 1 → fully fixed Jun 8
