# F0x — Entropy latency CENSUS + the refund-race, sharpened (nar.bet, Monad)

**Status:** measurement COMPLETE, hypothesis SHARPENED, exploit path NOT yet closed.
**Method:** live `eth_getLogs` on Monad mainnet. No speculation — every number below is from
on-chain data, script in `recon/entropy_race_test.py` (re-runnable).

## 1. The measurement

`REFUND_COMMIT_WAIT_BLOCKS() = 20` is nar.bet's anti-abort guard: a player must commit a refund,
wait 20 blocks, and only then can they claim it. The intended purpose is to stop a player
refunding a bet **after** they learn the outcome.

So we measured the actual Entropy fulfillment latency on Monad — request block → reveal block —
for nar.bet's own cycles:

**315 paired request→reveal cycles (30-day window, Entropy proxy
`0xd458261e832415cfd3bae5e416fdf3230ce6f134`):**

| metric | blocks |
|---|---|
| min | 2 |
| p50 | 5 |
| p90 | 8 |
| p99 | 9 |
| max | 9 |
| **reveals slower than the 20-block commit wait** | **0 / 315** |

Per game: RockPaperScissors 100, CoinFlip 97, Roulette 85, Plinko 26, Slots 5, Mines 2 —
every one with `over_commit_wait = 0`.

**Read:** Entropy always answers inside the wait window (~2.5 s at 0.5 s blocks vs a 10 s wait).
So the naive shape — "commit a refund for *this* bet, then refund after watching the reveal" —
is **structurally dead**. The bet settles ~5 blocks after it is placed; the commitment cannot be
claimed until ~20. By then the request is no longer pending. This kills the *first* reading of
hypothesis #1 and is worth recording as a negative.

## 2. Why that does NOT close the hypothesis (the sharpened shape)

The wait window only protects against timing **one bet**. It does nothing about a **pre-matured
commitment**. The attack that survives the measurement:

1. **Commit a refund while idle** (no bet in flight). 20 blocks later it is mature and immediately claimable.
2. **Then place a bet.** The commitment is already ≥20 blocks old, so it needs no waiting.
3. Entropy answers ~5 blocks later — in a **public transaction** whose data contains the random
   number. The outcome is knowable before the outcome is *settled*.
4. If the reveal is a **loss**: fire `X_Refund()`, ordered ahead of (or in the same block as) the
   callback tx. The wager comes back.
   If the reveal is a **win**: do nothing, let it settle and collect.
5. Net: a free option on every bet — the exact "settle-win / refund-loss" asymmetry the commit wait exists to prevent.

`REFUND_TIMEOUT_BLOCKS() = 2000` (≈17 min) would bound the dry-run window, not kill it.

## 3. The one fact that decides it

Everything hinges on whether the refund path **binds the commitment to a specific requestID**:

- **If bound** (`commitment.requestID == the pending request`) → the attack dies, because at step 1
  the player cannot know the future request's ID. Hypothesis #1 closes NEGATIVE.
- **If not bound** (commitment tracked per-player, `requestID` informational only) → a matured
  commitment is reusable against any later request, and the attack is live.

`RefundCommitmentCreated(address player, uint256 requestID, uint256 claimableBlock)` carrying a
`requestID` is *suggestive* of binding but proves nothing — an event field is not a check.
**This cannot be settled from logs; it needs the implementation bytecode** (see §5).

## 4. Supporting evidence gathered

- **No refund has ever been used.** In the whole 30-day window the game contracts emitted only
  `X_Play_Event` and `X_Outcome_Event` — zero `X_Refund_Event`, zero `RefundCommitmentCreated`.
  The refund path is empirically untouched, which is why nobody has hit this (if it exists).
- **Player cannot choose the request's random value.** `RockPaperScissors_Play(uint256 wager,
  address tokenAddress, uint8 action, uint32 numBets)` — no randomness parameter, and the observed
  call `0x493e7930…` decodes to exactly those four args. So "attacker supplies `userRandomNumber`"
  is **falsified** as a route. The random value comes from the contract.
- **Cycle volume:** 341 request/reveal cycles in 30 days (~11/day) across 6 active games. Low but real traffic.
- **The two logs the player's own tx emits on the Entropy proxy** carry
  `userRandomNumber = 0xa019284a96ed5fb8f5c30065a4f6a3fdb52ff159a8ef60bc7a1906b44512167`, and the
  reveal-side log carries the same value back — so `userRandomNumber` is the cycle correlator. It is
  emitted by the game, **not** supplied by the caller.

## 5. Next step (the work this opens)

1. Read the RockPaperScissors implementation `0x8d2026407da5324bf955ba7f21962816cb477bfc`
   (no verified source — bytecode route) and locate the refund-claim path. The single question:
   **does the claim check the commitment's requestID against the player's current pending request,
   or only the player's address + maturity?**
2. If unbound: fork-attack phase (mandatory before any clean verdict) — anvil fork of Monad,
   impersonate a player, mature a commitment, place a bet, and race `X_Refund()` against a known
   losing reveal. Success = reported finding with a real PoC.
3. If bound: record the negative, and pivot to the refund × settlement ordering question
   (`NotAwaitingVRF` / `RefundClaimPending`) and the ban-vs-in-flight-funds family.

## 6. Calibration notes (detector discipline — both caught only by controls)

- **Event hashes were computed, never guessed.** All 16 observed game topics matched hashes
  derived from the recovered ABI. The 4 Entropy-proxy topics matched **nothing** — not standard
  Pyth `Requested`/`Revealed`, not the `*WithCallback` variants. Rather than guess a name, the
  logs were labelled by **transaction origin** (`tx.to == Entropy proxy` ⇒ reveal side;
  `tx.to ∈ game proxies` ⇒ request side) and verified on a sample: request logs ride the player's
  own tx, reveals arrive in a separate tx from `0x9a436862…` to the Entropy proxy. A confident
  wrong name would have made the entire latency number meaningless.
- **Under-counting caught, not hidden.** A first pass reported 104 cycles/topic; the second reported
  180 and a third 341. Cause: silently dropped chunk errors (this RPC rejects spans > 29,999
  blocks). Logs-per-topic being *exactly equal* (341/341/341/341) was the tell that the sample was
  whole — a partial scan would have produced unequal counts. The final run prints chunk errors
  explicitly.
- **RPC reality on Monad (cost real time):**
  - `rpc.monad.xyz` is unusable under any load — returns `413 Request Entity Too Large` for
    *tiny* requests and `-32602 Invalid params` for a call that succeeded a minute earlier. Both
    are throttling artifacts, not real errors. Do not debug your own code against them.
  - `rpc2.monad.xyz` works, **if you send a browser `User-Agent`** — bare python-urllib gets
    403/400 from it and from drpc/publicnode/thirdweb. Hard cap: **29,999 blocks per `getLogs`**
    (`-32012 request exceeded max allowed range`). Chunk it; 81 chunks = 4.7 s wall clock.
  - `api.monadscan.com` still 404s for everything, so explorer-side data stays unavailable.

## 7. Artifacts

```
TARGETS/narbet/recon/
  scan_logs.py             chunked game-proxy scanner + WMON positive control
  entropy_race_test.py     the census above (re-runnable: `python3 recon/entropy_race_test.py 30`)
  wide_scan.py             topic labelling from computed hashes
  entropy-latency.json     per-caller latency stats
  topic-labels.json        topic0 -> event name, computed
  entropy-race.json        THE RESULT: 315 cycles, p50 5 blocks, 0/315 over the commit wait
```

---

# ADDENDUM (same session, continued) — structural read of the refund path

## 8. RETRACTION: `0x5614ffd9` is NOT a hidden entry point

A `PUSH4 <4 bytes> EQ` sweep of the implementation bytecode listed `0x5614ffd9` as dispatched on
RockPaperScissors, CoinFlip and the Range impl while appearing in **no** recovered-ABI function.
I read that as a hidden/unlisted entry point — plausibly the refund-commit path. **That read was wrong.**

Control that killed it — `eth_call` against the live proxy:

| call | result | meaning |
|---|---|---|
| `Refund()` (known) | revert data `0x49050b30` | real custom error |
| `REFUND_COMMIT_WAIT_BLOCKS()` | returns `20` | real getter |
| `GetState(player)` | returns 6 words | real getter |
| **`0x5614ffd9`** | revert data `0x` (empty) | — |
| `0xdeadbeef` (bogus) | revert data `0x` (empty) | no such selector |
| `0x12345678` (bogus) | revert data `0x` (empty) | no such selector |

`0x5614ffd9` is **indistinguishable from two deliberately bogus selectors**. The `63…14` pattern also
matches an ordinary data constant followed by `EQ`, so the sweep carries false positives. The 22/23
hand-match rate was the thing that made it look trustworthy — a detector can be right 22 times and
still lie on the 23rd. **Rule: a selector sweep proposes candidates; only a live `eth_call` (real
decoded return, or a custom error that decodes against the ABI) confirms one.** Nothing is a "hidden
entry point" until it answers.

Everything else the sweep produced IS calibrated — the impl ABIs are strict subsets of the recovered
ABI plus that one false positive:

- **RPS impl** `0x8d202640…`: 23 dispatched — `RockPaperScissors_Play/Refund/GetState`,
  `_entropyCallback(uint64,address,bytes32)`, `entropy()`, plus the shared UUPS/owner/config tail
  (`initialize`, `upgradeTo`, `upgradeToAndCall`, `proxiableUUID`, `setEdgeFactor`, `setRiskCap`,
  `setWagerNumber`, `setWhiteList`, `edgeFactor`, `riskCap`, `wagerNumber`, `whiteList`).
- **CoinFlip impl** `0xbe4d58428…`: same 23, same shape, one game.
- **`0x0B1E533e…` is NOT a "config base" — it is the Range game** (impl `0xdba35808…`: 11342 bytes;
  carries `Range_Play(uint256,uint32,address,bool,uint32)`, `Range_Refund()`, `Range_GetState`,
  `_entropyCallback`) *plus* the shared base. The recon address map's label was wrong: the Range
  events we saw on that address were the range game playing, not a config contract emitting.
- **BankRoll impl**: 37 dispatched, 23 matched, 14 unlisted — consistent with an ERC-20/share pool
  carrying standard token surface the frontend never calls.

## 9. NEW: `REFUND_COMMIT_WAIT_BLOCKS`-style config is PER-GAME, not global (README correction)

The recon note recorded a single `riskCap() = 275 → 2.75%`. That was read from one proxy. Live, per game:

| game | riskCap | | game | riskCap |
|---|---|---|---|---|
| RockPaperScissors | **10000** | | Limbo | 1460 |
| Plinko | **10000** | | Slots | 1000 |
| CoinFlip | 5000 | | Roulette | 3334 |
| Range | 275 | | Mines | 270 |

Every proxy agrees on `edgeFactor = 9500`, `wagerNumber = 20`, `REFUND_COMMIT_WAIT_BLOCKS = 20`,
`REFUND_TIMEOUT_BLOCKS = 2000`, `getRandomFee = 1.4e18`. Only `riskCap` varies per game — so the
global-config reading was wrong and there is **no config drift** between recon and now (I checked for
drift first, because a 275→10000 jump in a day would have been a finding; it is not one).
`riskCap = 10000` on RPS and Plinko (vs 270/275 on Mines/Range) is a **per-game risk parameter worth
understanding** — what it caps is still unknown, and 100% vs 2.7% is a 37× difference between games.

## 10. NEW: the refund path's first guard is identified

`X_Refund()` called with no pending request reverts with the **ABI-decoded custom error
`NotAwaitingVRF()`** (`0x49050b30`). So the first check in the refund path is *"does the caller have a
request in flight"* — not "is there a commitment" and not maturity. Consequences for the hypothesis:

- A player **cannot create a commitment while idle** — the commit is gated on a live pending request.
  That removes the simplest "pre-mature a commitment, then go betting" route.
- The surviving shape is therefore narrower and more specific: **a matured commitment that outlives
  the request it was created for and is then reused against a later request.** For that to work, the
  claim path must (a) not bind the commitment to the requestID it was created under, and (b) not clear
  the commitment when that request settles.
- Those two questions are the whole target now, and they are **bytecode facts, not log facts.**
