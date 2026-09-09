# death.fun (DeathFun / "Death Race")

**Chain:** Abstract (zkSync-family L2, chain ID 2741)
**Chain Explorer:** https://abscan.org/address/0x27EDd16eE56958fddCBA08947f12C43DDeC2B20C
**Date:** September 9, 2026
**Status:** 🔴 Findings (1, source-confirmed — fork execution blocked by zkEVM/Foundry tooling gap)

**Audited commit:** verified source as deployed, compiler `v0.8.24+commit.e11b9ed9`, `zksolc
v1.5.13`, pulled via Etherscan V2 unified API (`chainid=2741`)
**Final commit:** — (no fix round yet)
**Repo:** verified source only (Abscan). `github.com/Death-fun` exists but only hosts a
client-side provably-fair hash-verifier tool, not the contract source.

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
| 4: Fork tests | Foundry fork PoC for F01 | ⚠️ **blocked** — Abstract's zksolc-compiled bytecode isn't executable by standard Foundry/revm fork execution (confirmed: even a plain view call reverts on fork while succeeding via live `cast call`). Needs `foundry-zksync`. Test written and ready, not yet run. |
| 5: Deep dive | Second pass, different angle (cross-contract replay hypothesis) | ✅ — hypothesis formed, then directly checked and ruled out (not just assumed) via live `messagePrefix()` comparison |

## Findings

| # | Finding | Severity | Impact | Likelihood | Status |
|---|---------|----------|--------|------------|--------|
| F01 | `increaseBet()` missing `msg.value` check + missing signature-replay protection | High (conditional — see writeup) | High | High | Source-confirmed, fork execution blocked (zkEVM tooling gap) |

Full writeup: [findings/F01-increaseBet-free-inflation.md](findings/F01-increaseBet-free-inflation.md)

## Verdict
Not clean. F01 is real and unambiguous at the source level — two missing checks in one function,
confirmed by direct code read against the actual verified deployed bytecode, with the live
contract holding real, meaningful money ($44K) and active daily volume. The one honest gap is
execution-level proof: Abstract's zkEVM bytecode isn't runnable by the Foundry tooling available
in this session, so this stays at "source-confirmed" rather than "fork-confirmed" (contrast with
Run Money, where standard EVM fork testing worked cleanly). Closing that gap (`foundry-zksync`,
or a cooperative/authorized test against a testnet deployment) is the natural next step before
any team disclosure, per RULES.md #2.
