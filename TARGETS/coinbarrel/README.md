# Coinbarrel (Robinhood Chain) — Target README

**Status:** ⏳ Phase 0.5 in progress (TMAAR + on-chain verification done) — blocked on source access (implementations unverified, no public repo)

| | |
|---|---|
| Target | Coinbarrel — token launchpad / launch platform (coinbarrel.com, @UseCoinbarrel) |
| Chain | Robinhood Chain (4663) — Hook V5; also Arc (5042), Stable (988), BSC |
| TVL | ~$61K (DefiLlama, LP principal; 100% RHC) |
| Fees | $124.6K 30d / $171.7K cumulative (DefiLlama) |
| Category | Launchpad (Uniswap V4 hook architecture; no bonding curve) |
| V5 activation | Block 21,306,158 ≈ **2026-07-28 04:26 UTC** (~37 days live — over the 30d filter; active upgrades ongoing) |
| Audits | None found (DefiLlama, docs, Google, GitHub) — "reviewed" in docs = internal |
| Prior scan | thestackaudit.xyz rated T4 (2026-07-31, PRE-V5): old RH factory = UUPS proxy + single EOA key + unverified impl |
| Team | Reachable — X @UseCoinbarrel; dev Kyle McDougal (@RioStreamKyle); docs.gitbook with deployment registry |
| Source | ❌ NOT public: 6 proxies verified on explorer (OZ proxy only); ALL implementations unverified; no GitHub |

## Phase 0.5 — Verified on-chain (Sep 3, 2026, ~20:50 UTC, block 53,635,088)

### Owner concentration — CONFIRMED single EOA
`owner()` on **all six** application proxies = `0x30e4b6dc3139e28b5c5e493d395a0aca4f1cddba`
- `eth_getCode(0x30e4b6dc…)` = `0x` → **bare EOA**, no multisig, no timelock.
- One key = UUPS upgrade authority over: launcher, position vault, hook V5, fee router, stock registry, impairment controller.

### Implementation slots vs docs
| Proxy | Live impl (ERC1967 slot) | Docs say | Status |
|---|---|---|---|
| launcherProxy `0x4234e536…e70` | `0xfce63ecc…9d73f` | same | ✅ match (upgraded TODAY Sep 3 04:20 UTC to this impl) |
| positionVaultProxy `0x685c85df…e1` | `0x53fb5d66…fe83a` | same | ✅ match |
| hookProxy `0xf667c59c…bfff` | `0xaf4ea672…b9379` | same | ✅ match (last upgraded Aug 16 — terminal handoff NOT executed; still upgradeable) |
| feeRouter `0xfff9bbf1…562` | `0x8e7e525d…b5c08` | `0xa4bcdb94…dc7d74` | ❌ **docs STALE** — upgraded **Aug 30 19:49 UTC** |
| stockRegistry `0x28873508…9e` | `0x27307a9f…85be1` | same | ✅ match |
| impairmentController `0x4f16b570…d0` | `0x81431532…c6d2f` | `0x7616d1a9…c34f72` | ❌ **docs STALE** — upgraded **Aug 30 02:39 UTC** |

### Upgrade history (Upgraded event per proxy, tx hashes in blockscout)
- V5 deploy wave: block ~21.3M (2026-07-28)
- vault → burn-impl `0x53fb5d66`: 2026-08-11 (docs-documented tx `0x0fb2e27a…`)
- hook → `0xaf4ea672`: 2026-08-16 (no upgrade since — pre-terminal state)
- impairment → `0x81431532`: **2026-08-30 02:39** (`0x12307f15…`)
- feeRouter → `0x8e7e525d`: **2026-08-30 19:49** (`0xd109e790…`)
- launcher → `0xfce63ecc`: **2026-09-03 04:20** (`0x80670dcf…`) — SAME impl as docs; re-upgrade/no-op or docs refreshed

### Permanent custody (principal boundary claim)
- `PermanentV4PositionCustody` `0x418ece71…659`: contract exists (2,657 bytes), **NOT a proxy** (ERC1967 slot = zero) → structurally non-upgradeable ✓ (code read still required to rule out escape paths)
- Uniswap V4 PositionManager `0x58daec31…fa7` live
- Docs claim: NFT minted straight into custody; no approve/transfer/withdraw path on custody; vault/hook/fee-router upgrades cannot reach LP principal → **to verify in code pass**

## Open questions for the code pass
1. What changed in feeRouter `0x8e7e525d` and impairment `0x81431532` on Aug 30? (docs don't cover these impls at all)
2. Why did launcher re-upgrade to the same docs impl today (Sep 3 04:20)?
3. Terminal hook handoff: prepared but NOT deployed — hook owner can still swap hook logic today. What does the handoff tx look like and what EXACTLY gets stripped?
4. Fee accounting seams (P2): flat 1%/direction for post-flat pools vs proportional 30/70 for pre-flat pools — pinned per pool at registration; hook-fee + pool-LP-fee combined formula `hook + lp − hook·lp/1e6`; escrow/claims/rewards/burn/reinvestment paths; legacy V1/V2/V3 pools still trading on old paths.
5. Launch protection + Advanced creator controls (fee/allocation/quote/rewards/collection) — what can a creator change post-launch (P1/P3)?
6. ERC-404 launches (LaunchToken404) — novel surface.
7. Do any authz predicates pass for fresh/empty accounts (P1 default-state check)?

## Source access options
- No public repo (GitHub search: 0 hits for coinbarrel+Solidity)
- RHC Blockscout (robinhoodchain.blockscout.com): Cloudflare-walled for direct API; via r.jina.ai works; proxies verified, impls return `{"Address":...}` only (unverified)
- rh-scan.com: reachable, minimal API (no v1/v2 contract endpoints)
- Arc/Stable explorers: impls also not verified there (404 on API)

**→ Next: ask team for source** (docs invite reviewer scrutiny; team reachable). If no source, this target caps at structural findings.

## Receipts
- Verification script: saved as `verify_onchain.py` in this dir (RPC + blockscout checks)
- Explorers: rh-scan.com · robinhoodchain.blockscout.com · RPC rpc.mainnet.chain.robinhood.com (UA-blocked for python-urllib; needs browser UA)
- Docs: docs.coinbarrel.com (markdown via `.md` suffix; llms.txt index)
- Registry: coinbarrel.com/integrations/robinhood/deployments.json (contains V4-era + advancedV5 sections; partially stale)
