# TMAAR — Moocon (No-Loss Lottery, Solana / Jupiter Lend)

Filled out from Phase 0 recon (RECON.md) before any control-flow-level code read — full source
isn't public, so this is built from binary string extraction + direct account reads, not a
source read. Flagged where that limits confidence.

## Actors & Trust Levels

| Actor | Trust Level | What They Can Do | What Happens If Compromised |
|-------|-------------|-------------------|------------------------------|
| Upgrade authority (`JsvR5eLkPzfJ3TqiumoowRTco1m5qf21V5NCWn9H5UR`) | **High** | Redeploy the entire program at will (no timelock observed). Confirmed on-chain to also be recorded directly on the reward/commitment account (`authority` field). | Total: can rewrite reveal/consume-randomness/withdraw logic, redirect funds, change any rule |
| Keeper bot (`H9Q6c1RYvoQ64QdQcbnQJFrTEsdH3ojR4jvMxTQFm83L`) | **High for round integrity** | Sole observed signer for `Reveal` / `ProcessUndelegation` / `Commit` — runs the entire reveal→undelegate→commit cycle every round, ~every 35-55 min | If compromised or just self-interested: could selectively delay/skip unfavorable reveals (needs confirming no deadline/permissionless-fallback exists) |
| VRF authority (`SetVrfAuthority`-controlled) | **High (must be honest for "verifiable draw" to mean anything)** | Whoever holds this can be the source of round randomness | If it's admin-settable with no pinning/timelock, "verifiable" is marketing, not a property |
| Users (depositors) | None | Deposit SOL/JupUSD, withdraw principal, claim yield if winner | — |
| Jupiter Lend program (external CPI dependency) | High (must behave correctly) | Vault's yield source — all deposited principal is CPI'd into Jupiter's lending market | If Jupiter Lend is paused/exploited/insolvent, vault's underlying yield source breaks — moocon inherits Jupiter's risk surface entirely |
| MagicBlock Ephemeral Rollup validator/delegation program | High during delegation window | Executes state transitions on delegated reward-result accounts off the base chain, until `ProcessUndelegation`/`Commit` returns authority to Solana L1 | If the rollup validator misbehaves or the commit step doesn't fully re-validate the delta, state could be committed back incorrectly (balance/round inflation) |
| Depositors' merkle-proof ticket ranges (whoever builds the tree) | Unclear — likely admin/keeper-side, no on-chain evidence of permissionless verification against real deposit records | Determines which address "owns" which ticket range for winner-index matching | If the tree can be built/adjusted after the winning index is already fixed, direct winner-selection manipulation |

## Key Assumptions

1. **The keeper (`H9Q6...`) always reveals every round, honestly and promptly, regardless of
   outcome.**
   - *What if it fails?* No observed permissionless fallback/deadline-forfeiture instruction in
     the extracted instruction list — if true, a self-interested or compromised keeper can
     simply not submit `Reveal` for a round whose randomness doesn't favor them, indefinitely
     stalling that round with no recourse for depositors. Needs confirming: does `Reveal` have
     an enforced deadline after which ANYONE can call it (or claim a penalty), or is it
     forever gated to the keeper?
2. **VRF/randomness authority cannot be silently changed to something predictable.**
   - *What if it fails?* `SetVrfAuthority` exists as an admin instruction. If callable at any
     time with no pin/timelock, the "verifiable draw" claim is not backed by the actual trust
     model — confirmed the authority field on the reward account currently equals the upgrade
     authority itself (single EOA, both roles).
3. **The merkle root describing ticket ranges is locked before the winning index is knowable.**
   - *What if it fails?* Whoever submits/updates the root after the outcome is known can shape
     ranges so a chosen address's ticket covers the winning index — direct jackpot theft. Not
     yet confirmed either way; requires call-order-level logic, not just string extraction.
4. **Jupyter Lend CPI position accounting matches real vault claims (SyncRate / high-water
   mark).**
   - *What if it fails?* The 1061% APY currently advertised is either real yield or a symptom
     of a rate-sync/rounding bug. High-water-mark guard (`"Exchange rate dropped below the
     vault high-water mark"`) suggests some defense exists — direction/correctness not yet
     verified.
5. **MagicBlock delegation/undelegation cannot be interrupted or reordered by a third party
   mid-cycle.**
   - *What if it fails?* On-chain error `"Reward result delegation must immediately follow its
     commit"` suggests the devs already thought about this — a defensive check, tentatively
     good, but needs the actual enforcement path confirmed (does it revert, or just log?).

## Accepted Risks (self-declared by the protocol, inferred from architecture — not yet
confirmed against any published docs beyond the Twitter thread)

1. **Full reliance on Jupiter Lend as external yield source.** Not moocon's bug if Jupiter Lend
   itself fails — but moocon inherits that risk entirely and doesn't appear to say so
   explicitly anywhere public yet.
2. **Program is upgradeable with no observed timelock.** Standard early-stage-protocol risk;
   not itself reportable per RULES.md #6 unless it contradicts a specific trust-minimization
   claim (see "verifiable draw" gap above — that part IS worth writing up).

## Attack Surface Summary

- **Primary trust assumption to attack:** the keeper bot's honesty and promptness in the
  Reveal→Undelegate→Commit cycle, and whether the VRF/round authority is genuinely independent
  of the team's own upgrade key (it currently is not — same EOA appears on the commitment
  record).
- **Most powerful attacker:** the upgrade authority itself. It doesn't need to "hack" anything —
  it already holds the keys to both round-authority and the entire program's logic. The
  question worth chasing isn't "can an outsider break in" (classic exploit), it's "does the
  system actually deliver the 'no-loss, verifiable' guarantee it markets, or is that guarantee
  entirely dependent on one party's good behavior with zero on-chain enforcement" — a
  transparency/trust-minimization finding, same class as the Sherwood source-drift finding
  already in this repo.
- **Can the protocol survive if the upgrade authority / keeper key is compromised or turns
  malicious?** No — single point of failure for both code and round outcomes. This is worth
  stating plainly to the team as feedback even before any concrete exploit is proven, since it's
  the kind of thing a "reachable, small team" (RULES.md target filter) can often fix cheaply
  (multisig + pinned/timelocked VRF authority) once pointed out.

## TMAAR Quality Check

- [x] Every external dependency has an assumed trust level (Jupiter Lend, MagicBlock, keeper,
  upgrade authority)
- [x] Every "we assume X" has a "what if X fails?" answer
- [x] Owner/admin power enumerated — not just "can upgrade": confirmed via direct account read
  that the SAME EOA is both upgrade authority and (likely) the round `authority`/VRF role
- [x] Accepted risks explicit — inferred since no public docs exist beyond the Twitter thread;
  flagged as inferred, not confirmed, where relevant
- [ ] **Not yet confirmed:** exact field semantics of the 80-byte commitment account (which
  pubkey is literally `vrf_authority` vs. general `authority`) — next step is decoding against
  the account-name strings already extracted, or asking the team directly
