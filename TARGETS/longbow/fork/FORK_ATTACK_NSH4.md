# Longbow — NSH-4 fork attack + S9 curator-powers enumeration

**Fork:** anvil, Robinhood Chain (4663), pinned at **block 64,972,513**.
**Vault under test:** MetaMorphoV1_1 `0x8cb8AA35228c96C1C4E956E69AbAEBCc2aA7Dcfe`
(`totalAssets` = 8.022515 USDG at the pin; the bulk of the $48.5K sits in the sibling vault
`0x93777a9b917be3c8259c84456222f43a01dd6492`).
**Scripts:** `attack_nsh4.sh`, `attack_nsh4_part2.sh`
**Source read:** `source/vault.sol` (MetaMorphoV1_1, verified, solc v0.8.26, 950 lines)

---

## S9 — which curator/owner powers are INSTANT vs TIMELOCKED

Read from source, then **proven on the fork** rather than asserted.

### Role holders (fork)
| Role | Holder | Kind |
|---|---|---|
| `owner()` | `0x1bf704707e9F3f407EbC9364fDAeD08C39893770` | **bare EOA — `eth_getCode` = 0 bytes** |
| `curator()` | `0x1bf704707e9F3f407EbC9364fDAeD08C39893770` | **same address as owner** |
| `guardian()` | `0x67f79ccc109667CEBd25a1E2F8C365345EB3e918` | separate |
| `feeRecipient()` | `0xA4C8E4ed1d6a85b68032F4B921b20a664Ea36413` | |
| `skimRecipient()` | `0x9573D31ed1B0fA47D47FdD44b1CAFEF8Fd253f71` | |
| `timelock()` | `86400` (24h) | |

**One bare EOA is both owner and curator.**

### INSTANT — `onlyOwner`, no timelock
Source: `setName`, `setSymbol`, **`setCurator`**, **`setIsAllocator`**, `setSkimRecipient`,
**`setFee`**, **`setFeeRecipient`**.

Fork-proven:
- **`setCurator(0xA11CE)` → `status 1` (success).** `curator()` immediately read back as the
  attacker. Role takeover is instant, no warning window.
- **`setFee(0.5e18)` → `status 1` (success).** Proven ceiling: 0.60 / 0.75 / 0.90 / 1.00e18
  **all revert `MaxFeeExceeded`** ⇒ `MAX_FEE` is exactly **50%**, and it is reachable in one
  un-timelocked call.

### INSTANT — `onlyAllocatorRole` (= allocator ∨ curator ∨ owner)
`setSupplyQueue`, `updateWithdrawQueue`, `reallocate`.

Fork-proven:
- **`setSupplyQueue([marketIdx2])` → `status 1` (success).** `supplyQueueLength` went
  **28 → 1**: the curator collapsed the deposit routing of the entire vault to a single market
  in one call, no timelock.
- `reallocate` **passed authorization** as the attacker-curator (it reached Morpho's
  `transferFrom`, i.e. the `onlyAllocatorRole` gate was satisfied) and failed only on
  liquidity, not permission.

### TIMELOCKED — submit → wait 24h → accept
`submitTimelock`/`acceptTimelock`, `submitGuardian`/`acceptGuardian`,
**`submitCap`/`acceptCap`**, `submitMarketRemoval` (+ `revokePending*` by guardian).

Fork-proven, and this is the load-bearing defence:
- `submitCap(market2, 999999999999)` → `status 1` (accepted as pending).
- `acceptCap(market2)` **immediately after** → **REVERTED with custom error `0x6677a596`**.
  Selector computed locally: **`0x6677a596` = `TimelockNotElapsed()`**.
- After `evm_increaseTime 90000` + mine → **`acceptCap` SUCCEEDED**.
  ⇒ **time is the only barrier**, and it is exactly the 24h `timelock()`.

### INSTANT by design (correct direction)
`submitCap` branches: `newSupplyCap < supplyCap` calls `_setCap` **directly** (instant),
`>` goes through `pendingCap` + timelock. Reducing exposure instantly is deliberate and safe.

---

## NSH-4 — "the single-EOA curator moves vault funds into a hostile/malicious market"

**Result: BLOCKED on the new-market path. Not outsider-reachable. Residual = owner-key trust.**

### The barrier that holds
A hostile *new* market requires `submitCap` → **24h** → `acceptCap`, and the separate
`guardian` can `revokePendingCap` inside that window. Proven above: the immediate
`acceptCap` reverts `TimelockNotElapsed()`.

### Two things that weaken it (worth recording, not exploitable today)
1. **The 24h timelock gives a false sense of protection.** Everything needed to take over the
   vault is instant and *not* vetoable by the guardian: `setCurator` (become curator),
   `setFee` (to 50%), `setSupplyQueue` (collapse routing to one market). Only cap *increases*
   and market *removals* wait. A compromised owner key therefore has immediate control of
   roles, fee and routing; the timelock only delays the addition of a new market.
2. **The withdraw queue is already saturated.** `withdrawQueueLength` = **30** =
   MetaMorpho's `MAX_QUEUE_LENGTH`, and **all 30 markets have non-zero caps / `enabled = 1`**.
   `_setCap` pushes a newly-enabled market and reverts `MaxQueueLengthExceeded` past the
   limit, so *no* new market can be added at all until one is removed
   (`updateWithdrawQueue`, which requires that market's cap = 0 and, if it has supply,
   `removableAt` elapsed). This further narrows the hostile-market path, and is a liveness
   note for the curator.

### Why there is no outsider path
Every power used above requires `owner`/`curator`/`allocator` — there is no unauthenticated
route. All 30 markets are already enabled and capped, so the attacker does not even need a new
market; but re-routing existing funds only matters if a *current* market is exploitable, and
**H3 (collateral vs real tradable price across all 26 comparable collaterals) came back
NEGATIVE — zero collaterals trade below their oracle.** No drain path was reached.

### Impact today
This vault holds **8.022515 USDG**. Severity is therefore **Informational** on this vault
alone; the *mechanism* (instant role + fee + routing on a single-EOA-managed MetaMorpho vault)
is reusable at scale and is the reason to recommend the owner be a multisig/timelock.

---

## Harness defects caught (so the numbers above stay trustworthy)
- Part 1 TEST B got `No Signer available` — the attacker address was never
  `anvil_impersonateAccount`-ed. Fixed in part 2.
- Part 1 TEST D/E failed on tuple construction: `cast` prints values with an annotation
  (`385000000000000000 [3.85e17]`), and piping that into a tuple breaks decoding — the same
  trap already recorded in `CHECKLIST.md` ("cast annotations corrupt awk field indices").
  Fixed by stripping to `$1` per line.
- Part 1 TEST F called state-changing selectors **with no arguments**, so every line
  "reverted" on argument decoding and proves nothing. **Not used as evidence.**

**Passes performed:** source read (S9) + fork attack (NSH-4) — 2 independent angles.
