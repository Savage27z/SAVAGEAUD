# Findings Index

No critical-grade reportable findings to date. Informational/Medium observations on
several targets; disclosure status per target (user handles outreach).

## All Targets

| # | Target | Chain | TVL | Findings | Verdict |
|---|--------|-------|-----|----------|---------|
| 1 | Quiver Protocol | Robinhood Chain | $3.1K | None | 🟢 Clean (rounding quantified: 1 wei max) |
| 2 | SLVR GridLottery | Robinhood Chain | $105K | None | 🟢 Clean |
| 3 | The Index | Robinhood Chain | — | None | 🟢 Clean |
| 4 | Moonvault | Robinhood Chain | $580 | None | 🟢 Clean (Beefy fork) |
| 5 | Basalt Vault | Arbitrum | $119K | None | 🟢 Clean |
| 6 | OBSDN | Monad | $220K | 5 observations (sequencer trust model) | 🟢 No critical findings |
| 7 | Cleave | Ethereum | $76 | None | 🟢 Clean |
| 8 | SukukFi | Berachain | $54 | None | 🟢 Already C4 audited |
| 9 | openOracle | Base | $3.5K | None | 🟢 Clean |
| 10 | Arcis Protocol | Base | $120 | None | 🟢 Clean |
| 11 | Windfall Lotto | Polygon | $1.4K | None | 🟢 Clean |
| 12 | Sentry | Robinhood Chain | $31K | None | 🟢 Clean |
| 13 | MinePea | Robinhood Chain | $5.5K | 12 observations (TWAP buyback price limit, quiverCallback re-entry, executor centralization, rounding dust) | 🟢 Clean — deep second pass confirmed |
| 14 | Ravenhood | Robinhood Chain | $0 (treasury $56K) | 8 observations (owner separation, no on-chain buyback, burn slippage, reward drain risk) | 🟢 Clean — standard patterns, well-structured |
|| 15 | Peeps | Robinhood Chain | $26K | 6 observations (LP vault mapping corruption, router centralization, graduation phase reversal, curve math verified) | 🟢 Clean — solid architecture, sound math |
|| 16 | HoodBets | Robinhood Chain | $803 | 5 observations (resolver centralization, no refund path in factory, nonReentrant missing on buyShares, dust accumulation, owner market params) | 🟢 Clean — two contracts: Chainlink parimutuel (trustless) + Factory YES/NO (centralized by design) |
|| **17** | **Hood Index** | **Robinhood Chain** | **$75** | **6 observations (no external audit, 1% slippage gap, caller-provided routes, dust accumulation, one-time-set risk, 80h staleness window)** | **🟢 Clean — best-designed protocol yet: immutable basket, hard-capped fees, no upgrade, no admin withdrawal** |
||| **18** | **STEEL** | **Robinhood Chain** | **$911** | **5 observations (owner redirects staker rewards, jackpot from same randomness, auto-subscribe grief risk, carry accumulation, integer dust)** | **🟢 Clean — SLVR.fun fork with veSTEEL staking, auto-subscribe, motherlode, refining** |
|| 19 | DefiLords | Arbitrum | $2.3K | 6 observations (V1 bugs known-to-team, single EOA owner, keeper rebalance, full withdraw liquidation, getTVL on every deposit, defense-in-depth allowance revoke) | 🟢 Clean — well-structured ERC-4626 vaults, V1→V2 fixes show proactive bug-finding |
| 20 | K613 | Monad | $36K | 5 contracts (Aave fork + staking) | 🟢 Clean |
| 21 | ATOMA | Arbitrum | $64.7K | 7 observations (off-chain NAV, capitalWithdraw reserve gap, operator EOA) | 🟡 Informational |
| 22 | Sherwood | Robinhood Chain | $28.8K | M1 fee-bypass (vault, off-scope), referral + Alchemy key (pre-reported), funded E2E deposit/withdraw tested clean | 🟡 First Medium (vault M1) — app surface clean |
| 23 | VETRO | Ethereum | $595K | 6 observations (peg-band asymmetry, WBTC fixed-feed blindness, empty-vault yield capture, cross-token oracle coupling, 120s delay, keeper EOA) | 🟡 Informational — audit-gap target, deployed code drifted past QS audit |
| 24 | Flex | Ethereum | ~$300K debt | F1/F2 depositor exit freeze (idle = 0 both markets, burn-shares-pay-later via cold auction) | 🟡 Informational |
| 25 | AZverse AssetVault | Arbitrum | — | Governance verified solid (Safe 3/4 + timelocks); EOA operator/validator trust anchor | 🟡 Informational |
| 26 | MonkeyBet / RaiseController | Robinhood Chain | — | Reserve accounting sound; EOA-vs-multisig docs mismatch | 🟡 Informational |
| 27 | Orchard | Robinhood Chain | — | Timing seam verified clean | 🟡 Informational |
| 28 | backed.is ($BACKED) | Robinhood Chain | ~$52K reserve | 6 observations (addStock retroactively reshapes redeem basket + single EOA, instant fee→10%, maxSpendPerBuy default uncapped [live 0.5 ETH], minOut=0, hook ETH-only scope, O(n) redemption) | 🟢 Clean-with-notes — empirically verified on fork (tax lands, redeem exact); ~19x floor premium noted (economic) |
| 29 | Astro (crash game) | Robinhood Chain | $85K | Black-box depth only: state machine hardened; settlement/winners validation UNVERIFIED (secret seed chain, source closed); game stalled 7h30m | ⏸ Inconclusive — source not public |
| 30 | Coinbarrel (launchpad V5) | Robinhood Chain | $61K | Phase 0.5 only: 6 UUPS proxies under ONE EOA, 2 impls drift from docs (Aug 30), launcher upgraded Sep 3, hook pre-terminal-handoff | ⏸ Blocked — implementations unverified, no public source |
| 33 | death.fun (DeathFun) | Abstract (zkSync L2) | $44K (live bankroll, $252K/30d wagered) | **F01** (High, **Confirmed on a real zkEVM fork**) — `increaseBet()` is missing both a `msg.value == amount` check and any signature-replay protection; a single admin-signed message can be resubmitted an unlimited number of times before its deadline, inflating `betAmount` for free every time. Fork PoC against the real deployed contract: player paid 1 wei total, inflated recorded `betAmount` to 35 ETH via 7 replays of one signature. Direct-drain impact beyond that still depends on an explicitly-flagged unknown (does the closed-source backend trust on-chain `betAmount`?). Required building `foundry-zksync` from source on Windows (no official release exists) plus 3 upstream patches — documented in the finding's Toolchain notes for reuse. **On-chain forensics addendum + CORRECTION (Sep 10):** decoded all **7,329** real `increaseBet` transactions ever mined. A first draft claimed these proved player-submission (and therefore player-exploitability); **that was wrong and is retracted.** On Abstract the txs are type-113 native-AA and `tx.from == game.player` identifies *whose account acted*, not *who signed* — session keys produce the same shape. Decisive check: the client bundle contains **zero non-ABI references** to `serverSignature` (every occurrence is inside an ABI entry) and its only `createGame` call-site is a gas estimate with dummy args — a client that never receives a signature cannot build a signed call. The session grant names the **server wallet** as signer. Conclusion: the **backend** submits (matching the original writeup's inference), so **no player ever held the exploit path**. Feature dormant since 2026-04-12 (no UI button, no API route today); function still deployed and callable. Recovered signer `0x937CddeCf00cD7f1f667f385deDFaE275A0f2Ea7` is simultaneously `isAdmin`==true, contract owner, and proxy-admin owner. Zero signatures reused across all 7,329 txs — never exploited. **F01 re-rated: Low / informational — defence-in-depth hardening gap, NOT a live drain.** Worth reporting because (a) safety currently depends entirely on the off-chain caller choosing the right `msg.value`, one integration away from breaking, (b) `createGame` binds `msg.value` while `increaseBet` does not, and there is no nonce anywhere, and (c) it is cheap to fix with zero migration cost. | 🟡 Findings — Low/informational, ready for private disclosure |
| 32 | Run Money (ClubPool) | Base | $3K (~$2,088 USDC + 0.35 ETH, live) | **F01** (Medium, **Confirmed on fork**) — flash-stake bonus-pool inflation: any athlete can temporarily inflate their stake right before a compliance check, withdraw immediately, and keep an oversized share of the epoch's yield pool for the rest of the epoch. Attacker (10 USDC real stake) earned ~100x a genuine 1,000-USDC-staked victim's bonus. **F02** (High, **Confirmed on fork**) — `recordActivity`'s non-compliant branch subtracts an athlete's CURRENT stake instead of their frozen snapshot; corrupts the shared pool total from ordinary usage (no attacker needed) — bricks other compliant athletes' `claimBonus`, or permanently locks a compliance status via underflow-revert. Principal never at risk either way. Live for ~93 weekly epochs. | 🔴 Findings — ready for private disclosure |
| 31 | Moocon (no-loss lottery) | Solana | $14K | Phase 0/0.5 only (closed-source Anchor program, no IDL — reversed via BPF string extraction + Anchor-discriminator-verified account reads): admin/upgrade-authority and keeper/round-execution are two distinct EOAs today, but admin holds `SetVrfAuthority` (no timelock observed) — one tx from reassigning round control to itself; dual randomness surface (VRF + commit-reveal) and merkle ticket-range winner selection not yet call-order-verified; single keeper bot runs entire Reveal→Undelegate→Commit cycle with no observed permissionless fallback | ⏸ In progress — TMAAR done, full logic read blocked on no source/IDL |

## Process

When a finding is confirmed (fork-proven or on-chain verified):
1. Write it up using `TEMPLATES/finding.md`
2. Save to `<target>/findings/`
3. Add a row here linking to the finding
4. Ask the user to proceed with disclosure

## Methodology Sources

This repo's combined methodology draws from ALL of the following — every target gets every layer:

- **Macro (0xmacro)** — TMAAR trust model, Impact×Likelihood matrices, commit tracking, public audit library (130+ reports)
- **BountyForge v2.0** — 4-gate finding triage (Reality → Impact → Dedup → Quality), "What Changed" disclosed-report learning, anti-pattern library
- **Open-Kritt** — Multi-agent orchestration engine, narrow focused passes, brute-force entry points × bug classes
- **Blockian (Immunefi #18)** — Anchored deduplication, relative ranking, repeats for enumeration
- **EVM Hack Analyzer** — Opcode-level exploit replay, historical hack study, PoC export
