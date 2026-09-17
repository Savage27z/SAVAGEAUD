# Pre-vet sweep — 2026-09-17 (four candidates, all REJECTED)

Sourced from `GET https://api.llama.fi/protocols` — EVM, TVL < $1.5M, listed <75d,
non-DEX categories, excluding everything already in `TARGETS/`.

**Why this file exists:** all four were rejected *before* any audit time was spent,
so nobody re-audits them by accident. Each rejection is a source-verification
failure, not a judgement on the code.

---

## 1. Arcus pTokens — REJECTED (core logic unverified) ⚠️ reads as verified

| | |
|---|---|
| Chain | Robinhood Chain (4663) |
| TVL | $632,998 (Arcus Perps behind it: $23,620,502) |
| Category | Derivatives — leveraged/inverse tokens ("pTokens") |
| Listed | ~20 days |
| Team | **dYdX Labs**, in partnership with Robinhood Crypto (launched Aug 25–26, 2026) |
| Docs | arcus.xyz, docs.arcus.xyz/llms.txt |
| Audits | DefiLlama `audits=0`; none found in search (only a third-party Solven "due diligence" post — not an audit) |

**Mechanism (from press + docs):** a pToken is an ERC-20 wrapping a *managed perpetual
account* carrying fixed leverage (`pBTC3x`, `pHOOD3x`, `pHOOD3x` short). Transferable and
tradeable on spot venues.

**Contracts inspected**
| Address | Contract | Verified |
|---|---|---|
| `0xe24CABDf76DD1c2576049167eB1755C84b985C36` | pHOOD3x (BeaconProxy, eip1967_beacon) | proxy ✅ |
| `0x4472C69d299382F8847ebCE4FC6Ed8e295510E3e` | pBTC3x (proxy) | proxy ✅ |
| `0x925F92F055EDB79C42B5d45E64A1b74143b90eA0` | pBTC1x (proxy) | proxy ✅ |
| `0xaDccEee8e422050F890522FA798F8A93a4857083` | pBTC3x Short (proxy) | proxy ✅ |
| `0x6e4db65dB8758D943F61d2F9Abcb26449B93082D` | PonsLauncherToken (launcher ERC-20, not core) | ✅ |
| **`0x1815A37B6027Ae8066720d873A508F25fC151AC5`** | **implementation behind the beacon — THE logic** | **❌ UNVERIFIED** |
| `0x33846348210a0cc0345f354d9de52b89ad473a76` | Beacon (590 bytes), `implementation()` → above | — |

**Evidence for rejection**
- `eth_getCode(0x1815A37B…)` = **31,386 bytes** of live code; `beacon.implementation()`
  → `0x1815a37b6027ae8066720d873a508f25fc151ac5` (confirmed by `eth_call`).
- Blockscout `smart-contracts/0x1815A37B…` returns the **6-key object with
  `creation_bytecode`** (126,125 bytes), no `source_code`, no `is_verified` — **identical
  on 3 consecutive fetches**, so this is the verification signature, not the intermittent
  500 that `CHAIN_INFO.md` warns about.
- Sourcify: `403` (server) / `404` (repo) on chain 4663. No official GitHub (only
  third-party waitlist clones and trading bots).

**Consequence:** the entire 31KB logic of a leveraged-token primitive is a black box.
Source review is impossible; only the black-box route (`references/blackbox-no-source-audit.md`)
would apply. Not worth a slot while verified targets exist.

---

## 2. HASHCATS — REJECTED (money contract unverified)

| | |
|---|---|
| Chain | Robinhood Chain |
| TVL | $140,875 |
| Category | Gamified Mining — fully on-chain proof-of-work NFT collection |
| Listed | ~4 days |
| Audits | none found |
| Twitter | @hashcats_rh |

- `0xca75082b85bb7bec8325d513f615b16bda260020` — **`HashToken`, VERIFIED** (3,252 bytes
  source, solc 0.8.25, verified 2026-09-13). ERC-20 with `addMinter`/`removeMinter`/
  `mint`/`burn` + ownership handover. **Holds 0 ETH.**
- `0xca75df55cc9c476db27a7375d1fc8e794cf80721` — **UNVERIFIED** (6-key object,
  creation_bytecode), **17,063 bytes of code holding 60.799 ETH**. Per DefiLlama's own
  methodology this is where the accrued rent lives.

**Consequence:** the ERC-20 is verified, the proof-of-work mint logic and the $140K rent
escrow are not. The interesting value path is the black box.

---

## 3. Gage — REJECTED (vaults unverified)

- Chain: Robinhood Chain · Category: Lending (fixed-term P2P, no liquidation) ·
  $541,460 USDG in protocol, 50,685 on loan, 2,712 live 7-day deals · listed ~6 days ·
  audits none found · `gage.cash`, @gagedotcash.
- Mechanism interest: **two engines coexist** — site states *"Positions funded on the
  earlier engine keep their recorded 48-hour grace window"*, i.e. V1 and V2 with different
  expiry rules. That is a genuine version-skew seam and the most promising thing found in
  this sweep.
- Verification: `0x7163aE1B5AeA2f09EBc609C52b4dcAc0a7a4bC2d` is the **GAGE ERC-20**
  (3,248 bytes, `is_smart_contract_verified: true`, `is_verified_via_admin_panel: true` —
  note it still 404s the `/smart-contracts/` endpoint). The three **lending vaults are not
  verified**, and Blockscout name search returns only copycat memecoins.

**Consequence:** rejected on the money contracts (the vaults), not the token. **Worth
revisiting if the vault addresses surface and are verified** — the dual-engine rule skew
is the best lead in this sweep.

---

## 4. Flock Credit — REJECTED (unverified)

- Chain: Robinhood Chain · Category: Lending · $143,380 TVL ($36,412 borrowed) ·
  listed ~2 days · audits none found · `ravenhood.xyz/flock-credit`.
- Part of the **Ravenhood** ecosystem (`parentProtocol: ravenhood`) — the Ravenhood
  protocol itself was audited clean on Jul 24 (`TARGETS/ravenhood/`).
- Mechanism: borrow USDG against **locked veUP** while gauge rewards auto-repay debt;
  epoch-based, relayer-run. 30 active collateral positions, 359,909 veUP, 25.39% LTV,
  80% cap.
- DefiLlama's protocol `address` is the RVH token, not Flock's own contracts.
- Verification: `veUP` `0x1C75974b41410D293ee2632240cC0BD71bf89707` **unverified**;
  market vault `ffveUP-USDG` "Fireflies veUP Lending USDG" `0x6074f8997083e919ADB7843D16D71D07588F93e2`
  **unverified**.

**Consequence:** rejected — every Flock-specific contract is unverified.

---

## Sweep conclusion

The fresh Robinhood Chain cohort (chain opened 2026-07-01) is **largely unverified**, and
the explorer's `is_verified` flag is **not** a reliable proxy for "the logic is readable":
on Arcus it is true for a 2.3KB BeaconProxy shell while the 31KB implementation behind it
is invisible.

**Rule reinforced:** verify the *implementation*, not the proxy — resolve the
ERC-1967/beacon slot, `eth_getCode` the implementation, and confirm `source_code` is
present for *that* address before proposing a target. See `CHECKLIST.md`.
