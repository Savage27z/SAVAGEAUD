# Finding F01 — Run Money (ClubPool)

## Reality Gate (Check before writing)

- [x] I have a concrete exploit path — not speculation
- [x] I can reproduce this on a fork or via on-chain call — Base fork, straightforward: stake → wait for a `recordActivity(compliant=true)` call (or, for a fork PoC, call it directly since `onlyOwnerOrReporter` can be satisfied by pranking the known reporter/owner) → unstake → claimBonus after `endEpoch()`
- [x] I have exact line numbers for the vulnerable code
- [x] I have tested the happy path AND the exploit path — **CONFIRMED on a Base mainnet fork
  against the real deployed contract** (Foundry, `vm.createSelectFork`, block 51065902). See
  Proof of Concept below for the actual run and output.
- [x] This is not "owner can steal" (design choice) — this is exploitable by ANY athlete against
  OTHER athletes' bonus share, no elevated privilege needed by the attacker
- [x] This is not "centralization risk" without exploitability
- [x] I've documented the trust model assumptions this finding relies on (see TMAAR.md)

## Title
`Logic/State-Machine bug in recordActivity()/claimBonus() allows an athlete to inflate their bonus-pool share via a temporary stake, with no lockup or snapshot protection`

## Severity
Medium (current TVL is small — ~$3K — but the bug class is a direct value-transfer between users at any TVL, and this contract has been live for 93 weekly epochs already)

## Impact × Likelihood

| Axis | Rating | Rationale |
|------|--------|-----------|
| **Impact** | Medium (scales with TVL — currently caps around the size of one epoch's yield bonus, ~$3K TVL means each epoch's yield pool is small today, but the mechanism has no cap and would scale directly with TVL growth) | Directly steals value from other compliant athletes' rightful bonus share — not a "grief," a real transfer |
| **Likelihood** | High | No front-running, no MEV sophistication, no flash loan strictly required. Epochs are 7 days long (confirmed live: `epochDuration() = 604800`). Attacker just needs capital for however briefly it takes to get caught by one `recordActivity(true)` call, which given a full week window is trivial to time by simply watching the athlete's own on-chain compliance status (`getCurrentEpochComplianceStatus`) flip |

**Final severity: Medium** (High likelihood × Medium impact per the matrix in METHODOLOGY.md; would escalate to High if TVL grows materially, since nothing about the bug is TVL-capped)

## Status
**Confirmed** — reproduced end-to-end on a Base mainnet fork against the real, live, deployed
`ClubPool` contract (not a redeployed copy). RULES.md #2 satisfied.

## Root Cause Classification
- [x] Logic / state machine
- [x] Design / economic (no snapshot / no minimum holding period around a value-weighted distribution)

## Impact Litmus Test
> An attacker can **temporarily inflate `athletes[msg.sender].stakedAmount` right before a `recordActivity(..., true, ...)` call marks them compliant for the epoch, then immediately withdraw that capital**, resulting in **receiving a share of that epoch's entire USDC + WETH yield bonus pool proportional to the inflated (already-withdrawn) amount, diluting the rightful share of every other genuinely-staked compliant athlete for that epoch — with the inflated snapshot persisting for the rest of the epoch even after full withdrawal.**

## Summary
The contract redistributes each epoch's accrued Aave yield to "compliant" athletes (those who
met their running goal, attested by an off-chain reporter) in proportion to how much USDC they
had staked. The proportion is fixed the *instant* the reporter marks them compliant, reading
their **live, current** stake with no minimum holding period and no re-check afterward. Because
staking and unstaking are completely free and instant (no cooldown, no fee, and Aave V3 lets
you supply then withdraw within the same transaction), an athlete can stake a large amount right
before getting marked compliant, get a big frozen bonus-share number locked in, then take their
money straight back out — and keep collecting the oversized bonus share all epoch, since later
`recordActivity(true)` calls while already marked compliant are silently no-ops.

## Vulnerability Detail
- **File:** `src/ClubPool.sol`
- **Functions:** `recordActivity()`, `stake()`/`_stake()`, `unstake()`, `claimBonus()`
- **Lines:** `recordActivity` L194-228, `_stake` L133-149, `unstake` L151-168, `claimBonus`
  L230-258
- **Audited commit/source:** Verified source pulled directly from Basescan for
  `0x1089Db83561d4c9B68350E1c292279817AC6c8DA` (Base mainnet), compiler `v0.8.26+commit.8a97fa7a`,
  live-state-confirmed as of 2026-09-09 (`currentEpoch()` = 93, `epochDuration()` = 604,800s / 7
  days, `totalUsdcDeposited()` ≈ $2,088, `totalEthDeposited()` = 0.35 ETH — real, live, ongoing
  money, contract has been running for ~93 weekly cycles)

Walking the exact mechanism:

1. `recordActivity(athlete, true, epoch)` (L194) is called by the owner or an off-chain
   "reporter" role. When it flips an athlete from non-compliant to compliant (L207-215), it
   does two things: `epochAthleteStake[epoch][athlete] = stakeAmount` (a **snapshot of their
   CURRENT stake, read live from `athletes[athlete].stakedAmount` at L197**), and
   `epochs[epoch].totalDepositByCompliant += stakeAmount`.
2. **There is no delay, no minimum holding period, and no re-validation of that snapshot for
   the rest of the epoch.** If the athlete calls `unstake()` (L151) the very next block — or
   even the same block — nothing in `unstake()` touches `epochAthleteStake` or
   `totalDepositByCompliant`. The frozen numbers used for the bonus split stay exactly as they
   were at the moment of the `recordActivity` call.
3. **Crucially, subsequent `recordActivity(athlete, true, epoch)` calls while already compliant
   are no-ops** (L207: `if (compliant && !previousCompliance)` — guarded on the FALSE→TRUE
   transition only). So even if the reporter calls this multiple times over the week (plausible,
   since it's presumably driven by periodic Strava syncs), the inflated snapshot from the FIRST
   compliant marking survives untouched unless the reporter explicitly flips them back to
   non-compliant and then compliant again — which requires the reporter to actively notice and
   intervene, and there's no code-level mechanism forcing that.
4. At `claimBonus(epoch)` (L230), the payout is
   `usdcBonusAmount = epochData.usdcBonus * epochAthleteStake[epoch][msg.sender] /
   epochData.totalDepositByCompliant` (L240) — using the stale, inflated, already-withdrawn
   snapshot as the numerator. The attacker collects a bonus share as if their capital had been
   staked the whole epoch, when in reality it was only present for however long it took to get
   caught by one `recordActivity` call.

**Root cause:** the bonus-distribution weight (`epochAthleteStake`) is derived from a live,
freely-mutable balance at a single unprotected instant, with no snapshot-timing protection (no
minimum stake duration, no average/time-weighted balance, no re-validation before the epoch
closes).

**Consequence:** value transfer from genuinely-staked, genuinely-compliant athletes to anyone
willing to temporarily park capital in the contract around a compliance check. Directly
contradicts the "consistency with higher returns" framing in the protocol's own marketing — the
person actually being consistent gets diluted by someone gaming a single snapshot.

**Remediation options (pick one, roughly in order of robustness vs. complexity):**
1. **Time-weighted average stake** over the epoch (or since `joinedAt`/last stake-change),
   rather than an instantaneous snapshot at compliance-marking time.
2. **Lock staked funds for compliant athletes until `claimBonus` for that epoch** — i.e.,
   `unstake()` should check `epochAthleteCompliance[currentEpoch][msg.sender]` and either block
   withdrawal of the frozen portion or re-decrement `epochAthleteStake`/`totalDepositByCompliant`
   proportionally on any withdrawal that happens after the compliant-snapshot, for the rest of
   that epoch.
3. **Minimum holding period** before a stake counts toward a compliance snapshot (e.g., stake
   must have been in place for N days / since before the epoch started) — simplest fix, doesn't
   require re-architecting the accounting, but is a policy choice rather than removing the class
   of bug entirely.

## Proof of Concept
**Run and passing.** Full Foundry project at `TARGETS/run-money/fork-test/` in this repo
(`test/F01_FlashStakeBonusInflation.t.sol`, interface at `src/IClubPoolMin.sol`). Forks Base
mainnet (`vm.createSelectFork`) and interacts with the real, live, deployed `ClubPool` at
`0x1089Db83561d4c9B68350E1c292279817AC6c8DA` — no redeployment, no source modification.

Scenario: `victim` stakes 1,000 USDC and holds it for the entire epoch (genuine participation,
marked compliant honestly). `attacker` stakes only 10 USDC genuinely, but inflates to 100,010
USDC (a further 100,000 USDC deposit) immediately before `recordActivity(attacker, true, epoch)`
is called (pranked as the real on-chain `owner()`, who is a valid caller per
`onlyOwnerOrReporter`), then calls `unstake(100_000e6)` immediately afterward to withdraw the
inflated capital back out. A later `recordActivity(attacker, true, epoch)` re-confirmation
(simulating a subsequent Strava sync mid-epoch) is shown to be a silent no-op that does not
refresh the stale snapshot. Time is then warped to the real `epochDuration` (7 days) so real
Aave yield accrues, `endEpoch()` is called (permissionless), and both athletes call
`claimBonus()`.

```
[PASS] test_F01_AttackerInflatesShareThenWithdraws() (gas: 1715735)
Logs:
  Attacker's frozen epochAthleteStake right after recordActivity: 100010000000
  Attacker's REAL stake after withdrawing: 10000000
  Victim (1,000 USDC staked the WHOLE epoch) received bonus: 16693
  Attacker (10 USDC real stake, 100,010 USDC for ~0 blocks) received bonus: 1669500
  Attacker's share of the bonus pool (bps): 9901
  Attacker's share of FROZEN WEIGHT (bps), for reference: 9900

Suite result: ok. 1 passed; 0 failed; 0 skipped
```

**The attacker — who held real capital in the pool for effectively zero duration — walked away
with ~100x the victim's bonus, despite the victim staking 100x more real capital for the entire
epoch.** The attacker's payout share (99.01%) tracks their frozen snapshot weight (99.00%)
almost exactly, confirming the payout is driven purely by the stale snapshot with no regard for
actual holding duration.

To reproduce:
```bash
cd TARGETS/run-money/fork-test
forge test --match-contract F01_FlashStakeBonusInflation -vvv
```

## Dedup Check
- [ ] Solodit search for this bug class (snapshot-timing / flash-stake governance-style dilution)
  on similar "stake-weighted yield redistribution" contracts — not yet done
- [x] Checked target's GitHub — org `github.com/Run-Money` currently 404s / not found publicly,
  no changelog to check
- [x] No Basescan-visible prior audit or "known issues" page for this contract
- [x] No prior disclosure found in this repo

## Recommendation
```diff
  function recordActivity(address athlete, bool compliant, uint256 epoch) external onlyOwnerOrReporter {
      require(epoch == currentEpoch, "Invalid epoch");

      uint256 stakeAmount = athletes[athlete].stakedAmount;
+     // e.g. option 3 (simplest): require the stake to have been in place before the epoch
+     // started, so a same-epoch stake can never count toward that epoch's snapshot.
+     require(athletes[athlete].joinedAt <= currentEpochStartTime || <stake predates epoch>, "Stake too recent for this epoch's bonus");
      ...
```
Or, more robustly, make `unstake()` aware of an active compliant snapshot for the current epoch
and decrement `epochAthleteStake[epoch][msg.sender]` / `epochs[epoch].totalDepositByCompliant`
by the withdrawn amount at withdrawal time, so the frozen number can never exceed what's
actually still staked.

## Team Response
Not yet disclosed — flagging for 𝖲𝖠𝖵𝖠𝖦𝖤 to verify on a fork before any outreach, per RULES.md
#2 and #5.

## References
- `CHECKLIST.md` → Math & Accounting / Share ratio manipulation
- Conceptually related to flash-loan/flash-stake governance-snapshot manipulation bugs (a
  well-documented DeFi bug class — same root cause: using an instantaneous, freely-mutable
  balance as a weight with no time-lock or averaging)
