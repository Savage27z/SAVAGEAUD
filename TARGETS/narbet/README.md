# nar.bet — Monad casino, Pyth Entropy (TARGET, recon stage)

**Chain:** Monad mainnet, chainId **143** (`0x8f`), RPC `https://rpc.monad.xyz`
**App:** https://nar.bet — "The Fairest Crypto Casino on Monad"
**Date opened:** 2026-09-12
**Status:** ⏳ Recon complete — black-box ABI recovered; audit starting

## Why this target

Found via the post-death.fun sweep for "gambling sites like this" (DefiLlama Gaming/Prediction
Market/Yield Lottery across our 8 RPC chains → 113 candidates → filtered; Alchemy's dapp index
supplied the live URL). Chosen because it is the closest structural sibling to death.fun that is
**not** a sports book: 19 casino games, on-chain settlement, an explicit fairness mechanism.

## Game contract map (on-chain, resolved)

Ten 209-byte ERC-1967 **game** proxies, each with its own unique implementation. Every one of them
implements `getRandomFee()`, `edgeFactor()`, `REFUND_COMMIT_WAIT_BLOCKS()` and `entropy()` — i.e.
each game is separately upgradeable and separately wired to Entropy.

| Game | Proxy | Implementation |
|---|---|---|
| **Mines** | `0x3014d056Db789984552084Db359D7C56A620549b` | `0x116ad93f4dcb9c1d7c2c7214cccb50118ab0d196` |
| **CoinFlip** | `0xb82360d08784f0Ff24A740ADaD6b1AC2391C8D57` | `0xbe4d58428ae13e0b8edbab92e7994e4c7f0073ee` |
| **Roulette** | `0x4A050DD00c08856cc3d7C5BD152E4e601ffDaa35` | `0xe976fbe7210878c203f1770b44bf15bf7edf399a` |
| **Plinko** | `0x5859E2926750F3981f95bbA16b86d8e69cf4334B` | `0x3eba1cecfc04f74b831e9a8e695f741649990be5` |
| **Slots** | `0xd6F08aF222C8aa69F99B6099F93C6d96897d378f` | `0x10e7375ed7c77ea3b7328beb0852ef69e95d53b7` |
| **Limbo** | `0xb9e0b5447B92eb5CF246693F7b533d5c84AA8dC5` | `0x69aaec5a6edd0ce0533c08d749e7d25b781a5a62` |
| **VideoPoker** | `0xb86A1955E96147665d7bdd70E50bD6Af38E086d1` | `0x016ad1852ca89181c45e543f42570cad8b0f4d80` |
| **RockPaperScissors** | `0x843D62ad75F5d0b383f8520e23d19174b7961b8E` | `0x8d2026407da5324bf955ba7f21962816cb477bfc` |
| **Baccarat** | `0x8261A173DC96e206b8D8621ca1231a3E7bcB851E` | `0x862f403a4c0fd667e868b12ca085e18133d72e0a` |
| **FishPrawnCrab** | `0xbbE3FA39912355C49Aa3ccdD02C51d989Fb33E79` | `0x03f6c356978c57cd577d465a6b7821ee4abeb02c` |

**Roles of the other proxies:** `0x71dc4a72…` = **BankRoll** (`getIsGame`, `tokenTotalShares`,
`owner`) · `0x0B1E533e…` = shared **config/Entropy base** (`edgeFactor`, `REFUND_*`, `entropy`,
`bankroll`) · the three 149-byte proxies (`0xE6d461…` root, `0xa4338e…` registry, `0x314582…`
resolver) implement **only** `owner()`.

## Config read live (all free, read-only)

```
edgeFactor()                 = 9500        -> 5.00% house edge (global)
riskCap()                    = 275         -> 2.75%
wagerNumber()                = 20
REFUND_COMMIT_WAIT_BLOCKS()  = 20 blocks
REFUND_TIMEOUT_BLOCKS()      = 2000 blocks
getRandomFee()               = 1.4e18      (Entropy request fee, wei)
entropy()                    = 0xd458261e832415cfd3bae5e416fdf3230ce6f134   (Pyth Entropy on Monad)
bankroll()                   = 0x71dc4a726c92e6bf506f2afc2cee8b63a89b29ec   (BankRoll)
BankRoll owner/getOwner      = 0x4ad0d8f0a100a74547e4b66c008cae6e91ef6d8b
BankRoll getFeeInfo()        = (0x4ad0d8f0…, 1000)   -> 10% of something to the owner
root/registry/resolver owner = 0xb34f876ccf1d422bdc5a52aa83a96afe251faf68   <- DIFFERENT owner
```

**Two distinct owners** (`0x4ad0d8f0…` on BankRoll/games, `0xb34f876c…` on the small proxies) is a
trust-model fact worth resolving — and a second-hand control risk if the two are independent keys.

## ⚠️ Second calibration failure this session (both were silent-wrong, worth recording)

I wrote a "free existence oracle" (implemented ⇒ custom-error revert, absent ⇒ empty revert) and the
first version reported **every selector as implemented on every proxy**. Cause: it tested
`"data" in error_json`, but every revert payload has a `data` key — usually the empty string `"0x"`.
Right rule: **empty `"0x"` revert data ⇒ selector ABSENT** (that is exactly what a proxy fallback
returns when the implementation lacks it); **≥4 bytes of revert data ⇒ the custom error decoded, so
the selector IS implemented.** After the fix the oracle immediately separated the ten games.
Same class of mistake as the HTML "unverified" grep: a detector whose parse rule cannot distinguish
the two outcomes returns confident nonsense. **Both were caught only because each had a control.**

## Trust model (TMAAR — first pass)

| Actor | Capability | Risk |
|---|---|---|
| **Owner** (UUPS) | `upgradeTo`/`upgradeToAndCall`, all setters, `suspend`/`liftSuspension`/`permantlyBan` | Total control. No timelock observed yet. |
| **Manager** (whitelisted) | `setWhiteList`-granted; `Mines_SetMultipliers`, `VideoPoker_*` fee events | Needs enumeration on-chain |
| **Player** | `*_Play` (payable), `*_Refund`, `Mines_Reveal`, `VideoPoker_Replace` | The adversary in every hypothesis below |
| **LPs** | `deposit`/`withdraw` into the BankRoll share pool | Counterparty to player wins |
| **Pyth Entropy** | `_entropyCallback` provider | Assumed honest (verified provider) |

**Accepted-by-design risks to record, not report:** owner can upgrade; owner can suspend players;
house edge exists and is not a bug.

## Architecture (recovered from the bundle + on-chain)

- **19 games**, each exposing `X_Play(...) payable`, `X_Refund()`, `X_GetState(address) -> tuple`,
  and an `X_Outcome_Event(..., uint64 sequenceNumber)`.
  Games: Baccarat, CoinFlip, Crash, Dice, DragonTiger, FishPrawnCrab, HiLo, Keno, Limbo, Mines,
  Plinko, Range, RockPaperScissors, Roulette, SicBo, Slots, VideoPoker, War, WheelOfFortune.
- **Randomness: Pyth Entropy V2.** ABI contains `entropy() -> contract IEntropyV2`,
  `getRandomFee() -> uint256`, `_entropyCallback(uint64 sequence, address provider, bytes32
  randomNumber)`. Every outcome event carries the Entropy `sequenceNumber`.
- **BankRoll**: share-based liquidity pool (`userShares`, `tokenTotalShares`, `houseLiquidityList`,
  `deposit`, `withdraw`, `transferPayout`, `calculatedIncome`, `tokenTotalShares`), ERC-20-shaped.
- **UUPS upgradeable**: `proxiableUUID`, `upgradeTo`, `upgradeToAndCall`, `initialize(_bankroll,
  _entropy)`, `Initialized`/`Upgraded`/`AdminChanged`/`BeaconUpgraded` events.
- **15 implementations behind ERC-1967 proxies** on-chain: 10 game contracts (one game each) + the
  BankRoll + the shared config/Entropy base + 3 minimal `owner()`-only proxies (see map below).

## On-chain footprint (Monad 143)

| Address | Role | Code size |
|---|---|---|
| `0x71dc4a726C92E6bf506F2Afc2Cee8B63A89B29EC` | ERC-1967 proxy → impl `0xf53441ef835df1106198038ef71d8459f389ec15` | 2739 B |
| `0x0B1E533e33f9E82849E71fb5c0a33F38462D5eD4` | ERC-1967 proxy → impl `0xdba35808de5e89e5e0ca28605d7d3f0292579404` | 209 B |
| `0xE6d461c863987F2a1096eA3476137F30f75B3d46` | ERC-1967 minimal proxy → impl `0x97526a253dcae184cbab869f16004765693ff1f7` (bundle: `rootContractAddress`) | 149 B |
| `0xa4338eadf4D2e0851eFb225b0Eab90bE47A095F1` | ERC-1967 minimal proxy → impl `0xa3d8c3eea65bbd40d25191476b32c7f656f60519` (bundle: `registryContractAddress`) | 149 B |
| `0x314582158A0a72802aD8F6EeE6243C73dCf1F562` | ERC-1967 minimal proxy → impl `0xc3274962e9d165b0d332701afaed52078942344c` | 149 B |

Every proxy's implementation slot was read directly (`0x360894a13ba1a3210667c828492db98dca3e2
076cc3735a920a3ca505d382bbc`). **All five point to different implementations.**

## Source verification — UNCONFIRMED (stated precisely)

- `api.monadscan.com` JSON API returns 404 for *everything*, including WMON and USDC Monad — an
  uncalibrated negative, so it proved nothing either way.
- The HTML fallback (`grep -i unverified` on `monadscan.com/address/<a>`) **failed its own negative
  control**: a random nonexistent address rendered as "verified". A detector that cannot answer
  correctly on a known-bad input cannot certify anything, so its signal on nar.bet is void.

**Consequence:** treat as **no verified source**. This caps classic source review but NOT this
audit — the shipped bundle contains **full JSON ABIs** (130 functions / 80 events / 57 errors), and
all bytecode is on-chain. Reachability and interface-level analysis are fully available; only
implementation internals require bytecode work.

## Top hypotheses (ranked, to be tested)

1. **Refund-after-reveal (the Entropy race).** There is an explicit anti-abort design —
   `REFUND_COMMIT_WAIT_BLOCKS()`, `REFUND_TIMEOUT_BLOCKS()`, `RefundCommitmentCreated(player,
   requestID, claimableBlock)`, `RefundTooEarly(have,want)`, `RefundClaimPending`. The question is
   whether Entropy fulfillment latency can beat `claimableBlock`: if the random number lands inside
   the wait window, a player who can refund **after seeing the outcome** can re-play and never
   accept a loss. Measure the two clocks on-chain.
2. **Refund × settlement ordering.** `NotAwaitingVRF(requestID)` / `AwaitingVRF(requestID)` /
   `NoRequestPending` imply a request-pending state machine. If `_entropyCallback` does not settle
   atomically, is there a window where a refund and a settle both succeed (or neither, stranding
   funds)?
3. **`permantlyBan()`/`suspend()` × in-flight funds.** An operator can ban a player. If a banned
   player cannot `*_Refund` or complete a `Mines`/`VideoPoker` multi-step game, funds are locked —
   the highest-severity family in the Shieldify corpus (`funds_locked_dos`, 20% severe).
4. **Multi-step games (Mines, VideoPoker).** `Mines_Start` → `Mines_Reveal(bool[25])` →
   `Mines_End`; `VideoPoker_Start` → `VideoPoker_Replace(bool[5])`. Guards to attack:
   `TileAlreadyRevealed` (can a tile be revealed twice?), `InvalidNumberToReveal(_, maxAllowed)`
   (bound correct?), `MinNumberToReveal`, `Mines_SetMultipliers` (can multipliers change mid-game?).
5. **BankRoll share accounting.** `userShares`/`tokenTotalShares`/`houseLiquidityList` — first-
   depositor share inflation and `calculatedIncome` rounding are the exact `share_inflation_4626`
   and `rounding_precision` families (27% severe in the corpus).
6. **Client-supplied state.** `HiLo_Play(..., uint8 currentCard, ...)` and `Mines_Reveal(bool[25])`
   are client inputs; `InvalidCurrentCard` exists, so validation is intended — verify it holds.
7. **Client-side house edges** (client bundle): CoinFlip 1 · Dice/Range 1 · Mines 1 · Slots 2.056 ·
   Plinko 2.074 · RockPaperScissors 2.056 · VideoPoker 0.5555 · Baccarat "" (empty).
   Compare against on-chain `edgeFactor()` — a client/contract mismatch is the exact
   verifier-constant-drift bug found in death.fun (F03 §5) and a 25%-severe family in the corpus.

## ⚠️ Pitfall recorded (cost real time, and I nearly mis-concluded twice)

`entropy` in a **Privy**-based bundle is **doubly loaded**. Privy's embedded-wallet fields are
`entropyId` / `entropyIdVerifier`; Pyth's randomness contract is also `entropy`. A keyword grep for
"Entropy" hit **Privy** first and I briefly concluded the Pyth inference was wrong. It was right —
but only provable from a different signal: the ABI's **`internalType": "contract IEntropyV2"`** and
`_entropyCallback(uint64,address,bytes32)`.
**Rule: for a randomness-provider claim, resolve it from the typed ABI (`internalType` / the
callback signature), never from a keyword count.** Also: a `head`-terminated pipe SIGPIPEs a Python
extractor mid-run and silently loses the save — redirect to a file instead.

## Artifacts

```
TARGETS/narbet/recon/
  extract_abi.py       first attempt (too strict, 0 hits — kept for provenance)
  extract_abi2.py      bracket-matching ABI extractor (65 ABI arrays -> 130 fns)
  abi-real.json        the recovered interface: functions, events, errors
  abi-report.txt       full human-readable dump
```

## Next steps

1. On-chain `owner()`, proxy admin, and whether a timelock sits behind upgrades (hypothesis 0)
2. Read `REFUND_COMMIT_WAIT_BLOCKS()` / `REFUND_TIMEOUT_BLOCKS()` / `getRandomFee()` / `edgeFactor()`
   — four free reads that either kill or sharpen hypotheses 1, 2, 7
3. Reconcile settled games from `X_Outcome_Event` logs against the documented house edge
4. Only then: any state-changing test, and only against a local fork or mock
