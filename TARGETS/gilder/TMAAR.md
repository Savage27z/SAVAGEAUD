# TMAAR — GILDer (Phase 0.5, written BEFORE reading any source)

Target: `gilderfinance.com` · DefiLlama: **GILDer**, Yield, Base, **$118,091 TVL**, **45.7 days old**,
**audits: 0**, no audit links, non-DEX.
Source: **fully public — 11/11 contracts `exact_match` on Sourcify** (verified 2026-08-03), 63 files.
TayDex was picked first and stalled on unverified source; this target is the reverse.

## 1. Trust model (from public material)

> "GILDer is a non-custodial fixed-term deposit protocol on Base. Users deposit USDC into 3-year
> Term Deposits represented as NFTs; 80% of each deposit i[s deployed]" — DefiLlama description

Read as: user USDC enters → a DepositNFT is minted representing a **fixed-term, fixed-rate claim** →
the principal is split across destinations by BPS constants → interest accrues on a simple annual
rate → at maturity the depositor settles. Deposits have a lifecycle: open → matured / dormant /
abandoned / liquidated, with `earlyExit` for a penalty.

**This is a fixed-liability / pre-sold-claims structure** — the bug class where the protocol owes a
fixed future amount but funds it with variable, operator-managed returns. My own anti-pattern
library carries a dedicated entry for it ("Fixed-Liability Vaults — option sales, put sales,
pre-sold claims"). Primary audit question: **can total claims exceed real assets?**

## 2. Actors

| actor | holds | can |
|---|---|---|
| `DEFAULT_ADMIN_ROLE` | role administration | `grantRole`/`revokeRole` on everything |
| `UPGRADER_ROLE` + **proxy admin** | upgrade rights | replace the logic of all 6 proxies |
| `PARAMETER_ROLE` | configuration | rates, BPS splits, and every wiring setter (`setLendingContract`, `setCyrContract`, `setTurboContract`, `setTvtContract`, `setTokenBuyRouter`, `setLiquidityManager`, `setMarketingWallet`, `setDepositValidationFlags`, `setLoanState`) |
| `BOND_ENGINE_ROLE` | interest engine | `accrueInterest`, `consumeAccruedInterest`, `settleMatured` |
| `LENDING_OPERATOR_ROLE` | lending arm | `applyInterestToLoan`, loan state |
| `LIQUIDATOR_ROLE` | liquidation | `markLiquidated` |
| `NFT_MINTER_ROLE` | deposit NFTs | mint `openDepositFor` |
| `TREASURY_OPERATOR_ROLE` | treasury | treasury operations |
| `COMPOUND_OPERATOR_ROLE` | compounding | `setCompoundMode`, autocompound trigger |
| `PAUSER_ROLE` | liveness | `pause`/`unpause` |
| `deployer` | freeze power | freeze; **reducible via `renounceDeployerFreeze`** |
| emergency guardian / freeze authority / `guardianCouncil` | emergency | `emergencyFreeze`/`emergencyUnfreeze` |
| **depositors** (NFT holders) | principal | `openDeposit`, `rollover`, `earlyExit`, `withdrawInterest*`, `settleMatured*` |

External dependencies wired in by setters: a **lending** contract, **turbo**, **TVT**, **CYR**,
**autoCompound**, **tokenBuyRouter**, **liquidityManager**, **treasury**, **SafeVault**, USDC.

## 3. On-chain facts (verified, read-only)

| contract | address | size | verified |
|---|---|---|---|
| BondContract | `0x5d25cfc927f95cb519c0fef438afaa64cb374e10` | 23,617 B | exact_match |
| DepositNFT | `0x809c4ee02279a38c9c32e63d4e1d9f0f8cc7da02` | 10,223 B | exact_match |
| SafeVault | `0x9b937b72172c0706b51984a09992bb8007771e67` | 8,062 B | exact_match |
| GilderTokenBuyRouter | `0xd144cdceb6a49bc9be906964abeb6de5d39952d0` | 4,946 B | exact_match |
| GilderToken | `0xa6c3b8dcb7c31132dcef64ef099f68b731db1e73` | 1,443 B | exact_match |
| 6 × GilderUUPSProxy | `0x13a18c43…`, `0x41e5d0ea…`, `0x904e0e92…`, `0x9e2ce951…`, `0xaa199c56…`, `0xf2e668f7…` | 1,922 B each | exact_match |

Wiring read live: `BondContract.safeVault() = SafeVault`; `BondContract.treasury() = 0x9e2ce951…`
(a proxy); `SafeVault.bondContract() = BondContract`; `GilderTokenBuyRouter.usdc() = USDC (Base)`;
`SafeVault.treasury() = 0` (unset — confirm intent); `paused() = false` on the direct contracts.

**All six proxies share ONE ERC1967 proxy admin:**
`0xb358e81b0f92698215bbe821b8c25986ad523a1b`

## 4. ⚠️ RISK #1 — the whole system's upgrade root is a bare EOA

`0xb358e81b0f92698215bbe821b8c25986ad523a1b` has **0 bytes of runtime code**. It is not a Safe,
not a multisig, not a timelock — just an externally-owned key. Through it, one keypair can
`upgradeToAndCall` the implementation behind **all six proxies**, i.e. rewrite the logic that holds
$118K of user USDC locked on 3-year terms.

This is the top item to establish and, if confirmed, to report: an EOA upgrade root on a
long-lockup deposit protocol means a single compromised key (or the operator acting unilaterally)
can change the rules of funds that users cannot withdraw for three years. **No exploit is needed —
the authority is the design.** Severity is High on Impact × Likelihood: impact maximal, likelihood
depends on key hygiene which cannot be assessed from outside.

**To confirm before reporting:** is the proxy admin also the `UPGRADER_ROLE` holder and the
`DEFAULT_ADMIN_ROLE` holder? Is any timelock present anywhere? Was the admin rotated during the
45 days? Report as a finding with the exact storage slot evidence.

## 5. Assumptions to test

1. Total claimable (principal + accrued interest) never exceeds real assets under management.
2. Accrued interest reflects *actually realised* returns, not a booked rate. The constants
   (`SIMPLE_ANNUAL_RATE_BPS`, `_TURBO`) are compile-time; `accrueInterest` is operator-driven —
   is interest booked as a liability before the return exists?
3. `earlyExit` never pays more than pro-rata minus the stated penalty, and cannot be used to exit a
   losing position for free.
4. The deposit lifecycle flags (matured / dormant / abandoned / liquidated) are mutually exclusive
   and each is reachable exactly once; a double-settle or a settle-after-liquidate would be value
   extraction.
5. `dePegGuard`/`pegOk` actually gate deposits and exits while USDC is off-peg; `setPegOk` is
   privileged and cannot be used to bypass.
6. The BPS splits sum to ≤ 100% and the sum cannot be changed to over-allocate by `PARAMETER_ROLE`.
7. Wiring setters cannot repoint the money path at an attacker contract mid-flight, and cannot be
   used retroactively on existing deposits.
8. `SafeVault.treasury() = 0` is benign, not a mis-wired destination that reverts or sends funds
   into a void.

## 6. Accepted risks (design, not bugs — state in any report)

- 3-year lockup; early exit penalised by design.
- Centralised role set (9 roles) and operator-driven interest; no on-chain source of yield.
- Upgradeable logic (6 proxies).
- `deployer` freeze power exists until renounced.

## 7. Next steps (in order)

1. Confirm RISK #1 — role holders for `UPGRADER_ROLE`/`DEFAULT_ADMIN_ROLE`, any timelock, admin history.
2. Read `GilderSystem.sol` + `GilderAccessControl.sol` (the shared core) and `GilderProxy.sol`.
3. Section-by-section, one at a time, per `AUDIT_PROTOCOL.md`: deposit lifecycle, interest engine,
   BPS split, depeg guard, wiring.
4. Mandatory fork-attack phase (anvil on Base) before any clean verdict.
5. Second pass with different angles + the 3 gap-hunter passes.

## Honest limits

- I have not read the code yet (protocol: TMAAR precedes code).
- Total deposits / real TVL not yet measured on-chain — DefiLlama's $118K is the only figure so far.
- The `BondContract` ABI declares role constants; the earlier role-member probe failed because the
  getters differ from OZ's `getRoleMemberCount`. Role membership is still **unverified**.
