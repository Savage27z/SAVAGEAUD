# death.fun (DeathFun / "Death Race")

**Chain:** Abstract (zkSync-family L2, chain ID 2741)
**Chain Explorer:** https://abscan.org/address/0x27EDd16eE56958fddCBA08947f12C43DDeC2B20C
**Date:** September 9, 2026
**Status:** 🔴 Findings (2 — F01 confirmed on a real zkEVM fork of the deployed contract,
F02 confirmed live from the production bundle + on-chain reads)

**Audited commit:** verified source as deployed, compiler `v0.8.24+commit.e11b9ed9`, `zksolc
v1.5.13`, pulled via Etherscan V2 unified API (`chainid=2741`)
**Final commit:** — (no fix round yet)
**Repo:** verified source only (Abscan). `github.com/Death-fun` exists but only hosts a
client-side provably-fair hash-verifier tool, not the contract source.

## Open threads (updated 2026-09-10 — read this before touching the target)

All three threads below are independent; any of them can move without the others.

| Thread | State | Blocked on |
|---|---|---|
| **Disclosure email** | `disclosure/draft-email.md` **v3** ready to send. Leads with the F01 defect, then the v2 question, ends with an explicit "no funds were taken". Correction note kept at the bottom, marked do-not-send. | nothing — send it whenever 𝖲𝖠𝖵𝖠𝖦𝖤 wants |
| **Live reachability capture** (`disclosure/live-capture/`) — answers "does the backend ever hand a *player* a signature?" | Harness built, 6/6 self-test passing, Chrome installed and both dry runs done. **Not yet run with a real key.** | the throwaway funded key (0.005 ETH on Abstract) |
| **Authorised live on-chain demo** (`disclosure/live-demo/`) — replays one note 5x on mainnet to show the contract's own `betAmount` inflated | Harness built, tested against mainnet reads, `selector_controls.py` proves `increaseBet` exists on the live proxy. **Not yet run.** | two signed notes from the team (`ask-for-the-notes.md`) — send that, or `ask-live-demo.md` for the softer version |

**Standing decisions — do not relitigate without new evidence:**

- **No cash-out.** `cashOut` requires the team's own signature over `payoutAmount`, so paying the
  inflated figure would demonstrate that *they* paid us, not that the contract is broken, and it
  moves live player funds to do it. The `betAmount` inflation proves the missing guard alone. The
  clean alternative offered in `live-demo/NOTE-FORMAT.md` is to cash out our own real stake.
- **F01 likelihood is Low (external), not High.** The "restore High" reasoning on the session-key
  grant was superseded by the client-flow proof (see the finding's Impact × Likelihood section and
  addendum §5.1). The full three-round trail is kept deliberately, including the round that was
  wrong, so the reasoning stays auditable.

## Overview
"Mines"-style on-chain casino: player wagers ETH, advances through a grid for increasing
multipliers, cashes out before hitting a "death" tile. Outcome logic runs off-chain (server
picks a seed, commits its hash, later reveals it — classic hybrid provably-fair pattern); the
on-chain contract only handles bet-taking, admin-signed settlement, and bankroll custody.
Genuinely live: $44K bankroll, $252K wagered in the last 30 days, real ongoing users.

## Key Contracts

| Contract | Address | Role |
|----------|---------|------|
| DeathFun (proxy) | `0x27EDd16eE56958fddCBA08947f12C43DDeC2B20C` | Entry point — `TransparentUpgradeableProxy`, holds the ~$44K ETH bankroll |
| DeathFun (implementation) | `0x2c133230CFca00b9bf78c46DAe03A97019D96551` | Actual logic, deployed 193 days ago |
| Old DeathFun (retired) | `0x0D55076685EcB11c0Caf4fa749D26823B509d03E` | Prior deployment, negligible balance, different `messagePrefix` (checked directly — no cross-contract replay between the two) |

## TMAAR
See [TMAAR.md](TMAAR.md).

### Actors & Trust Levels (summary)
| Actor | Trust Level | Notes |
|-------|-------------|-------|
| Owner | High | Upgrade proxy, add/remove admins, full bankroll withdrawal |
| Admins (backend signer) | High | Sign all player actions; can also call `cashOut`/`markGameAsLost` directly with no signature |
| Players | None (but see F01) | Can inflate their own `betAmount` for free — unclear downstream impact, depends on off-chain backend trust (explicit unknown) |

### Key Assumptions
- A signed `increaseBet` message is used once, for the ETH actually sent — **false, this is F01**
- Signed messages are scoped to this specific contract — checked directly (OLD vs. NEW
  `messagePrefix` differ, so no live cross-contract replay today), but there's no
  `address(this)`/`chainid` binding, so this is a real hardening gap for future redeploys

### Accepted Risks
- Off-chain, closed-source RNG/settlement backend — same category limitation as this repo's
  Astro entry, documented rather than assumed safe
- Upgradeable proxy, single owner, no timelock observed

## Exclusions
- Off-chain "mines" outcome/RNG logic — not on-chain, not public, out of scope
- `death-fun-provably-fair` client-side verifier repo — reviewed only far enough to confirm it's
  a post-hoc hash checker, not the settlement logic itself
- Frontend (death.fun) — not reviewed beyond extracting contract addresses from its JS bundles

## Analysis Summary
- Single upgradeable contract, 463 lines, full read completed in one pass
- Signed-settlement architecture (admin ECDSA signatures authorize `createGame`/`cashOut`/
  `markGameAsLost`/`increaseBet`) — `cashOut` correctly uses CEI + `nonReentrant` for the actual
  ETH payout; reentrancy surface looks clean
- `createGame` correctly binds `msg.value` into its signed hash; `increaseBet` does NOT — this
  inconsistency is the direct root cause of F01
- No signature-nonce/used-tracking anywhere, compounding F01 into an unlimited-replay bug, not
  just a single-use mismatch
- **Live UI check (2026-09-10), two rounds, then a third that settled it:**
  (1) played the real app end-to-end with real (tiny) funds — mint, create a real game, advance a
  round, cash out successfully. Never found a manual "increase bet" *button* anywhere in the flow.
  (2) **But** searching the frontend's JS bundles for `increaseBet` found its function selector
  registered in the Abstract session-key permission setup with `valueLimit: Unlimited` — the same
  grant shown in the app's own "Create Session Key" screen (3 permissions: Create Game, Cash Out,
  Increase Bet). An unlimited-value grant isn't registered for dead code, so the backend
  evidently calls this in normal operation — this briefly **restored likelihood to High**.
  (3) **Now settled against High:** the grant is a permission for the **server wallet** to submit
  on the player's account, not a capability handed to the player. Confirmed on the client — the
  create-game flow `POST`s `{betAmount, rowConfig}`, gets back **only `{preliminaryGameId}`**,
  shows "Preparing game…", then polls `/api/games/active` until `pending_onchain` clears. It never
  receives a signature, never builds calldata, never submits a transaction. `increaseBet` uses the
  identical prepare-then-poll shape (`increase_bet_pending`). So the backend both signs **and**
  submits, and no player ever holds a note. **Frequency of generation ≠ attacker access** — see
  the finding's Impact × Likelihood section for the full trail (all three rounds kept on purpose,
  including the one that was wrong)
- Verified live on-chain: real $44K bankroll balance, real `messagePrefix`/`gameCounter` values,
  confirmed OLD vs. NEW contract don't share a domain prefix (ruled out one hypothesis instead of
  assuming it)

## Passes Performed

| Phase | Method | Status |
|-------|--------|--------|
| 0: Recon | Surface map, trust model, deps, live on-chain state via `eth_call`/`cast` | ✅ |
| 0.5: TMAAR | Documented actors, assumptions, risks | ✅ |
| 1: Read | Full code read (Feynman questioning) — entire contract, single pass | ✅ |
| 2: Hunt | Access control / reentrancy / signature / oracle-trust checklist run | ✅ |
| 3: Tools | Slither | ⏭️ skipped this session |
| 4: Fork tests | Foundry fork PoC for F01 | ✅ — confirmed on a real zkEVM fork. Standard Foundry can't execute Abstract's zksolc-compiled bytecode; built `foundry-zksync` from source (3 local patches for Windows support) plus real Windows `zksolc`/ZKsync-fork-`solc` binaries. Full saga in the finding's "Toolchain notes". |
| 5: Deep dive | Second pass, different angle (cross-contract replay hypothesis) | ✅ — hypothesis formed, then directly checked and ruled out (not just assumed) via live `messagePrefix()` comparison |

## Findings

| # | Finding | Severity | Impact | Likelihood | Status |
|---|---------|----------|--------|------------|--------|
| F01 | `increaseBet()` missing `msg.value` check + missing signature-replay protection | **Low / informational** (defence-in-depth — re-rated after forensics) | Low (external) | Low | **Confirmed** — fork PoC: 1 wei paid, betAmount inflated to 35 ETH via 7 signature replays. **On-chain forensics: 7,329 real `increaseBet` txs (554 accounts, 15-min deadlines), then dormant since 2026-04-12. CORRECTION: an earlier revision claimed these proved player-submission and player-exploitability — that was wrong and is retracted. The txs are type-113 native-AA (`tx.from` = account, not signer) and the client never handles a signature, so the backend submits. No player ever held the exploit path.** |
| F02 | **v2 migration drift** — the staged v2 contract adds signature-replay protection (`rakebackNonces`, `referralNonces`) to its two new ETH-paying claim functions but leaves `increaseBet`'s signature byte-identical to v1 with no nonce, and re-enables it at Unlimited / 100 ETH per session call | Informational (F01 timing risk) | Medium **if** v2 ships as the ABI implies | High (evidence is live) | **Confirmed** — live production bundle ships a complete undeployed v2 ABI; live proxy impl slot still points at audited v1; every v2-only selector returns no data on the live proxy. **Honest limit: an ABI cannot prove the absence of a `msg.value` check, so we do NOT claim v2 still contains F01 — we claim the nonce half is provably absent and the function is being switched back on.** |

Full writeup: [findings/F01-increaseBet-free-inflation.md](findings/F01-increaseBet-free-inflation.md)
**On-chain forensics + CORRECTION (read this too):** [findings/F01-ADDENDUM-onchain-forensics.md](findings/F01-ADDENDUM-onchain-forensics.md)
— 7,329 decoded production transactions, the retraction of the player-submission claim, and the
correct explanation (`tx.from` on a native-AA chain is the *account*, never the *signer* — session
keys and relayers produce identical on-chain shape). Also identifies the single EOA
(`0x937CddeCf00cD7f1f667f385deDFaE275A0f2Ea7`) that is simultaneously the contract owner, the
proxy-admin owner, and the signer of every `increaseBet`.

**v2 migration drift:** [findings/F02-v2-migration-drift.md](findings/F02-v2-migration-drift.md)
— the live frontend ships **two complete contract interfaces at once**. The v2 ABI (116 entries)
adds `claimRakeback`, `claimReferral`, `payReferral`, `setGameCounter`, `setServerSignerAddress`,
`withdrawFunds` and per-action prefixes (`createGamePrefix`, `cashOutPrefix`,
`claimRakebackPrefix`, `claimReferralPrefix`, `markGameAsLostPrefix`), changes `cashOut` to a
`bytes32 gameStateHash` and `createGame` to hash-based inputs — **and adds
`rakebackNonces(address)` / `referralNonces(address)` while leaving
`increaseBet(uint256,uint256,uint256,bytes)` completely unchanged with no nonce.** v2 also moves
`increaseBet` from *not granted at all* in `sessionPolicyV1` to *Unlimited value / 100 ETH per
use* in `sessionPolicyV2`. Config baked into the bundle:
`NEXT_PUBLIC_CONTRACT_ADDRESS = 0x27EDd16e…` (live v1 proxy),
`NEXT_PUBLIC_SERVER_WALLET_ADDRESS = 0xc372B35582933277d5f4431F1a322Abc8DeA0612` (nonce 0,
balance 0 — signer-only key, as expected).

## Verdict
Not clean. F01 is **confirmed end-to-end on a real zkEVM fork** of the actual deployed contract
— two missing checks in one function, with a live PoC showing 1 wei paid turning into a 35 ETH
recorded bet via seven replays of one signature. The live contract holds real, meaningful money
($44K) and active daily volume. Getting fork execution working on Abstract from a Windows
session required building `foundry-zksync` from source (no official Windows release exists) and
patching three real upstream bugs — see the finding's "Toolchain notes" section, preserved for
any future zkSync-family target. Ready for RULES.md #5-compliant private disclosure whenever
𝖲𝖠𝖵𝖠𝖦𝖤 wants to send it.
