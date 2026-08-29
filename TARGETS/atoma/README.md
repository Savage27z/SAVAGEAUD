# ATOMA — AtomaVault (Arbitrum One)

**Status:** 🟡 Informational — clean of critical/high, 7 observations, no reportable exploit found
**Date:** 2026-08-05
**Source:** Blockscout-verified (impl `0x9521b08303ae010e85e24fc15d5334a0e506641e`, proxy `0xCC56410e1a136aF0eCEb7241c6aE394F4d8b581c`)
**Repo:** github.com/tony-crypt0/atoma-vault (⚠️ stale — deployed is V2/V3 hardened, repo is V1)

## What it is
USDC ERC-4626 vault that captures perp funding-rate spreads: opens long on Nado, short on Extended, pays the spread into NAV hourly. Operator pushes NAV on-chain; users deposit/request/claim around weekly epochs.

## Live state (on-chain, 2026-08-05)
- totalAssets: $64.7K | on-chain USDC balance: **$628.50** (99% of assets custodied off-chain at perp venues)
- totalSupply: 59.4M shares (12dp) | NAV ≈ 1.0917e12 (≈ HWM 1.0917 — one crystallization already done)
- currentEpoch: 438 | epochDuration: 7 days (was 1h at genesis)
- maxTotalAssets: $100K cap | maxUpdateDeltaBps: 200 (2%) | minUpdateInterval: 30 min
- settledUnclaimedAssets: $509.75 (settled-but-unclaimed liabilities)
- owner: **SafeProxy multisig** `0x0429...540b3` (contract) ✅
- operator: **single EOA** `0xc367...613b` ⚠️ — controls NAV pushes, epoch settlement, fee crystallization, pause

## TMAAR (Trust Model)
- **Owner** (Safe multisig): can upgrade (UUPS), capitalWithdraw (whitelisted destinations, 24h delay), resyncTotalAssets (paused only), set bounds/caps/epoch duration, setOperator. Trusted.
- **Operator** (single EOA): pushes NAV ±2%/30min, settles epochs, crystallizes 20% perf fee, pauses. **Single point of failure** — controls the share price the whole protocol runs on.
- **Users**: deposit → shares; requestWithdrawal (next epoch settle) → claim (0.5% fee). Shares non-transferable.
- **Assumptions**: operator reports honest NAV; perp venues (Nado/Extended) don't lose funds; owner returns capital in time for claims.
- **Accepted risks (documented in code)**: off-chain custody — owner MUST be able to move assets; no trustless variant.

## Observations (in priority order)

- **🟡 O1 — capitalWithdraw reserves settled liabilities only, NOT requested-but-unsettled.** `settledUnclaimedAssets` guard leaves pending withdrawal requests unbacked. Owner (Safe) can withdraw capital backing users who already requested, and their claims revert `InsufficientIdle` until capital returns. No deadline forces return. Mitigated by 24h whitelist delay + multisig, but the reserve gap is a real seam between "requested" and "settled" states.

- **🟡 O2 — Settlement price is settle-time NAV, not epoch-end NAV.** `settleEpoch` uses `totalAssets()` at call time; operator picks WHEN to settle (any time after epoch ends) and can grind NAV ±2%/30min before settling. Exit price for withdrawers is operator-controlled within the window. Inherent to design, but the "epoch lock" promise is weaker than it reads.

- **🟡 O3 — Operator is a single EOA on the NAV/fee/settle path.** Key compromise → attacker can grind NAV up (2% × 48/day ≈ 2.6x in 24h), crystallize 20% fee shares on fake profit, then claim whatever on-chain USDC sits in the vault. On-chain balance is small today, but grows with deposits. Centralization risk, not an exploit — operator is trusted by design.

- **🟡 O4 — NAV bound is 2% (code) not 0.2% (README).** `DEFAULT_MAX_UPDATE_DELTA_BPS = 200` = 2%. Doc mismatch; bound is per-update, compounds without cumulative limit. Operator can reach arbitrary NAV over days.

- **🟡 O5 — depositEpoch not updated on third-party deposits to existing holders.** `if (receiver == msg.sender || balanceOf(receiver) == shares)` — a deposit to an address that already holds shares (by another caller) leaves `depositEpoch` stale → receiver can `requestWithdrawal` in the same epoch (lock bypass). Impact: exit one epoch earlier than intended. Low.

- **🟡 O6 — Claims gated on on-chain balance.** `claimWithdrawal` requires `token.balanceOf(this) >= assets`. With $628 on-chain vs $64.7K totalAssets, large claims revert until owner deposits capital back. Liveness depends on owner action; claims "persist indefinitely" but can be unpayable indefinitely.

- **🟢 O7 — Rounding dust.** `settledUnclaimedAssets` records floor of the sum; per-user claims floor individually → residual dust permanently locked in the reserve, slightly deflating `totalAssets()`. Negligible.

## What I checked (clean)
- settleEpoch fee math: fee charged ONLY on withdrawing shares' profit; remaining holders NOT diluted (traced with values — correct)
- crystallizePerformanceFee formula (standard HWM dilution): correct
- Reentrancy: CEI respected on claim (state zeroed before transfer); USDC no hooks
- `_update` transfer restriction: shares non-transferable except mint/burn/vault — no share-gaming
- Cap, MIN_DEPOSIT, epoch schedule edge cases: guarded
- Proxy: UUPS, `_authorizeUpgrade` onlyOwner (Safe); impl verified; deployed code is HARDENED vs repo (opposite of drift trap)
- On-chain admin: owner = SafeProxy ✅, operator = EOA ⚠️

## Verdict
No third-party-exploitable critical/high. The protocol is honest about its trust model (off-chain custody explicitly ACCEPTED in code comments). The interesting findings for disclosure are O1 (reserve gap) and O3 (single-key operator) — both design/centralization, likely "won't fix / acknowledged" but worth sending if the team wants a relationship. Per 4-gate triage: none pass Gate 1 (reality check) as funds-loss exploits.
