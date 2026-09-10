# Changelog

## v1.13.2 (Sep 10, 2026)

- **death.fun F01 — CORRECTION: "the backend submits" never closed the reachability gap.**
  Independently re-derived from the contract source (not just agreed with the prior "Low"
  re-rating): `increaseBet`'s only caller check is `msg.sender == game.player`, satisfiable by the
  player's own wallet with zero session-key involvement. Once any `increaseBet` tx is mined —
  regardless of who submitted it — its calldata (incl. `serverSignature`) is permanently public.
  So the "backend submits the first call" finding (correct, per F07/F08's independent client-flow
  and live-capture work) only explains how a player's *first* signature gets minted, not whether
  they can reuse it. Any of the 554 players who got one legitimate `increaseBet` during the live
  window (2026-03-11 → 2026-04-12) had a ~15-minute, fully self-service replay path via their own
  wallet. Re-rated: **Low today (feature is genuinely dormant, confirmed independently), High the
  moment it's reactivated** — not a flat Low. Full mechanism in the finding's new CORRECTION
  section.
- **death.fun — skull-before-click, independently re-verified with a live predictive PoC.** Read
  the client-shipped `getDeathTileIndex(seed, row, tiles) = sha256(seed+"-row"+row).slice(0,8) %
  tiles` algorithm directly from the production bundle, pulled a live demo-mode seed out of React
  props mid-game, and predicted two rows' death-tile positions **before playing them** — both
  landed exactly right. Confirms demo mode is trivially exploitable this way (harmless: seed is
  client-self-generated, no stakes). Then re-ran the same check against a real, funded, live game:
  `gameSeed` stayed `null` and every unplayed row's `deathTileIndex` stayed `null` throughout —
  confirms real-money mode is clean, corroborating F03/F07/F08's independent (and more extensive)
  work reaching the same conclusion.
- **death.fun — live adversarial sweep against the real API (funded account), Death Race only.**
  Concurrent double-submit race on `select-tile`: cleanly serialized, no double-credit. Cash-out on
  a resolved game: rejected both by version mismatch and by state check (layered). IDOR on
  `/api/games/history?walletAddress=`: another wallet's address correctly 401s. Username field:
  rejects anything outside `[A-Za-z0-9_-]`. `rowConfig` bounds at game creation: 2-7 tiles/row, 25
  rows exactly, minimum 0.001 ETH bet — all enforced server-side. No new gaps found; corroborates
  F04/F06/F07's independent, more extensive validation work reaching the same conclusions.

## v1.13.1 (Sep 10, 2026)

- **death.fun F01 — on-chain forensics addendum.** Scanned the live contract's full history and
  decoded **every `increaseBet` transaction ever mined (7,329)**. Two open questions from the
  original writeup are now settled with production data:
  - ~~**The player submits, not the backend.**~~ **RETRACTED — this was wrong.** `tx.from ==
    game.player` on 7,329/7,329 txs does **not** prove the player submitted it: on Abstract these
    are type-113 native-AA transactions, so `tx.from` is the *account*, not the signer, and a
    session key produces the identical on-chain shape. Decisive counter-check: the client bundle
    has **zero non-ABI references** to `serverSignature` (every hit is inside an ABI entry), and
    its only `createGame` call-site is a dummy-argument gas estimate — a client that never
    receives a signature cannot build a signed call. The session grant names the **server wallet**
    as signer. **The backend submits.** The original writeup's inference ("the backend evidently
    calls this server-side") was correct; an earlier revision of this addendum wrongly
    "corrected" it and has been fixed. **No player ever held the exploit path.**
  - **Feature is dormant, not removed.** Ran 2026-03-11 → 2026-04-12 (5,279 + 2,050 events), then
    **zero calls for 5 months**. No UI button and no API route today
    (`/api/games/<id>/increase-bet` → 404 HTML; method validated against the real
    `/api/games/<id>/select-tile` route → 401 JSON). Function still deployed and callable.
  - **Never exploited.** 7,329 distinct signatures, zero reuse; every tx paid the signed amount in
    full. Good news for the disclosure.
  - **Signer identified:** `0x937CddeCf00cD7f1f667f385deDFaE275A0f2Ea7` — 60/60 ECDSA recoveries,
    live `isAdmin` == true, and the same EOA is contract owner **and** proxy-admin owner. One key
    holds upgrades, bankroll withdrawal, and all settlement signatures.
  - Reproducible scripts + summary in `TARGETS/deathfun/forensics/`.
- **Bonus (unrelated, same target):** independently reproduced death.fun's provably-fair scheme
  from live on-chain data — `deathTile = sha256("<seed>-row<i>")[0:8] % tiles` replayed **10/10
  real games** correctly, and the commitment `sha256(JSON({version, rows, seed}))` matched the
  on-chain `gameSeedHash` exactly (houseEdge 0.04, 8-dp rounding). Seed entropy checked across 122
  games: 122 unique 32-byte seeds, no predictability. Confirms the scheme is sound as designed.


## v1.13.0 (Sep 3, 2026)

- **Exploit-wave study (Aug 20 – Sep 3)** — Postmortems: Provenance state-divergence
  admin bypass (82 markers/~$500K), Cosmos EVM balance-sync cluster (MANTRA/TAC/
  KiiChain/Nesa +2, nominal ~$70M, realized ~$5.7M, fix-existed-3-months disclosure
  failure), Moonwell MAMO oracle pump ($8.7–9.1M, supply-cap bypass via direct
  transfer), Coldcard RNG fallback (~2,055 BTC/$130M hardware).
- **Pattern trace** — `POSTMORTEMS/pattern-trace-2026-09.md`: 8 exploit classes mapped
  to protocol families + detection methods; 14 wave-derived checks added to
  CHECKLIST.md.
- **backed.is ($BACKED, target #28)** — RHC reserve-backed token: 4/4 contracts read
  (token, StockVault, router, fee hook) + empirical fork verification (3% tax lands
  exactly; redeem == preview to the unit). 🟢 Clean-with-notes, 6 observations; ~19x
  floor premium noted.
- **Astro (target #29)** — RHC crash game: black-box depth (function surface via
  bytecode ∩ 4byte, live calldata recovery, fork state-machine probes). All reachable
  paths hardened; settlement validation untestable without source (secret seed chain);
  game observed stalled 7h30m. ⏸ Inconclusive.
- **Coinbarrel (target #30)** — RHC launchpad V5: Phase 0.5 on-chain verification —
  six UUPS proxies under one EOA, feeRouter/impairment impls drift from docs (Aug 30),
  launcher upgraded Sep 3, hook pre-terminal-handoff. ⏸ Blocked (impls unverified, no
  public source).
- **Lesson logged**: the late-Aug RHC/Base micro-wave largely ships unverified source
  (unlike the July batch); verification-first target selection now mandatory.

## v1.12.0 (Jul 28, 2026)

- **evm-cortex integration** — Cloned ccashwell/evm-cortex (50 agents, 94 skills, 19 hooks) into workspace

- **Pashov Audit Group v3** — Vendored attack-framing methodology from pashov/skills: agents are attackers not reviewers#
- **Gap-hunter passes** — 3 cross-lens seam scans added to multi-pass workflow: flow gap, trust gap, numerical gap# v1.11.0 (Jul 24, 2026)

- **DefiLords (target #19)** — Full audit on Arbitrum: 4 ERC-4626 USDC vaults (GrowthVaultV5, FlowVaultBalanced, FlowHybridVault V2, FlowHybridVault V1). Clean verdict.
- **6 observations** — V1 Hybrid vault buggy (known, retired), single EOA owner (no timelock), keeper rebalance centerTick (adapter guards mitigate), full-position liquidation on any withdrawal, getTVL() called on every deposit, defense-in-depth allowance revoke
- **V1→V2 diff analysis** — Identified 6 fixes: yield-reserve-aware deployIdle, correct harvest fee ordering, revert instead of assert, min reserve floor, migrateAdapter(), allowance revoke
- **TMAAR documented** — Trust model, actors, assumptions, accepted risks
- **4 vault sources saved** — GrowthVaultV5 (313 lines), FlowVaultBalanced (311), FlowHybridV2 (620), FlowHybridV1 (491)
- **19 targets audited, all clean**

## v1.10.0 (Jul 24, 2026)

- **STEEL (target #18)** — Full audit on Robinhood Chain: SteelMineV2 (SLVR.fun fork with veSTEEL staking, auto-subscribe, motherlode, refining). Clean verdict.
- **5 observations** — Owner can redirect staker rewards (changeable veSteel address), jackpot odds derived from same drand randomness (second preimage, safe), auto-subscribe grief risk (permissionless keeper), carry accumulators unbounded (no cap, pays to next winner), integer division dust in auto-subscribe escrow
- **New mechanics analyzed** — Auto-subscribe escrow system, motherlode accumulators with 1/625 jackpot roll, ORE-style refining dividend index, carry-forward for no-winner rounds
- **Contract sources saved** — SteelMineV2 (728 lines) + secondary instance
- **18 targets audited, all clean**

## v1.9.0 (Jul 24, 2026)

- **Hood Index / hMAG7 (target #17)** — Full audit on Robinhood Chain: 5 contracts (IndexVault, IndexFactory, NavLens, FeeConverterV4, ZapV4). Clean verdict.
- **Best-designed protocol yet** — Immutable basket, hard-capped fees (compile-time constants), no upgradeability, no pause, no admin withdrawal function
- **6 observations** — No external audit (unit tests only), FeeConverter 1% slippage gap on Chainlink floor, ZapV4 caller-provided routes, dust accumulation from floor-division redeem, one-time-set bootstrap risk, 80h Chainlink staleness window
- **5 contract sources saved + full TMAAR**
- **17 targets audited, all clean**

## v1.8.0 (Jul 24, 2026)

- **HoodBets (target #16)** — Full audit on Robinhood Chain: 2 contracts (HoodBets Chainlink-parimutuel + HoodBetsFactory YES/NO shares). Clean verdict.
- **5 observations documented** — Factory resolver centralization (single EOA decides outcomes), no refund path if resolver ghosts, buyShares lacks nonReentrant, integer-division dust, owner-controlled market params
- **Two different trust models analyzed** — Chainlink version is trustless and well-designed; Factory version is centralized by design
- **Contract sources saved** — HoodBets.sol (302 lines) + HoodBetsFactory.sol (655 lines) with full TMAAR

## v1.7.0 (Jul 24, 2026)

- **Peeps (target #15)** — Full audit on Robinhood Chain: PeepsCurveFactory, PeepsBondingCurve, PeepsLaunchToken, PeepsLPFeeVault, PeepsCurveMath. Clean verdict.
- **6 observations documented** — LP Fee Vault `onERC721Received` mapping corruption (anyone can overwrite `tokenPosition` with arbitrary NFTs), router/migrator centralization (single point of trust), sell can reverse graduation phase, factory params unset at construction, curve math verified sound
- **Full combined stack applied** — TMAAR, 6-agent hunting, BountyForge triage, on-chain verification
- **Curve math verified** — `PeepsCurveMath` correctly uses ceil-division for retained reserves (seller-favorable), constant product invariant is non-decreasing
- **CHECKLIST.md + FINDINGS.md** updated

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

- **Senior Auditor SOP** — Feynman Socratic Inversion mental toolkit now mandatory on every function read
- **Gap-hunter scan template** — New TEMPLATES/gap-hunter-scan.md with full seam checklists for all 3 passes
- **Methodology table expanded** — 4 new layers in combined stack: attack-framing, Senior Auditor SOP, gap-hunter, fuzz gen
- **Fizz fuzz generation** — Echidna and Medusa stateful fuzz suite generation available from evm-cortex skills
- **20 targets audited all clean** — K613 on Monad was target 20, 36K TVL
- **Target filter updated** — Pivoting to bigger bounties: Immunefi and HackenProof targets with 500K+ TVL