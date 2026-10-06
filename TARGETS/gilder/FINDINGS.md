# GILDer Financial — Findings

Target: **GILDer** (`gilderfinance.com`), Base, chain 8453.
DefiLlama: $118,091 TVL, 45.7 days, `audits = 0`, non-DEX. Source `exact_match` on Sourcify (11/11 contracts, verified 2026-08-03).

Core: `BondContract` `0x5d25cfc927f95cb519c0fef438afaa64cb374e10` (23,617 B, 104 fns).
Model: "non-custodial fixed-term deposit protocol. Users deposit USDC into 3-year Term Deposits represented as NFTs; 80% of each deposit is deployed."

Read out by pass scripts `_gilder_pass1.py` … `_gilder_pass7.py`. Every number below is a live `eth_call` against Base, reproducible.

---

## VERDICT TABLE

| # | Lead | Class | Status |
|---|------|-------|--------|
| 1 | `DEFAULT_ADMIN_ROLE` on a bare EOA, contradicting the source's own doc | Trust / deployment-vs-design | **CONFIRMED** |
| 2 | Interest obligation unfunded — reserve covers 18.3% of it, and the loan book can only fund it at ~99% APR | Economic / solvency | **CONFIRMED** |
| 3 | "proxy admin is a bare EOA, instant upgrade" | Trust | **RETRACTED** (my probe bug) |
| 4 | `creditEarlyExitPenalty` ungated | Access control | **FALSE** — gated by `msg.sender == safeVault` |
| 5 | Interest double-credit via re-computation in `earlyExit` | Accounting | **FALSE** — `realizedInterest` bumped on all 8 consumption paths |
| 6 | `chargeAbandonedFee` permissionless → repeat-charge | Accounting | **NOT A VULN** — capped at slice, no caller profit, `_lastFeeAssessment` advances correctly |
| 7 | BPS splits sum > 100% | Arithmetic | **FALSE** — `8000+1000+900+100 = 10,000` exactly |
| 8 | `RoundingLib` rounds the wrong way for the protocol | Arithmetic | **FALSE** — `n/d` is a true floor, as its name claims |

---

## FINDING 1 — `DEFAULT_ADMIN_ROLE` sits on a bare EOA that is not a multisig signer

**Impact: High. Likelihood: Medium. Class: deployment contradicts documented trust model.**

The source states the invariant (`contracts__GilderAccessControl.sol`):

> "That second rule is load-bearing. **DEFAULT_ADMIN_ROLE is held by the multisig**…"

On-chain it is **not**.

```
hasRole(DEFAULT_ADMIN_ROLE, 0x54f2316b0c02808354fd7f0d48e64a788f7be533)  = true
code at 0x54f2316b…                                                        = 0 bytes   (4/4 RPCs)
isOwner(0x54f2316b…) on the GilderMultisig 0xb358e81b…                      = FALSE
```

So the holder is (a) an **EOA**, and (b) **not even a signer** on the 5-of-N multisig that the docs say holds the role. It is outside governance entirely. It is also `deployer()`, so it retains un-renounced freeze power (`renounceDeployerFreeze()` was never called).

Through `grantRole`/`revokeRole` on every role, that single key reaches:

- `PARAMETER_ROLE` — every wiring setter (`setLendingContract`, `setLiquidityManager`, `setTokenBuyRouter`, `setSafeVault`, …) plus BPS/rate parameters
- `BOND_ENGINE_ROLE` — `accrueInterest`, `consumeAccruedInterest`, `settleMatured`, `applyInterestToLoan`
- `LENDING_OPERATOR_ROLE`, `LIQUIDATOR_ROLE`, `TREASURY_OPERATOR_ROLE`, `PAUSER_ROLE`

Compromise of one unprotected key therefore reaches the entire role graph. **No exploit is required — the authority is simply in the wrong place, and the protocol's own documentation says it should not be.**

Note: `UPGRADER_ROLE` is **vestigial** in this design. `GilderProxy` gates upgrades with `_onlyProxyAdmin` and never calls `_authorizeUpgrade`, so the upgrade path is multisig + 48h timelock (verified real: `UPGRADE_TIMELOCK = 48 hours`, two-step `proposeUpgrade`/`upgradeToAndCall`). The exposure is the role graph, not the proxy.

**Fix:** `grantRole(DEFAULT_ADMIN_ROLE, multisig)` → `revokeRole(DEFAULT_ADMIN_ROLE, 0x54f2316b…)` → `renounceDeployerFreeze()`.

**Evidence:** `phase1_roles.json`, `phase0_privilege.json`, `_gilder_pass3.py`, `_gilder_pass4.py`.

---

## FINDING 2 — The interest obligation is unfunded; the reserve covers 18.3% of it and the loan book cannot bridge it

**Impact: High. Likelihood: High (it is the current state, not a future risk). Class: economic / solvency.**

The protocol promises, per `BondContract`'s own constants:
`SIMPLE_ANNUAL_RATE_BPS = 2000` (20%/yr) and `FIXED_TERM = 1095 days` (3 years) → **interest of 0.20 × 3 = 60% of principal**, i.e. it owes **160% of principal** at maturity.

Live state (all `eth_call`, Base, cited in `pass7_solvency.json`):

```
totalActivePrincipal (treasury)      197,391.459299 USDC
SafeVault.accountedPrincipal         157,913.167458 USDC   <- exactly 80.0000% of principal
SafeVault.totalLoaned                 39,810.546453 USDC
treasury.interestReserve              21,713.060522 USDC   <- exactly 11% of principal
treasury.operationalReserve          123,156.802726 USDC
treasury.buybackReserve                7,895.658372 USDC

USDC held: SafeVault 118,102.621  Treasury 158,286.258  liquidityRecipient 304.545
TOTAL USDC CONTROLLED                276,693.424 USDC
```

Obligation vs assets:

```
owed principal                       197,391.46
owed interest (20% x 3yr)            118,434.88
TOTAL OWED                           315,826.33

coverage of principal alone             140.17%
coverage of principal + interest         87.61%
SHORTFALL vs the full obligation        -39,132.91
```

**The protocol cannot currently meet its own promises.** It holds 140% of principal but only **87.6%** of principal-plus-interest.

Two independent measurements of the funding gap:

1. **Coverage** — `interestReserve` is $21,713.06 against a $118,434.88 interest obligation = **18.33%**. And it is sized there *deliberately*: `COVERAGE_TARGET_BPS = 1100` (11% of principal) = **6.6 months of accrual against a 36-month term**. The protocol reserves for six months and promises three years.

2. **Deployment** — interest accrues at 20%/yr on $197,391.46 = **$39,478.29 per year**, but only **$39,810.55** is actually out on loan (25.2% of the vault claim; the remaining ~$78K of SafeVault USDC sits idle at 0%). For the loan book alone to fund the accrual it would have to return **99.2% APR**. Even if the entire vault claim ($157,913) were deployed and fully utilised, the requirement is **25.0% APR** — above the 15% loan rate the source itself references. To gross $315,826 out of the SafeVault's $118,102 of actual USDC requires **38.8% CAGR**.

**Structural cause.** 20% of every deposit leaves immediately at open time and never returns:

```
deposit 1,000  ->  SafeVault 800 | token-buy 100 | treasury 90 | liquidity 10
owed at 3yr    ->  1,000 principal + 600 interest = 1,600
```

A liability of 160% is created against an earning base of 80%, with 20% spent at t=0. The liability is fixed and the asset side is not, so the gap widens with every additional deposit unless realised yield exceeds ~26% CAGR on the deployed 80% — through a loan book that is currently 75% idle.

This is **not an exploit** — no attacker drains funds. It is a **solvency / sustainability** defect in the product design, and it is exactly the class that neither a code review nor a third-party audit of the *code* will surface, because every line is internally consistent and correct.

**Evidence:** `pass5_econ.json`, `pass6_impls.json`, `pass7_solvency.json`, `_gilder_pass5.py` … `_gilder_pass7.py`.

---

## RETRACTION — "the proxy admin is a bare EOA"

I previously reported that `0xb358e81b…` (the proxy admin) was an EOA with 0 bytes of code, so one key could upgrade all six proxies instantly. **Wrong, and it was my probe's fault.** The line

```python
n = (len(code) - 2) // 2 if isinstance(code, str) else 0
```

printed `"EOA (!!)"` when an RPC call *failed* and returned `None` — the `else 0` fired and I reported "no code" for "I got nothing back". A failed read is not a zero.

Re-measured across four independent RPCs, raw responses kept, all agreeing: `0xb358e81b…` is a **5,782-byte GilderMultisig** (5 owners, `isUnanimousExecution()` present), and it is also `guardianCouncil()`. The 48h upgrade timelock is real. Design and deployment agree here.

---

## NEGATIVES (checked and cleared — recorded so they are not re-hunted)

- **Interest re-credit in `earlyExit`** — `closeLoanForSettlement` mutates `deposit.accruedInterest`, then line 1467 recomputes it via `_calculateAccruedInterest`, which returns `totalAccrued - realizedInterest`. This *would* re-credit spent interest if `realizedInterest` were not maintained — but it is, on **all eight** consumption paths (`applyInterestToLoan` L554, `consumeAccruedInterest` L815, `sweepInterestForCyr` L861, `settleMatured` L1054, `settleMaturedNet` L1142, `withdrawInterest` L1266, `netLoanInterest` L1355, `earlyExit` L1521). Deliberately defended.
- **`creditEarlyExitPenalty` (L2472)** — no role modifier, but body-gated `if (msg.sender != safeVault) revert NotSafeVault(msg.sender)`.
- **`chargeAbandonedFee` (L1565)** — permissionless by design; fee capped at `safeVaultAmount`, routed to the treasury marketing bucket (not the caller, so no caller profit), and `_lastFeeAssessment` advances to `lastAssessed + elapsedMonths * 30 days`, which is ≤ now with the remainder carried forward. No double-charge, no theft.
- **`RoundingLib`** — `roundDownToProtocol(n, d) = n / d` (true floor, protocol-favourable as named); `roundUpToUser` guards `denominator == 0`.
- **BPS splits** — `SAFE_VAULT_BPS 8000 + TOKEN_BUY_BPS 1000 + TREASURY_BPS 900 + LIQUIDITY_BPS 100 = 10,000`. TURBO variants identical; only `EARLY_EXIT_PENALTY_TURBO_BPS 5000` differs from `EARLY_EXIT_PENALTY_BPS 2000`.
- **Split invariant on-chain** — `accountedPrincipal / totalActivePrincipal = 157,913.167458 / 197,391.459299 = 80.0000%` exactly.
- **`eip712Domain` / signature binding** — n/a here; GILDer does not use a server-signer trade path.

---

## OPEN

- The deposit lifecycle state machine (`Active → Matured → Dormant → Abandoned → Closed`, plus `Exited`/`Liquidated`) — whether the flags are mutually exclusive and every terminal state is reachable exactly once. `markDormant`/`markAbandoned`/`markDormant` are all permissionless.
- `withdrawAbandoned` pays `safeVaultAmount` and **drops the accrued interest** — verify this is intended forfeiture and not an accounting leak.
- The lending/liquidation leg: `closeLoanForSettlement`, `netSettleLoan`, `forfeitCollateral` (claim→0, debt→0, liquidator bonus), `netInterestAgainstLoan`.
- Turbo recursive loop (`Turbo.executeTurboLoop`, `TURBO_LTV_BPS = 7500`) — leverage-by-recursion, `~2.5x` gross.
- **FORK-ATTACK PHASE not yet run for GILDer** (mandatory before any "clean" verdict).

---

## NOTE ON TARGET SELECTION (earned this target)

This file cites `§Code-Review H4 (Jul 2026)`, `§M6 (Jul 2026 client review)`, `§Code-Review C2`, `§Code-Review N4`, `§V6.2`, `§V6.3` — **multiple named internal review rounds**. "Unaudited" on DefiLlama means *no third-party firm signed it*; it does not mean nobody has read it. Expect shallow bug classes to be pre-fished. Both CONFIRMED findings here are therefore in the layer a code review does not touch: the **trust graph** and the **economic structure**.
