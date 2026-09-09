# Finding F02 — Run Money (ClubPool)

## Reality Gate (Check before writing)

- [x] I have a concrete exploit path — not speculation
- [x] I can reproduce this on a fork or via on-chain call — reproduced on a Base fork against
  the real deployed contract
- [x] I have exact line numbers for the vulnerable code
- [x] I have tested the happy path AND the exploit path — **CONFIRMED**, two variants, both
  passing on a Base mainnet fork against the real deployed contract
- [x] This is not "owner can steal" (design choice) — the owner/reporter is doing exactly what
  they're supposed to (honestly recording a real compliance change); the bug corrupts shared
  accounting as a side effect, harming OTHER athletes who did nothing wrong
- [x] This is not "centralization risk" without exploitability
- [x] I've documented the trust model assumptions this finding relies on (see TMAAR.md)

## Title
`Arithmetic/Logic bug in recordActivity() subtracts an athlete's CURRENT stake instead of their frozen epoch snapshot, corrupting the shared bonus-pool denominator for every compliant athlete`

## Severity
Medium-High (no attacker or malicious intent required at all — this fires from completely
ordinary usage, and can zero out or underflow-revert the shared accounting for an entire
epoch, affecting every compliant athlete in it, not just one account)

## Impact × Likelihood

| Axis | Rating | Rationale |
|------|--------|-----------|
| **Impact** | High | Can brick `claimBonus` for every honest, compliant athlete in an epoch (Variant 1), or permanently and unremovably lock an athlete's compliance status for the rest of an epoch regardless of their real activity (Variant 2) — a correctness/availability failure of the core product feature, not a fringe edge case |
| **Likelihood** | High | Requires ZERO attacker intent. Fires from the single most ordinary sequence imaginable: an athlete increases their stake after being marked compliant (a totally natural thing to do — "I'm doing well this week, let me save more"), then is later marked non-compliant (a bad week, or a reporter correction). Over 93 historical epochs with real users, this exact sequence is plausible to have already occurred |

**Final severity: High** (High × High per the matrix in METHODOLOGY.md)

## Status
**Confirmed** — two variants reproduced end-to-end on a Base mainnet fork against the real,
live, deployed `ClubPool` contract.

## Root Cause Classification
- [x] Arithmetic / rounding (stale-value subtraction, underflow)
- [x] Logic / state machine

## Impact Litmus Test
> An attacker (or, notably, no attacker at all — an ordinary athlete doing something completely
> unremarkable) can **increase their own stake after being marked compliant, then later be
> marked non-compliant**, resulting in **`totalDepositByCompliant` being corrupted for the
> entire epoch — either driven low enough that every other compliant athlete's `claimBonus`
> call reverts (`"Total deposits by compliant athletes is zero"`), or driven low enough that
> the arithmetic underflows, permanently preventing the reporter from ever marking that athlete
> non-compliant again for the rest of the epoch.**

## Summary
`recordActivity()` reads an athlete's current stake ONCE at the top of the function and uses it
for two different purposes depending on which way compliance is changing. When marking someone
compliant, it correctly *freezes* that value into `epochAthleteStake[epoch][athlete]` for later
use. But when marking someone NON-compliant, it subtracts the same fresh, current-at-this-call
read — not the value that was actually frozen and added earlier. If the athlete's real stake
changed in between (which `stake()` freely allows, any time, no restriction), the subtraction no
longer matches what was added, corrupting the shared pool-wide total that every other compliant
athlete's bonus share depends on.

## Vulnerability Detail
- **File:** `src/ClubPool.sol`
- **Function:** `recordActivity()`
- **Lines:** L194-228, specifically the mismatch between L212/L215 (compliant branch, correct)
  and L221 (non-compliant branch, uses the wrong value)
- **Live contract:** `0x1089Db83561d4c9B68350E1c292279817AC6c8DA` (Base)

```solidity
function recordActivity(address athlete, bool compliant, uint256 epoch) external onlyOwnerOrReporter {
    require(epoch == currentEpoch, "Invalid epoch");

    uint256 stakeAmount = athletes[athlete].stakedAmount;   // <-- read ONCE, current value

    if (stakeAmount == 0) { return; }

    bool previousCompliance = epochAthleteCompliance[epoch][athlete];
    epochAthleteCompliance[epoch][athlete] = compliant;

    if (compliant && !previousCompliance) {
        epochs[epoch].compliantAthleteCount++;
        epochAthleteStake[epoch][athlete] = stakeAmount;               // L212: correctly FROZEN
        epochs[epoch].totalDepositByCompliant += stakeAmount;          // L215: correctly added
    } else if (!compliant && previousCompliance) {
        epochs[epoch].compliantAthleteCount--;
        epochs[epoch].totalDepositByCompliant -= stakeAmount;          // L221: BUG — should be
                                                                        //   epochAthleteStake[epoch][athlete],
                                                                        //   not the fresh `stakeAmount`
        epochAthleteStake[epoch][athlete] = 0;
    }

    emit ActivityRecorded(athlete, compliant, epoch);
}
```

**Root cause:** the developer correctly identified the need to freeze a snapshot for the ADD
case, but reused the same local `stakeAmount` variable for the REMOVE case instead of reading
back the actual frozen value (`epochAthleteStake[epoch][athlete]`) that was originally added.
Classic "used the wrong variable" bug — the fix is a one-line change.

**Consequence — two confirmed variants (see PoC):**
1. **Denominator zeroed / driven below the true sum of remaining compliant athletes' frozen
   stakes** → every remaining compliant athlete's `claimBonus()` call reverts at
   `require(totalDeposits > 0, ...)` (or, if not exactly zero but under-counted, silently
   inflates everyone's share past what the actual bonus pool can pay out, risking later
   claimants reverting on the balance check at L244-245, or in the worst case, `claimBonus`'s
   `aavePool.withdraw()` calls touching funds that should have remained backing other users'
   staked PRINCIPAL, not just yield).
2. **Underflow revert on `recordActivity` itself** → if the athlete's current stake exceeds what
   remains in `totalDepositByCompliant` at the moment of the non-compliant marking, the
   subtraction reverts outright (Solidity 0.8.x default). The reporter's transaction fails, and
   there is no other way in the contract to correct that athlete's compliance status for the
   rest of the epoch — they stay marked compliant, unremovably, regardless of subsequent real
   activity.

**Remediation:**
```diff
     } else if (!compliant && previousCompliance) {
         epochs[epoch].compliantAthleteCount--;
-        epochs[epoch].totalDepositByCompliant -= stakeAmount;
+        epochs[epoch].totalDepositByCompliant -= epochAthleteStake[epoch][athlete];
         epochAthleteStake[epoch][athlete] = 0;
     }
```
Subtract the value that was actually added (the frozen snapshot), not the athlete's current
live balance. This one-line fix makes the invariant `totalDepositByCompliant == sum(
epochAthleteStake[epoch][athlete] for all currently-compliant athletes)` hold correctly in both
directions.

## Proof of Concept
**Run and passing**, both variants. File:
`TARGETS/run-money/fork-test/test/F02_StaleStakeUnderflow.t.sol`. Forks Base mainnet, interacts
with the real deployed `ClubPool` — no redeployment, no source modification.

**Variant 1 — bricks an honest athlete's bonus claim:**
```
[PASS] test_F02_HonestAthleteBBonusBricked() (gas: 716128)
Logs:
  CONFIRMED: an honest, still-compliant athlete's claimBonus is bricked
  solely because a DIFFERENT athlete increased their own stake mid-epoch.
```
Athlete A and B both stake 1,000 USDC and are marked compliant (total = 2,000). A stakes another
1,000 (now 2,000 real). A is later marked non-compliant — the call subtracts A's *current*
2,000 from the pool total (which was only 2,000 total across BOTH athletes), driving it to
exactly 0. B, who never touched their stake and is still marked compliant, then calls
`claimBonus` and the transaction **reverts** with `"Total deposits by compliant athletes is
zero"`.

**Variant 2 — permanently locks compliance status:**
```
[PASS] test_F02_RecordActivityRevertsLockingComplianceOn() (gas: 336274)
Logs:
  CONFIRMED: recordActivity(athleteA, false, epoch) reverts.
  The reporter can NEVER mark athleteA non-compliant again this epoch -
  athleteA is permanently 'compliant' regardless of real behavior, just
  by having staked more than their originally-frozen amount.
```
Athlete A stakes 1,000, marked compliant (total = 1,000). A stakes another 1,000 (current =
2,000, exceeding the pool total). The reporter's attempt to mark A non-compliant reverts on
arithmetic underflow — A is stuck "compliant" for the rest of the epoch no matter what.

To reproduce:
```bash
cd TARGETS/run-money/fork-test
forge test --match-contract F02_StaleStakeUnderflow -vvv
```

## Dedup Check
- [ ] Solodit search for this bug class — not yet done
- [x] No GitHub repo to check (`github.com/Run-Money` 404s)
- [x] No Basescan-visible prior audit or known-issues page
- [x] No prior disclosure found in this repo

## Recommendation
See the one-line diff above. Additionally worth considering: should staking MORE after being
marked compliant even be allowed to silently diverge from the frozen snapshot, or should
`stake()` itself reject/adjust when the caller already has a frozen `epochAthleteStake` entry
for the current epoch? The minimal fix (subtract the frozen value) resolves both confirmed
variants without needing behavioral changes to `stake()`/`unstake()`.

## Team Response
Not yet disclosed — see target `README.md` for team-status context (likely dormant; real
disclosure channel found: `info@runmoney.app`).

## References
- Same root class as F01 (`epochAthleteStake` snapshot handling) — worth disclosing together as
  one report covering `recordActivity()`'s snapshot logic end to end, since both findings live
  in the same ~30 lines of code
- `CHECKLIST.md` → Math & Accounting / Share ratio manipulation
