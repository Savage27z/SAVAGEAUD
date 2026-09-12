# OLY / OlympusX — Pashov Audit Group team review: 66 findings, mined for patterns (Dec 2025 – Jan 2026)

**Lesson:** a public audit report with *sixty-six* findings on one codebase is worth more
than sixty-six isolated bugs — it is a **map of where a protocol's seams are**. Almost every
finding here is one of ~12 recurring shapes, and the shapes are the same ones that produce
live exploits. Read the report for the shapes, not the bugs: the bug is patched, the shape
is not. **The single highest-yield habit this report teaches: whenever two code branches do
"the same thing" for two different assets, or whenever a value is *derived* from a config,
or whenever an amount is *guessed* instead of *measured* — assume they disagree, and go
prove it.**

---

## What this is

- **Report:** Pashov Audit Group, "OLY / OlympusX Security Review", 85 pages, engagement
  2025-12-31 → 2026-01-20. 5 Critical / 9 High / 25 Medium / 27 Low = **66 findings**.
- **Codebase:** large DeFi protocol — Uniswap **V4 hook** limit orders, a taxed OLY token
  with a TaxRouter, a genesis/vesting LaunchManager, an auction, a staking vault with
  multi-cycle (8/28/90/369/888-day) rewards, and a **Lido** validator vault (stETH/wstETH).
- **Status:** all findings reported as Resolved except M-16, M-18, L-03, L-04
  (Acknowledged) — the project fixed the severe ones and booked a follow-up.
- **Tweets/public URL:** https://x.com/PashovAuditGrp/status/2098444143110332754
- **PDF:** https://github.com/pashov/audits/blob/master/team/pdf/OLY-security-review_2025-12-31.pdf
  (raw: `https://raw.githubusercontent.com/pashov/audits/master/team/pdf/OLY-security-review_2025-12-31.pdf`,
  1.4 MB, 85 pages — extract with pymupdf, text = 155,849 chars)

**Where the findings cluster (mention count):** StakingVault 14 · FarmKeeper 12 ·
OlympusXHook 9 · ValidatorVault 8 · LaunchManager 8 · SwapActions 5 · FarmKeeperV4Lib 3 ·
OlympusXAuction 3 · EthPrice 3 · TaxRouter 1 · OlympusX 1.
The two clusters — **reward accounting** and **V4 liquidity management** — carry nearly half
the report. That is where the seams are.

---

## The 12 shapes (root-cause families)

### F1 — The contract's own balance is used as a fallback amount (earmarked funds get spent)
**Findings:** C-01.
`_distributeEthInternal` does `total = msg.value > 0 ? msg.value : address(this).balance`.
The `else` branch means a **permissionless** call with zero value redistributes *whatever the
router is holding* — including the genesis team's earmarked `userToEth` pot — to stakers,
validators and farms. Anyone can steal genesis' balance by calling a public function with
`value = 0`.
**Abstract class:** a contract that keeps *earmarked* balances (per-user ledgers) *and* has a
path that treats `address(this).balance` as "unallocated surplus". The two views of the same
ETH disagree; the surplus path sweeps the ledger.
**Detection:** grep every `address(this).balance` / `IERC20.balanceOf(address(this))` used as
an *amount to move*, then check whether the contract also tracks per-user credited amounts
for that same token. If yes: can a caller reach that path with an empty input?

### F2 — ETH↔WETH (or wrap/unwrap) asymmetry inside a multi-step flow
**Findings:** H-01, C-02, C-03.
- H-01: leftover **WETH** from a V3 swap is written back into `nativeBalance` without being
  unwrapped → the next farm treats wrapped ETH as native and pays out with native.
- C-02: "amount of native ETH used" for a V4 position is inferred from a sweep of the
  remainder, not measured — underflow when the sweep returns more than expected.
- C-03: the next `tokenId` is *cached* on the farm even when the computed liquidity is `0`
  and no mint happens → later accounting believes a position exists that doesn't.
**Abstract class:** a flow converts A→B→A for operational reasons, and the code assumes the
round trip is lossless and total. It is never both.
**Detection:** for every wrap/unwrap or deposit/withdraw pair inside one transaction, ask
"what form is this value in when it lands in the *next* step's variable, and does that step
know it?" Also: prefer a **measured** delta (balance before/after the external call) over a
*requested* amount — and if you do measure, handle the sweep returning extra.

### F3 — Derived state (IDs, caches) not invalidated when its source config changes
**Findings:** C-04, L-16, M-12.
- C-04: `setIntermediaryConfiguration()` updates the pool **key** but not the derived
  `poolId` → swaps route to the old pool. Admin action silently bricks the farm.
- L-16: setter accepts a `poolKey` with no check the pool exists (siblings `enableV3Farm`
  do check — the asymmetry is the tell).
- M-12: V4 uses `address(0)` to mean ETH in `currency0`, but validation looks the token up in
  an `isWethToken` map that can never contain `address(0)` → the reward-token check silently
  passes for the wrong token.
**Abstract class:** config → derived value, where the derived value is stored and the config
is mutable. Also: **sentinel values** (`address(0)`) that bypass membership checks.
**Detection:** for every setter, list every state variable derived from it and ask "is it
recomputed?" For every allowlist/mapping check, ask "what value can never be in this map, and
does the code accept it anyway?"

### F4 — Rebasing / share-vs-amount confusion (Lido stETH family)
**Findings:** C-05, L-07, L-11, L-27, M-19.
- C-05: `stETH.submit()` returns **shares minted, not stETH amount**. Treating it as the
  amount causes systematic *under-wrapping* to wstETH → broken accounting and reward math.
  This is a Critical from misreading one function's return-value semantics.
- L-07: floor rounding in `wrap()` means a small stake mints **zero** wstETH while ETH is
  really staked — external effect, no internal record.
- L-11 / L-27: assumes a wstETH/stETH feed exists on mainnet and that stETH is 1:1 with ETH
  — a depeg breaks every valuation.
- M-19: `emergencyWithdrawWstEth()` ignores the `pendingEth` bucket → funds stranded after
  the emergency the function exists for.
**Abstract class:** yield-bearing / rebasing tokens have **two numbers** (shares, assets) and
a conversion that is not 1:1 and not constant. Every use site must say which one it means.
**Detection:** for any LST/LRT/aToken/4626-share token, enumerate **every** call site and
label it `shares` or `assets`; then check the conversion direction and rounding. Separately:
grep for hardcoded pegs (`== ETH`, `1e18`) on any non-ETH asset. Read the return-value
docstring of every external call you consume — `submit()` vs `wrap()` differ.

### F5 — Lifecycle / partial-fill logic: "filled" flags, early exits, and fees left behind
**Findings:** H-03, M-08, M-09, M-23, L-05.
- H-03: limit orders are marked **fully filled** by comparing previous vs current tick and
  treating any crossed range as complete — a swap that only touches the boundary fills the
  whole order. No partial fills exist at all.
- M-08 / M-09: fees accrue to a tick range, not to the *participant*; a partial fill leaves
  fees that the **next** user to join the same tick can harvest ("subsidized liquidity").
- M-23: if every participant `kill()`s before an epoch is filled, epoch stays `!filled`,
  `withdraw()` is gated by `NotFilled()` → **LP fees permanently locked**.
- L-05: `mint()` hard-`require`s the remainder fits → no partial fill → griefable by front-run.
**Abstract class:** a state machine with a boolean terminal flag and a fee accumulator that
lives on the *container* (the range, the pool, the epoch) rather than the *participant*.
Any exit path that skips the flag leaves value behind.
**Detection:** for every `filled` / `settled` / `active` boolean, enumerate every transition
*out* of that state and check what happens to accumulated value. For every fee accumulator,
ask: who can join after fees exist, and can the range be exited before it's terminal?

### F6 — Spot price used where a TWAP is claimed; TWAP config unvalidated
**Findings:** H-06, M-04, L-04, L-17, L-26, L-22, M-05.
- H-06: `addLiquidity()` sizes the position off `getSlot0()` **spot** → sandwich: attacker
  moves price immediately before the add and extracts the difference.
- L-17 / L-26: TWAP period settable to `0`/absurd, and **observation cardinality** not
  checked — when the pool can't serve the period, the oracle **silently falls back to
  manipulable spot** (that's the real bug, not the bad config value).
- M-04 / L-04: no **deviation** check and a manipulable Uniswap-pool *fallback* when
  Chainlink is stale/abnormal — the fallback misprices ETH in USD.
- L-22: assumes Chainlink feed **decimals ≤ 18**, unenforced.
**Abstract class:** price reads treated as facts. A price is only as good as its (a) source,
(b) freshness, (c) deviation bound, (d) decimals, (e) manipulation cost.
**Detection:** grep `slot0`, `getSlot0`, `sqrtPriceX96`, `observe`, `latestRoundData`. For
each: is this a *decision* input (amounts, liquidations, mint/burn) or informational? If
decisional, demand TWAP + cardinality check + staleness + decimals + deviation. Any
"fallback to spot" branch is a Critical waiting to happen.

### F7 — Unit / scale asymmetry between two branches or two assets
**Findings:** H-04, H-07, M-20, L-20, H-08.
- H-07: `swapAmount` is `balance * 1e6` in the token1→token0 branch and **unscaled** in the
  other → in one direction the swap is **~1e6× too small** and rebalancing silently no-ops.
- H-04: picks which token to swap with `currency0Balance > currency1Balance` — raw wei,
  meaningless across different decimals.
- L-20: sums reward amounts **across tokens with different decimals** into one
  `totalClaimed` → the number is meaningless and stored.
- H-08: different tax formula for exact-input vs exact-output swaps → users route around the
  tax via exact-output, defeating the tax mechanism.
**Abstract class:** the same intent implemented twice (two branches, two tokens, two swap
modes) with a difference that only shows at scale. Uniform-looking code hides it.
**Detection:** for every `if (direction) {...} else {...}` that computes an *amount*, diff
the two branches symbol by symbol — same scaling? same rounding? same fee? Same for any place
two **different tokens'** raw amounts are compared, added, or summed. Given a fee formula,
check **every** swap variant (exactIn/exactOut, buy/sell) applies the same effective rate.

### F8 — Reward-accrual accounting: precision, "zero means uninitialized", cycle attribution
**Findings:** M-01, M-02, M-06, M-11, M-14, M-16, M-17, M-22, L-09, L-10, L-18, L-19, M-07.
This is the **largest family (13 findings)** and the one most likely to appear on any target
with a staking vault.
- M-01: `tokenReward * PRECISION` **underflows** when `_globalActiveShares` is large and the
  reward is small → reward loss. Precision must exceed the divisor's magnitude range.
- M-06: `totalInflationDistributed` (allocated, not minted) vs `totalInflationMinted` — a
  timing gap between stake-end and claim lets **more inflation out than `maxInflationPool`**.
- M-14: `userRewardDebt == 0` is used as the "uninitialized" sentinel → after
  remove→re-add of a reward token, a user whose debt is *legitimately* 0 **loses rewards**.
- M-17: `totalSupply` changes with **no stake event** (mint/burn) → the inflation formula
  computes on a supply the accounting never snapshotted.
- M-22: a permanent `deadStake` of 1000 shares keeps `_totalShares != 0` forever → the
  "no real stakers, accrue nothing" guard **never fires**, and the dead stake absorbs
  inflation share.
- M-16: five cycle lengths, but eligibility isn't restricted by stake duration → short-term
  stakers claim long-term (less frequent, more valuable) cycles. **Acknowledged, not fixed.**
- L-09: catch-up is `nextCyclePayoutDay += cycleLength` → one cycle per call, so an overdue
  schedule needs many transactions to reach now.
- L-10: the emitted `ethReward` depends on **token array ordering** (pre-scan breaks early).
- L-18 / L-19: rewards locked when `totalShares == 0` at removal; rounding **dust**
  (`amount * PRECISION / totalShares`) left in the contract, pool balance zeroed anyway.
- M-07: auction tokens permanently locked if a cycle gets **no deposit** (`totalReservedTokens`
  lifecycle).
- M-02 / M-11: share-rate multiplier applied mid-stake changes value under the user; a
  day-based maturity calc compounds rounding to let a stake end **almost a day early**.
**Abstract class:** "earned" is a *derived* quantity from (shares × time × rate), and every
simplification — a sentinel, a cached supply, a boolean guard, a rounding floor, an array
order — is a place where the derivation silently breaks.
**Detection (run this list on any vault):**
1. `totalShares == 0` guards: is the value *provably* reachable? (a dead/minimum stake makes
   it unreachable — that's a bug, not a safety net).
2. Every `== 0` used as "uninitialized": can 0 be legitimate?
3. `x * PRECISION / y`: bounds on `y` vs `x` → under/overflow.
4. Rounding down: where does the dust go, and is the pool zeroed anyway?
5. Attribution: does the claim path filter by the *stake's* duration/cycle eligibility, or
   just by what's available?
6. Catch-up loops that advance by one step per tx.
7. Emissions accounting: is "allocated" tracked separately from "minted", and can a claim
   fall between them?
8. Events computed from a pre-scan that can break early.

### F9 — Push-vs-pull payment, blacklistable tokens, and external protocol limits
**Findings:** M-03, M-10, M-15, L-06, M-07, M-23.
- M-03: rewards are **pushed** as ERC20 during stake *and* unstake → a user blacklisted by
  USDC **cannot open or close a stake at all**. The payout mechanism is a lockout mechanism.
- M-10: `_prepareWithdrawalAmounts()` combines a remainder with a full request → exceeds
  Lido's `MAX_WITHDRAWAL_AMOUNT` (1000 stETH) → **all** withdrawal requests revert.
- L-06: Buy&Burn's 16% share converted below Lido's 100-wei minimum → `harvest()` **reverts**,
  blocking the whole harvest.
- M-15: `place()` keeps excess `msg.value` → trapped in the contract.
**Abstract class:** an outbound transfer that *must* succeed is treated as a statement that
*will* succeed. Real tokens blacklist; real external protocols have min and max amounts.
**Detection:** for every outbound `transfer`/`call{value:}`, ask: can this revert, and what
does the enclosing function do then? Is there another path to the user's funds? For every
amount sent to an external protocol, check its documented **min and max** bounds (Lido min
100 wei, max 1000 stETH) and whether a computed remainder can land outside. Refund excess
`msg.value` or use exact-amount pulls.

### F10 — Privileged setters miss validation the constructor (or a sibling setter) has
**Findings:** L-15, L-16, L-17, L-26, M-12, M-13, L-22.
Constructor validates the weth address is in the pool; `setPriceConfig()` — the *same*
config, later — validates nothing. `setIntermediaryConfiguration()` checks slippage and
twapPeriod but not pool existence, while `enableV3Farm()` does. `validateFarmSetup()` doesn't
check the intermediary pool's token matches the main pool. Setters accept `twapPeriod = 0`
and a cardinality that can't support the period.
**Abstract class:** validation written at *construction* time and forgotten at *mutation*
time. Also validation written for one sibling path and not copied to the structurally
identical one.
**Detection:** build a table of setters × the invariants the constructor/`enable*` path
establishes, and diff. Any invariant set once and not re-checked on mutation is a finding.
Then ask: for each config value, what is the **minimum/maximum meaningful** value, and is
that enforced?

### F11 — Permissionless entry points gamed by being your own counterparty / growing an array
**Findings:** H-05, L-01, L-12, L-05, L-23, M-15.
- H-05: `claim()` doesn't check the auction has **ended** → the first depositor in an active
  cycle immediately claims the whole distributed amount before others can join.
- L-01: attacker floods a victim's `userStakes` array with dust stakes via
  `mint()` + `startStakeForUser()` → the victim's `unstake` now costs unbounded gas.
- L-12: **self-referral** → one user claims both minter and referrer bonus, draining the pool
  at 2× the intended rate.
- L-23: permissionless `stakeETH(amount)` reverts when `amount > pendingEth` → an attacker
  front-runs with a tiny amount (or a huge one) to make the victim's tx revert.
**Abstract class:** a public function that (a) pays from a shared pool on a condition the
caller controls, (b) writes to a **per-user array** the user didn't authorize, or (c) reverts
on a caller-supplied amount. Free to call ⇒ free to weaponize.
**Detection:** for each permissionless function: can I be both sides? Can I make someone
else's storage grow? Can I cause a revert for a specific victim by racing? Then check
*ordering*: state that must be terminal before payout (auction end, epoch fill) — is that
actually checked, or only implied by the UI?

### F12 — The protocol trading through its own taxed/restricted pool
**Findings:** M-25, H-08, H-02, L-24.
- M-25: rebalancing swaps through the farm's own pooled pair, which carries the OLY sell tax
  — the protocol pays its own tax, and when `taxBps` (18–38%) > `swapSlippage` (10%) the
  rebalance **can never succeed**.
- H-08: tax differs by swap mode (see F7).
- H-02: retry mechanism sets `unusedAmount = amountIn - amountToSwap`, but after **all**
  retries fail the used amount is 0 and unused must be the full `amountIn` → accounting drift.
**Abstract class:** internal operations routed through the same surface as external users,
inheriting fees/limits/hooks that were designed for users.
**Detection:** trace every internal swap/transfer for whether it touches a hook, tax, or fee
tier. Compare the fee/slippage configs of the two sides — if the fee can exceed the slippage,
the path is dead. For retry loops, verify the failure case recomputes *all* amounts.

---

## Checklist additions (feed these into CHECKLIST.md)

1. **Earmarked balance sweep.** Any path that uses `address(this).balance` /
   `token.balanceOf(this)` as the amount to spend, in a contract that also keeps per-user
   credited balances: check for a zero-input / permissionless trigger. (C-01)
2. **Wrap/unwrap round-trip.** In any multi-step flow, name the *form* (native vs wrapped)
   of every value crossing a step boundary. Never infer "amount used" from a requested
   amount; measure the delta — and handle the sweep returning extra. Don't cache derived
   IDs (`tokenId`, `poolId`) when the underlying operation can no-op. (H-01, C-02, C-03)
3. **Config → derived state.** For every setter, list derived state and confirm recompute.
   For every mapping membership check, ask what value can never be a key (`address(0)`) and
   whether the code accepts it anyway. (C-04, M-12, L-15, L-16, L-17, L-26)
4. **Shares vs assets.** On any rebasing/yield-bearing token, label every use site as shares
   or assets, verify the conversion direction, check rounding (can wrap mint 0?), and grep
   for hardcoded pegs. Read the return-value semantics of each external call consumed.
   (C-05, L-07, L-11, L-27, M-19)
5. **Lifecycle terminal flags.** For each `filled`/`settled` boolean, enumerate exits and
   what happens to accumulated value. Attach fees to participants, not containers. Support
   partial fills — or prove the hard-revert can't be griefed. (H-03, M-08, M-09, M-23, L-05)
6. **Price-read decision test.** Is the price used to size an amount, mint, burn or
   liquidate? Then require TWAP + observation-cardinality + staleness + decimals + deviation
   — and treat any "fall back to spot" branch as Critical-class. (H-06, M-04, L-04, L-17,
   L-22, L-26)
7. **Branch-diff the arithmetic.** Two branches computing the same kind of amount must agree
   on scaling, rounding and fees; two tokens' raw amounts must never be compared or summed.
   Check every swap variant gets the same effective tax. (H-04, H-07, H-08, L-20)
8. **Vault reward-accrual gauntlet** (the 8-point list in F8) — run it verbatim on every
   staking/vault/inflation system. (13 findings)
9. **Outbound-transfer failure.** Every transfer must answer: what if the token blacklists
   or the recipient reverts, and is there another exit? Every external protocol call must
   respect its documented min/max (Lido: min 100 wei, max 1000 stETH). Refund excess
   `msg.value`. (M-03, M-10, L-06, M-15)
10. **Setter-vs-constructor invariant diff**, and **permissionless self-dealing probe** (be
    both sides of a bonus; grow someone's array; race to revert a victim). (F10, F11)
11. **Never route internal ops through the user-facing taxed/hooked surface.** Compare fee
    vs slippage configs — if fee > slippage the path is a brick. Retry loops must recompute
    all amounts on total failure. (M-25, H-02, L-24)

---

## Why this transferable

Every one of these shapes appears in the SAVAGEAUD targets and the exploit traces already
filed: F2/F7 are the V4 accounting class (`provenance-state-divergence`, `cosmos-evm-balance-sync`);
F4 is the classic LST depeg family (`moonwell-mamo-oracle` is F6 with a borrow instead of a
mint); F8 is the ve/reward-vault class that keeps surfacing in new launches; F11's "be your
own counterparty" is `pattern-trace-2026-09` Pattern 1 (authz satisfiable from the attacker's
default state) in incentive form. The report is useful precisely because it is *dense*: 66
findings, no novel cryptography, all of it ordinary DeFi arithmetic done slightly wrong —
which is what actually drains protocols.

**Practical note for our own targets:** OLY is a Uniswap-V4-hook + Lido + tax-token stack.
Any target with that shape (V4 hooks, LST vaults, taxed tokens, multi-cycle reward vaults)
should get these 66 as a pre-audit grep list before a single line is read.

## Receipts

- Tweet (public, syndication + fxtwitter verified): https://x.com/PashovAuditGrp/status/2098444143110332754
  — "5 security researchers, 3 full weeks of audit, 66 total vulnerabilities found."
- Report: 85 pages, count table = Critical 5 / High 9 / Medium 25 / Low 27 = 66.
  Findings C-01…C-05, H-01…H-09, M-01…M-25, L-01…L-27. Status: Resolved except
  M-16 / M-18 / L-03 / L-04 (Acknowledged).
- Local artifacts: `~/.hermes/workspace/study/pashov-oly/oly.txt` (full extracted text),
  `findings.json` (per-finding parsed digest), `OLY-security-review.pdf`.

---

## Appendix — all 66 findings (ID / title / status)

- **C-01** Genesis rewards will be stolen — *Resolved*
- **C-02** Underflow during FarmKeeper V4 liquidity minting — *Resolved*
- **C-03** V4 farm tokenId can be cached but not minted — *Resolved*
- **C-04** Intermediary poolId not updated for nonnative farms — *Resolved*
- **C-05** Incorrect handling of stETH shares causes accounting error — *Resolved*
- **H-01** Fail to unwrap WETH in swapV3EthForFarmToken — *Resolved*
- **H-02** Unused amount may be calculated incorrectly — *Resolved*
- **H-03** Limit order incorrectly filled on tick movement — *Resolved*
- **H-04** Inefficient liquidity provision due to decimal-agnostic token — *Resolved*
- **H-05** First depositor can claim all auction tokens before auction — *Resolved*
- **H-06** Liquidity addition vulnerable to sandwich attacks due to spot — *Resolved*
- **H-07** Asymmetric unit scaling in swapAmount calculation breaks — *Resolved*
- **H-08** Exact output swaps incur lower tax than exact input swaps — *Resolved*
- **H-09** Withdraw pays only one token while accounting debits both — *Resolved*
- **M-01** Reward loss due to precision underflow in cycle payouts — *Resolved*
- **M-02** Share rate increase causing staking value loss — *Resolved*
- **M-03** Reward claim pattern issue with blacklisted tokens — *Resolved*
- **M-04** Eth pricing fallback misprices USD value — *Resolved*
- **M-05** Overflow risk in price calculation during V4 pool creation — *Resolved*
- **M-06** Inflation pool accounting gap allows excess distribution — *Resolved*
- **M-07** Tokens permanently locked in accounting if auction receives — *Resolved*
- **M-08** Accrued fees can be exploited to obtain subsidized liquidity — *Resolved*
- **M-09** New limit order participants unfairly receive fees from exited — *Resolved*
- **M-10** Withdrawal requests revert when combined amounts exceed — *Resolved*
- **M-11** Imprecise maturity calculation allows premature stake ending — *Resolved*
- **M-12** Incorrect validation in validateFarmSetup allows non- — *Resolved*
- **M-13** Missing validation allows intermediary pool with wrong token — *Resolved*
- **M-14** Reward debt heuristic can drop rewards after reward token — *Resolved*
- **M-15** Excess ETH not refunded when placing limit orders — *Resolved*
- **M-16** Unequal reward distribution lets short-term stakers access — *Acknowledged*
- **M-17** Inflation reward calculation is not accurate — *Resolved*
- **M-18** Ethereum can be locked if required liquidity is not achieved — *Acknowledged*
- **M-19** Emergency withdrawal fails to recover ETH in pendingEth — *Resolved*
- **M-20** Removed tokens lead to unclaimable rewards causing — *Resolved*
- **M-21** Missing slippage protection in mint function exposes users — *Resolved*
- **M-22** Dead stake violates zero staker invariant and absorbs — *Resolved*
- **M-23** LP fees can be permanently locked in nonfilled epochs after — *Resolved*
- **M-24** Missing collect accrued swap fees in — *Resolved*
- **M-25** Protocol rebalances incur OLY sell tax when swapping via — *Resolved*
- **L-01** Stake position flooding risk — *Resolved*
- **L-02** Ineffective staking allowance management in — *Resolved*
- **L-03** Claimable amount underflow causing stuck token — *Acknowledged*
- **L-04** EthPrice oracle missing price deviation check — *Acknowledged*
- **L-05** Mint transactions vulnerable to griefing via front running due — *Resolved*
- **L-06** ValidatorVault.harvest() reverts on buy and burn — *Resolved*
- **L-07** StakeETH allows ETH to be staked while minting zero — *Resolved*
- **L-08** Unused token allowance after partial swap execution — *Resolved*
- **L-09** Payout schedule advances only one cycle per call when cycles — *Resolved*
- **L-10** CyclePayoutTriggered logs ethReward = 0 due to — *Resolved*
- **L-11** No wstETH/stETH oracle on ETH mainnet — *Resolved*
- **L-12** Self-referral allows users to claim both minter and referrer — *Resolved*
- **L-13** Farm removal fee distribution mismatch with documentation — *Resolved*
- **L-14** Incorrect liquidity removed value in FarmKeeper_Removed — *Resolved*
- **L-15** Constructor does not validate price configuration parameters — *Resolved*
- **L-16** Intermediary pool configuration lacks validation — *Resolved*
- **L-17** Twap period can be set to an invalid value — *Resolved*
- **L-18** Reward tokens become permanently locked when removed — *Resolved*
- **L-19** Rounding dust from reward distribution becomes — *Resolved*
- **L-20** Summed reward claims across different tokens produce — *Resolved*
- **L-21** Inconsistent slippage handling for increase and decrease of — *Resolved*
- **L-22** Implicit assumption on Chainlink price feed decimals in — *Resolved*
- **L-23** StakeETH can be front run with a small amount to disrupt — *Resolved*
- **L-24** Missed slippage protection when users sell OLY — *Resolved*
- **L-25** Mint accounting break with mixed liquidity and vesting — *Resolved*
- **L-26** Insufficient observation cardinality validation in — *Resolved*
- **L-27** ValidatorVault assumes stETH is pegged 1 to 1 with ETH — *Resolved*

Severity counts: Critical 5 · High 9 · Medium 25 · Low 27 = **66**.