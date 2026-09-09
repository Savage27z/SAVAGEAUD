# TMAAR — Run Money (ClubPool, Base)

## Actors & Trust Levels

| Actor | Trust Level | What They Can Do | What Happens If Compromised |
|-------|-------------|-------------------|------------------------------|
| Owner (`owner` state var, set at deploy) | High | `setMembershipFee`, `setReporter`, `ownerUnstake` (force-unstake any athlete, funds go to the athlete not owner), `burn` (burn a membership NFT), `withdrawMembershipFees` | Can change fees, add malicious reporters, forcibly kick athletes out of positions, and — see O1 below — can skim yield that hasn't yet been formally allocated as epoch bonus |
| Reporter (`reporters` mapping, owner-appointed) | High (must be honest — this is the off-chain Strava-verification bridge) | `recordActivity()` — the only way compliance gets recorded on-chain | A malicious/compromised reporter can mark anyone compliant/non-compliant arbitrarily — no on-chain check against real Strava data (trusted oracle by design) |
| Athletes (any depositor) | None (but see F01) | `mint`, `stake`, `unstake`, `claimBonus` | Can attack the bonus-distribution mechanism against OTHER athletes — see F01, no elevated privilege required |
| Aave V3 Pool (external dependency) | High (must behave correctly) | Custodies all staked USDC/WETH, generates yield | If Aave is paused/exploited/insolvent, ClubPool inherits that risk entirely — no fallback |
| Anyone (public) | None | `endEpoch()` is permissionless | Can be called by anyone once `epochDuration` elapses — fine, no abuse found calling it early/reentrantly (guarded by the timestamp check; calling it exactly at the boundary doesn't appear exploitable) |

## Key Assumptions

1. **The reporter tells the truth about athletes' real-world running activity.**
   - *What if it fails?* Entirely off-chain trust — no on-chain check possible against Strava
     data. Accepted risk, not a contract bug (this is the whole point of a "reporter" oracle
     role) — but worth noting there's only one role, no dispute mechanism, no multi-reporter
     quorum.
2. **An athlete's recorded stake at the moment `recordActivity` marks them compliant fairly
   represents their real participation for that epoch.**
   - *What if it fails?* **This is F01.** Stake is freely mutable right up to and immediately
     after the snapshot instant, with no lockup, no minimum holding period, and no re-validation
     — confirmed false. This assumption is the direct root cause of F01.
3. **Aave V3 `supply()`/`withdraw()` round-trip within a short window (even the same
   transaction) without penalty or restriction.** Standard Aave V3 behavior, not gated by any
   cooldown — this is what makes F01 practically free to execute (any capital source works,
   doesn't strictly need to be a flash loan since there's no same-block requirement given
   7-day epochs).
4. **`endEpoch()` being permissionless is safe.** Reviewed — looks fine; nothing exploitable
   found in calling it early (blocked by the timestamp `require`) or in rapid succession (each
   call only processes yield accrued since the last checkpoint, via `unclaimedUsdcYield`/
   `unclaimedEthYield` tracking).

## Accepted Risks

1. **Reporter is a single trusted role with no on-chain verification of underlying Strava
   data.** This is the protocol's entire premise (bridging real-world fitness data on-chain) —
   not a bug, an inherent design tradeoff. Worth noting there's no visible dispute/appeal path
   for an athlete wrongly marked non-compliant.
2. **Owner is a single EOA with broad admin power** (fee changes, reporter appointment, forced
   unstake, membership burn). Standard early-stage centralization, not itself reportable per
   RULES.md #6 — *except* see O1 below, which is closer to a genuine trust-minimization gap
   given the "yield redistributed to compliant members" marketing claim.

## Observations (not findings — informational)

- **O1 — `withdrawMembershipFees()` can pull yield that hasn't been formally allocated as epoch
  bonus yet.** `withdrawableAmount = aWETH.balanceOf(address(this)) - totalWethBonus` (L322).
  `totalWethBonus` only increases inside `endEpoch()`. If the owner calls
  `withdrawMembershipFees` *before* calling `endEpoch()` (or simply never calls `endEpoch()` as
  often as WETH yield accrues), any yield sitting in the Aave position that hasn't yet been
  checkpointed as bonus is indistinguishable from "membership fee revenue" and can be withdrawn
  by the owner. This blurs the line between "club revenue" and "yield owed to compliant
  athletes" — worth pointing out to the team even though it requires owner-level trust already
  assumed elsewhere (RULES.md #6 gray area: it does contradict the stated "consistency is
  rewarded" redistribution promise, just via omission rather than an exploit).
- **O2 — Zero-compliance epochs permanently strand that epoch's yield.** If
  `compliantAthleteCount == 0` for an ended epoch, that epoch's `usdcBonus`/`ethBonus`
  allocation becomes practically unclaimable (nobody satisfies `claimBonus`'s compliance
  check), and it's absorbed into the running `unclaimedUsdcYield`/`unclaimedEthYield`
  checkpoint rather than rolled into the next epoch's pool. Dead-weight funds, not a fund-loss
  exploit — Informational.
- **O3 — Bare `receive() external payable {}` (L344) with no accounting.** Anyone sending ETH
  directly (not via `mint()`) has it silently absorbed with no corresponding state update and no
  function that ever spends raw `address(this).balance` — permanently stuck if it ever happens.
  Self-inflicted, Informational.
- **O4 — `ownerUnstake()` sends funds to the athlete, not the owner** — reviewed specifically
  because "owner can unstake anyone" sounds alarming; it's actually a forced-withdrawal-to-owner
  *of the athlete's own funds, to the athlete*, not a theft path. Not a finding.

## Attack Surface Summary

- **Primary trust assumption to attack:** the instantaneous, unprotected stake snapshot in
  `recordActivity()` — F01.
- **Most powerful attacker:** any athlete, no elevated role needed — this is what makes F01
  worth prioritizing over the admin-centralization observations (O1/O2), which need an
  already-trusted party to matter.
- **Can the protocol survive if F01 is exploited repeatedly, epoch after epoch?** No — every
  epoch's bonus pool is fully capturable this way by a single sufficiently-capitalized attacker,
  at the expense of every genuinely-compliant athlete. Doesn't threaten user principal (staked
  USDC itself is never at risk — Aave-custodied, always fully withdrawable), only the yield
  redistribution mechanism, which is the entire product.
