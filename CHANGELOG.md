# Changelog

## v1.6.0 (Jul 24, 2026)

- **Ravenhood (target #14)** — Full audit on Robinhood Chain: RVH token, RavenhoodVault, RVHStakingPool. Clean verdict.
- **8 observations documented** — Vault owner ≠ DAO wallet (two trust anchors), no on-chain buyback automation (off-chain only), `claimBurn()` no slippage protection, `emergencyRewardWithdraw()` centralization risk, RVH ownership renounced, staking pool unused at launch
- **On-chain verification** — Confirmed owner addresses, nftId (17757), total supply (100M), staking state (~0 staked), token name/symbol
- **CHECKLIST.md** — Ravenhood entry added with all 8 anti-patterns

## v1.5.1 (Jul 24, 2026)

- **MinePea deep second pass** — Focused re-read of all 5 contracts with different attack angles: re-entry trace through `quiverCallback`, TWAP economic bounds analysis (one-directional deviation check, `MIN_SQRT_PRICE+1`), feeCollector re-entry vector via raw `.call`, AutoMiner rounding dust trap, `_resolveTopMiner` gas bounds analysis
- **Finding #7 upgraded (Medium → High/Medium)** — Treasury buyback `sqrtPriceLimitX96 = MIN_SQRT_PRICE + 1` = no effective price cap; one-directional deviation check only blocks overpriced buys; at scale, manipulator can force buyback at inflated PEA price
- **Finding #5 analysis deepened** — `quiverCallback` lack of `nonReentrant` + `_safeTransferETH` raw `.call` to feeCollector = concrete re-entry vector, though current state ordering prevents exploitation
- **2 new findings added** (#11: feeCollector re-entry vector, #12: AutoMiner rounding dust trap)
- **CHECKLIST.md** — 3 new anti-patterns added: one-directional price deviation check, raw ETH `.call` in callbacks, prepaid rounding dust
- **FINDINGS.md** — MinePea row updated with 12 observations count

## v1.5.0 (Jul 24, 2026)

- **MinePea (target #13)** — Full audit of all 5 contracts (GridMining, PEAToken, Staking, AutoMiner, Treasury). Clean verdict.
- **Full combined stack applied** — TMAAR + Open-Kritt multi-agent hunting (6 perspectives across all 5 contracts) + BountyForge triage + deep dive on game theory
- **10 findings documented** — all low/medium design observations, no exploitable vulnerabilities
- **Cross-contract analysis** — first target with 5 interdependent contracts; verified CEI, reentrancy, and access control across the full system

## v1.4.0 (Jul 24, 2026)

- **Combined methodology enforced** — Every target now gets the FULL stack: Macro TMAAR + BountyForge triage + Open-Kritt hunting + EVM replay. No cherry-picking.
- **CLAUDE.md** — Updated with combined methodology table, TMAAR mandates, all 5 source methodologies listed
- **QUICKSTART.md** — Rewritten with Phase 0.5 TMAAR in the workflow table, Macro library reference for pre-audit research
- **RULES.md** — Expanded from 7 to 11 rules: TMAAR mandatory before code (Rule 8), Impact×Likelihood assessment (Rule 9), commit hash locking (Rule 10), check Macro library first (Rule 11)
- **FINDINGS.md** — Full rewrite with all 12 targets in a master table, methodology sources documented, clean process flow
- **.gitignore** — Added for Solidity/Foundry/Node/IDE artifacts
- **TARGETS/sentry** — Removed empty extra files (extra_0.sol, extra_1.sol)

- **Sentry Launch Factory (target #12)** — Full audit on Robinhood Chain. Clean verdict. TMAAR applied live (Macro-style). On-chain verification of owner, treasury, proxy admin.
- **TMAAR demonstrated in live audit** — Phase 0.5 applied to Sentry before code reading. Documented actors, trust levels, assumptions, and accepted risks.
- **Impact × Likelihood used during analysis** — No findings on Sentry, but the matrix is now baked into the triage process.
- **Macro methodology now operational** — Not just documentation. Every new target gets TMAAR + Impact×Likelihood + commit tracking applied during the audit.

## v1.2.0 (Jul 24, 2026)

- **Macro integration** — Studied 130+ Macro audit reports. Extracted and integrated their methodology into our repo
- **TMAAR** — New Phase 0.5: Trust Model, Assumptions & Accepted Risks. Mandatory before reading any code. Comes with template at `TEMPLATES/TMAAR.md`
- **Commit tracking** — Every target now records audited + final commit hashes and excluded components
- **Impact × Likelihood Matrix** — Every finding assessed on both axes, not severity alone. Added to finding triage (Gate 1)
- **Expanded severity tiers** — Moved to Macro's 7-tier system (Critical through Informational) with clear action items per tier
- **Updated finding template** — Added root cause classification, Addressed/Won't Do statuses, Impact×Likelihood table, team response field
- **Updated target summary template** — Added TMAAR section, commit tracking, exclusions, Phase 0.5 in passes table
- **CHECKLIST.md** — Added 4 new sections: Trust Model (TMAAR), Bridge/Cross-Chain, Signatures & EIP-712, plus Macro-sourced entries in the per-target table
- **Repo references** — Added Macro library and blog to METHODOLOGY.md references
- **Macro context** — Saved as persistent memory for future sessions

## v1.1.0 (Jul 24, 2026)

- **CLAUDE.md** — Project-level agent context file for instant bootstrapping
- **Unified TARGETS/** — All 12 targets now accessible under `TARGETS/` (symlinks for root-level dirs)
- **CHANGELOG.md** — Version tracking
- **FINDINGS.md** — Central findings index (empty — all targets clean so far)
- **Arcis README** — Added missing target documentation
- **Methodology** — BountyForge triage pipeline (4 gates), "What Changed" learning method, anti-pattern library
- **Finding template** — Reality/dedup checklists, impact tiers, quality gates
- **README** — Simplified structure, removed split-directory section

## v1.0.0 (Jul 22, 2026)

- Initial repo setup with METHODOLOGY.md, CHECKLIST.md, RULES.md, CHAIN_INFO.md
- TARGETS/ structure with first 4 targets (Quiver, SLVR, Index, Moonvault)
- Multi-pass methodology from solo-contract-hunting skill
- TEMPLATES/ with finding.md and target-summary.md
- Full cold-pickup documentation (QUICKSTART.md)
