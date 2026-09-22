# TMAAR — BaiBai (Phase 0.5, written before section-by-section code reading)

**Target:** BaiBai — PropAMM exchange + aggregator on Base
**App:** app.baibai.cx · Docs: docs.baibai.cx · Opened 2026-09-22
**Basis:** public published addresses only (scoped like `app-surface-bounty-hunting` / `suspect-site-teardown`: no signing, no accounts, no state-changing calls)

---

## Trust Model

**What the user is trusting.** A taker grants an ERC-20 allowance to `BaibaiEntrypoint`
(`0x98c1D9E1…`) and calls `swapExactAmountIn`. Input is pulled from `msg.sender` into
`BaibaiCustodian`, output is paid from `BaibaiCustodian` to the recipient. **The Entrypoint is an
approval target, and the Custodian holds maker inventory** — so both sit directly on user funds.

**Where the trust actually terminates.** All three contracts are **EIP-1967 proxies**. Their
implementations are **UUPS-upgradeable** and **have no published source** (Blockscout: bytecode
only; Sourcify: 404; both with a working control — the `L2Bridge` impl *is* verified in the same
registries with 28,487 chars of source, so the absence is meaningful). All three proxy `owner()`
reads return **one address: `0xb1f4e4d6…`**, which is a **Safe multisig with `getThreshold() = 1`
and 3 owners**. One signer can therefore replace the logic of the swap entrypoint and the vault.

**What the documentation says vs what exists.** The docs describe the three addresses only as
"Verified proxy address", publish a partial read/swap ABI, and state that "implementation contracts
are not routing or approval targets". They do not disclose that an owner exists, that the
implementations are upgradeable, that the implementations are closed-source, or that the upgrade
authority is a 1-of-3 multisig.

---

## Actors

| Actor | Address | Authority | Can | Verified how |
|---|---|---|---|---|
| BaiBai owner (upgrade authority) | `0xb1f4e4d6…a907` | **Safe multisig, threshold 1 / 3 owners** (masterCopy `0x29fcb43b…` = Safe v1.4.1) | `owner()` and `upgradeToAndCall` on Entrypoint + CurveBook + Custodian | `eth_call owner()` on all three proxies returns it; `getThreshold()`=1; `getOwners()` → 3 slots |
| L2 admin owner | `0x5c55dd20…f026` | **EOA** (code size 0) | `owner()` of `L2Router` and `L2BaibaiAdmin` | `eth_call owner()`; `eth_getCode` size 0 |
| L2 admin pending owner | `0xe6419b6d…306c` | **Safe multisig, threshold 3 / 9 owners** | `acceptOwnership()` (transfer in flight) | `pendingOwner()` on `L2BaibaiAdmin`; `getThreshold()`=3; 9 owner slots |
| L2BaibaiAdmin (contract) | `0x28BAd3f4…861e` | owns `L2Router` | admin functions (source unverified) | `L2Router.owner()` returns this contract address |
| Takers | any address | none | `swapExactAmountIn` within curve + `minAmountOut` | documented ABI |
| Makers | unknown set | credited inventory | `deposit` / `requestWithdraw` / `claim` (all undocumented) | bytecode selectors on the Custodian impl |
| Pylon appchain (L3) | — | sequencing + execution logic | decisions the L2 surface cannot verify | docs: "remains entirely behind the scenes" |

---

## Assumptions

1. **ASM-1** — the three Base implementations can be replaced by a single signer, so any audit of
   their current behaviour does not bind future behaviour. *Not accepted by design; not disclosed.*
2. **ASM-2** — integrators reading the docs will believe the Entrypoint's logic is fixed, because it
   is described only as a verified proxy. *Not accepted by design.*
3. **ASM-3** — the L3 appchain is trusted for routing/ordering; L2 cannot verify it. *Accepted by
   design; stated in the docs.*
4. **ASM-4** — `Custodian.withdrawDelay() = 600s` is the maker withdrawal reservation window.
   *Accepted by design.*

## Accepted risks (as disclosed by the project)

- Appchain opacity (ASM-3).
- External aggregation (Uniswap/Aerodrome) is part of the price claim.

## Accepted risks the project does NOT disclose

- Upgradeable, closed-source implementations behind an approval target (ASM-1).
- A **1-of-3** upgrade authority on the vault and the swap entrypoint (ASM-1).

---

## What must never happen (each becomes a fork attack)

| ID | Statement | Status |
|---|---|---|
| NSH-1 | An approved balance is moved by the Entrypoint other than as payment for an executed swap | not attempted |
| NSH-2 | Anyone other than the owner calls `upgradeToAndCall` on Entrypoint / CurveBook / Custodian | not attempted |
| NSH-3 | A stale/expired curve is executed at its stale price | not attempted |
| NSH-4 | A maker withdraws more than credited, or exits outside `withdrawDelay` | not attempted |
| NSH-5 | A swap partially fills or pays less than a previously-read `quoteFor` allows | not attempted |

---

## Coverage gap (blocks a clean verdict)

Eight published L3 addresses are **entirely unmapped**: `L3Bridge` `0xBDC74090…`, `TokenFactory`
`0x39132c23…`, `Registry` `0x18f5F642…`, `Router` `0xD4A37eBa…`, `L3RouterWrapper` `0xf2BDB1F7…`,
`Oracle` `0xA2d1378e…`, `VaultFactory` `0x0e7A5C6A…`, `L3BaibaiAdmin` `0x9E31AF1C…`. No code size,
no impl resolution, no verification status. **No "clean" verdict is permitted while this is open.**
