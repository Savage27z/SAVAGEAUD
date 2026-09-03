# Astro (Robinhood Chain) — Target README

**Status:** ⏳ Black-box audit in progress (Phase 0.5 complete-ish; source NOT available — unverified on both RHC explorers, no repo, IPFS metadata unreachable)

| | |
|---|---|
| Target | Astro (astro.fun) — provably-fair USDG crash game w/ bankroll (House side via ASTROLP) |
| Chain | Robinhood Chain (4663) |
| TVL | ~$85.4K (DefiLlama, listed 2026-08-24) |
| Category | Luck Games (crash) |
| Deployed | CrashGame created ~2026-08-11 (23 days before audit start) by `0x89CD80dc1dce754d4358bacb9740933447450b92` |
| Audits | DefiLlama: 0. No audit links/docs/GitHub found |
| Source | ❌ NOT public: robinhoodchain.blockscout.com + rh-scan.com both unverified; no GitHub; solc metadata (0.8.24) IPFS hash `QmPGRHfLbsCdQTfyGXnn7JSEGBYCY1qyBP5TfkSF1nCefd` unreachable from box |
| Docs | docs.astro.fun — round lifecycle, provably-fair math published, bankroll/HWM economics |
| Team | Unknown handle yet (to find: site links, docs) |

## Contracts (verified on-chain, all match docs)
- **CrashGame** `0xcC679b67eE1AbC40C06CFE20ce4479EFFaD9A407` (21,499-byte contract, solc 0.8.24) — game + rounds + bets + owner/admin
- **BankrollVault** `0x58D2f2D46af20C357885d540A9c02fDD791Ee1CF` — matches bankroll() getter ✓ (LP/ASTROLP + USDG custody)
- **ProvablyFair** `0x9e07AdC6EEa2eE5c781417f277634104210bA43f` — matches 0xc62416aa getter ✓ (crash math lib/contract)
- **AccessController** `0x77b12cAA89F78be0702e4bC9613FAeaac66E70FB` — matches accessController() ✓ (roles)
- USDG `0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168`

## Mechanism (docs + on-chain confirmed)
- Pre-generated **hash chain** of seeds (keccak(Seed[n+1]) = Seed[n]); final hash anchored once on-chain. Seed for round N revealed at finalize, contract checks it hashes back.
- **Salt = blockhash of the close-betting block** (unknown to anyone until mined; recorded at Close Betting, locked at Lock Salt which happens AFTER close).
- Crash point = `f(seed, salt)` — documented formula from CrashMath.sol (Bustabit-style), house edge 1/33 ≈ 3%.
- **Manual/auto cashout happens OFF-CHAIN** (operator tracks multiplier animation); at Finalize the operator submits `finalizeRound(roundId, seed, salt, winners[(addr, amount)])` — contract checks seed↔commitment, recomputes crash, settles winners; losers' bets are house profit.
- Safety rails: one bet/player/round, minBet $0.50 / maxBet $1,000, per-bet multiplier ceiling from bankroll at round start, 1h stall → refunds, 7d → owner force-cancel refunds.

## Phase 1 black-box results (live RPC probes, no state change)
- currentRoundId=4104 (~4,100 rounds since Aug 11); paused=0; houseEdgeDivisor=33; minBet=500000 (6dp $0.50); maxBet=1e9 ($1,000); MAX_PLAYERS=300; EMERGENCY_TIMEOUT=604800
- **Access model clean at admin layer**: setPaused/setMaxPlayers/setBetLimits/emergencyForceCancel/commitRound all revert `0x82b42900` (Unauthorized/Ownable) for a random EOA → owner-gated. Operator EOA `0x36D75c31…` drives Commit→Close→LockSalt→Finalize; players only Place Bet.
- Function surface (bytecode selectors ∩ 4byte): placeBet(uint256,uint256,uint256) 0xe71c9697; lockSalt(uint256) 0x272f911c; emergencyForceCancel(uint256) 0x4b79704c; setPaused(bool) 0x16c38b3c; setMaxPlayers(uint256) 0x288dee3b; setBetLimits(uint256,uint256) 0x7687dd49 + getters (rounds, bets, getRound, getBet, minBet/maxBet, paused, bankroll, accessController, houseEdgeDivisor, currentRoundId, EMERGENCY_TIMEOUT, MAX_PLAYERS, getRoundPlayers, getCurrentRound, getMaxBet).
- Live calldata recovered: commitRound = `0x4ed71302()` no args (owner-only); closeBetting = `0xb4ad06a1(uint256 roundId)`; finalizeRound = `0x33129ef6(roundId, bytes32 seed, bytes32 salt, (address,uint256)[] winners)`; placeBet = `0xe71c9697(roundId, uint256, uint256)` e.g. (4103, 20000, 5000000) — 2nd arg likely auto-cashout BP or ceiling class, 3rd = wager (6dp).
- Round loop block-order verified: Commit(seed committed) → PlaceBet → CloseBetting(records block#) → LockSalt → Finalize(seed+salt revealed, winners paid). Salt after close ✓.

## Hypotheses to test on fork (impersonate owner 0x36D75c31… / player)
1. finalize malformed winners: (a) winner who never bet, (b) duplicate winner, (c) payout > bet×crash ceiling, (d) payout multiplier > crash point, (e) seed that doesn't hash to commitment, (f) salt ≠ blockhash(closeBlock), (g) re-finalize same round, (h) finalize non-existent/stale round
2. placeBet: amount 0 / > maxBet / second bet same round / during wrong phase / after close (replay closeBetting block order)
3. Refund path: can anyone trigger 1h-stall refunds? correct amounts? after finalize?
4. forceCancel before 7d? partial?
5. BankrollVault LP: deposit/withdraw/HWM accounting — impersonate LP + owner paths
6. Owner powers: setBetLimits to 0 / huge; setPaused mid-round (funds stuck?); pause→refund semantics

## Phase 2 fork results (anvil fork of RHC; eth_call simulations)
**State machine is well-hardened on every path we could reach:**
- Re-finalize a finalized round (round 4103, real calldata replay) → revert custom `0xac831504` code 2 (already-finalized/wrong-state fires BEFORE seed/winners checks — also means winner-list validation is unreachable on old rounds)
- Finalize with mutated seed → same code 2 (state gate first)
- commitRound() while current round unfinalized → `0xac831504` code 5 (rollover blocked)
- lockSalt wrong state → code 2; closeBetting as owner in non-betting state → empty revert (phase-gated)
- **emergencyForceCancel is NOT owner-callable** → separate role via AccessController (role separation ✓); <7d cancel blocked
- placeBet validation order observed: amount checks (zero → `0x5688ffb3`) before phase/other checks (valid amount in stale round → `0x6b23d0f6`)
- Admin setters + commitRound: `0x82b42900` Unauthorized for outsiders ✓

**Testing constraints discovered (why we stopped here):**
- Winner-list validation (the interesting surface) REQUIRES finalizing a round whose seed check passes → needs the operator's secret hash-chain seed → **impossible without source**. Seed check sits behind the state gate, so old/replayed rounds can't reach winners processing.
- No open-betting window exists to test bet edges: the game has been **stalled since 2026-09-03 14:47 UTC (7h30m+)** — round 4104 committed at block 53,502,820, never closed/finalized; zero game txs in 257K+ blocks since. Round 4104 has **0 players** (no funds at risk). placeBet on the stale round reverts (`0x6b23d0f6`).
- RHC public RPC is not archival → can't fork to the last open-betting window (block 53,502,580 fails: "metadata is not found").

## Verdict at black-box depth
🟡 **No vulnerability found on any reachable path** (authz, state machine, replay protection, amount gates, role separation all hold). **Settlement/winners validation + bankroll/HWM math remain UNVERIFIED** — only reachable with source or decompilation. Live liveness issue observed: game stalled 7h30m+ (operator bot down), round 4104 orphaned but empty.

## Deeper options
- **Decompile** (heimdall-rs on CrashGame + BankrollVault bytecode) → pseudo-source for settlement/winners/bankroll logic; no outreach. Recommended if continuing.
- **Source from team** (option B) — full method.
- Stop: document as inconclusive-on-settlement, no reportable finding.

## Actors observed on-chain (from tx history, block ~53,502,xxx)
- `0x36D75c31aa1f44e26303462fbe84de7529b713ea` — round operator (calls Commit Round, Lock Salt, Close Betting, Finalize Round)
- `0x557CD0e7d5a7ccc843792e00254e0bd097e52d12` — player(s), calls Place Bet
- `0x89CD80dc1dce754d4358bacb9740933447450b92` — contract creator

## Round loop observed (blocks ascending, ~10s rounds)
Commit Round → Place Bet(s) → Close Betting → Lock Salt → Finalize Round → (next round) Commit Round
- Fairness order CONFIRMED at tx level: **Lock Salt happens AFTER Close Betting** — bets cannot react to the revealed salt.
- One operator EOA drives every state transition; players only Place Bet.

## Black-box plan (method A — no source)
1. Define intended behavior from docs (round lifecycle, cashout/settlement, HWM economics, limits) — done next
2. Recover function surface: bytecode PUSH4 selectors ∩ 4byte.directory text lookups
3. Probe permissions: eth_call state functions as random EOA (read-only, safe) — who can commit/lock/close/finalize/withdraw?
4. State-machine checks on live rounds: salt-lock-before-close invariant, one-round-at-a-time, stuck-round paths, betting after close
5. Fairness: crash-point derivation matches documented formula (need a full round's seed+salt — can observe via events/logs if decoded, else storage)
6. Bankroll/HWM: deposit/withdraw LP accounting; limits enforcement
7. Findings → reproduce on fork before reporting
