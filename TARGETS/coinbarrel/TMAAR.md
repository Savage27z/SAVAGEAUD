# TMAAR — Coinbarrel Hook V5 (Robinhood Chain)

Phase 0.5, filled **before** code read. All on-chain facts verified 2026-09-03 (block 53,635,088) unless marked [docs claim].

## Actors & Trust Levels

| Actor | Trust Level | What They Can Do | What Happens If Compromised |
|-------|-------------|------------------|------------------------------|
| **Proxy owner EOA** `0x30e4b6dc…ddba` | **High (single point)** | UUPS-upgrade ALL six proxies (launcher, vault, hook, fee router, stock registry, impairment controller); Ownable2Step owner of each; plus operating roles | **Total compromise**: can swap any application logic — fee accounting, hook swap/fee logic (until terminal handoff), impairment state, launch policy. Docs admit one EOA held all roles at deployment. NOT a multisig (no code at address). |
| Launcher owner | High (subset) | Launch config + launcher upgrades | Can change launch policy/finalization behavior for future launches |
| Hook owner | High (until terminal handoff) | Swap hook implementation (fee/swap logic), exemption administration, per-pool LP-fee controls | Can rewrite fee logic of live V5 pools; can add exemptions |
| Fee-router owner | High | Fee-accounting upgrades | Can change fee distribution accounting (impl upgraded Aug 30, docs stale) |
| Impairment owner/admin | Medium | Mark assets impaired → hook fails closed during swaps [docs claim] | Can freeze trading of chosen assets (grief/DoS), cannot move LP principal [docs claim — verify] |
| Stock-registry owner | Medium | Publish stock/route entries | Can list bad routes/assets (if any stock-launch path uses them) |
| Revenue controllers | Medium | Rotate permitted future revenue destinations | Can redirect fee revenue streams |
| Treasury recipients | None | Receive value only | — |
| Creators (Advanced mode) | Medium | Configure fee/allocation/quote/reward/collection controls at launch; creator fee share (70% legacy proportional / per-pool pinning) | Can rug their own launch's holders (creator risk, not protocol risk); verify post-launch change powers |
| Traders / LP holders | None | Trade via Universal Router/Permit2; hold LP claims through permanent custody | — |
| Automation operators | Low | Submit processing work | No entitlement ownership [docs claim] |

## Key Assumptions

1. **Single EOA key `0x30e4b6dc…` is not compromised** — it is the upgrade authority over all six application proxies.
   - *What if it fails?* — Attacker swaps any/all implementations. Fee router → redirect fees; hook → rewrite swap/fee logic of all V5 pools; launcher → change future launch policy. LP principal in permanent custody is the backstop (if the custody contract truly has no escape, the attacker can't take principal, only fees/logic — magnitude depends on fee volume ~$124K/30d).
2. **Terminal Hook V5 handoff eventually executes and permanently strips implementation-replacement** [docs claim].
   - *What if it fails or is delayed?* — Hook remains upgradeable indefinitely; hook compromise = fee-logic swap across every V5 pool.
3. **Permanent custody contract has no transfer/approve/withdraw path** [docs claim].
   - *What if it fails?* — LP principal drainable; would be THE critical finding.
4. **Fee/accounting state is consistent across launcher → vault → hook → fee router → escrow → payout/reinvest/burn executors** (P2: two sources of truth).
   - *What if it fails?* — fee divergence: accrued vs claimed vs paid; reward escrow shortfalls; cross-generation legacy path inconsistencies.
5. **Fee models pinned per pool at registration** (flat 1% vs proportional 30/70) — no repricing of old pools.
   - *What if it fails?* — retroactive repricing or mis-pinning → fee theft/grief.
6. **Docs ↔ on-chain alignment** — currently FALSE for feeRouter + impairmentController (upgraded Aug 30; docs stale). Every doc-based assumption about those two impls must be re-verified on-chain.
   - *What if it fails?* — reviewing stale docs = reviewing code that isn't deployed.

## Accepted Risks

1. **Upgradeability before terminal handoff** — hook (and all other proxies) are upgradeable by the single EOA today. Docs describe this as transitional with a planned handoff. *Mitigation:* permanent custody of principal is claimed to bound the damage.
2. **Creator risk** — Advanced launches expose fee/allocation/reward controls to creators; buyers accept creator-trust (launchpad standard). Stock/ETF/bond launches via registry entries add registry-trust.
3. **Closed source** — implementations unverified on explorers; review depends on team-provided source. *Mitigation:* request source; verify deployment hashes match registry.

## Attack Surface Summary

- **Primary trust assumption to attack:** single EOA upgrade authority over six proxies + pre-handoff upgradeable hook. Test: what can each owner do TODAY, and what survives the handoff?
- **Most powerful attacker:** compromised `0x30e4b6dc…` key, or malicious team (same thing pre-handoff).
- **Can the protocol survive if the EOA key fails?** Partially — principal custody is the designed backstop; fee/reward/logic state would be attacker-controlled until handoff/rotation. If custody has any escape, NOT survivable.
- **Non-key attack surface (no key compromise needed):** fee-accounting divergence (P2), launch-protection/cap bypass (P3), default-state authz (P1), ERC-404 mechanics, legacy V1–V3 path inconsistencies, creator-configurable param abuse, impairment fail-closed logic, per-pool fee pinning edge cases.
- **Watch item:** launcher was upgraded TODAY (Sep 3 04:20 UTC) to the docs-listed impl; feeRouter/impairment impls are 4 days old and undocumented — get those exact diffs from the team.
