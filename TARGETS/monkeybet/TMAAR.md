# TMAAR — MonkeyBet / RaiseController family (NothingGuarantees) · Robinhood Chain

**Audit date:** 2026-08-30 · **Chain:** Robinhood Chain (4663) · **State:** live & active (claims Aug 30)

## Contract family (all source-verified, Solidity 0.8.26)

| Contract | Address | Role |
|---|---|---|
| MonkeyBet V2 (Closed) | `0xCD38B4Ffa22f5c734a2E4CF4a51A8a8DB81730c2` | 3-tier put-option sale on RaiseToken, reserve-backed |
| MonkeyBet V1 (Open) | `0x3171e6e5E5750ef3a7aED79924D8E1557718A465` | older bytecode (9,821 vs 11,236 bytes), same logic |
| RaiseController V3 (active) | `0xd37895b039D19C3c3F63E78f48f57c4E7587fCDb` | **$218,341 raised**, finalized, claims today |
| RaiseController V4 (older) | `0x198f9Ce2fa7f3488F4fA1ceC851F2Df2530F40c6` | older mint-based design, $10,001 raised, finalized |
| RaiseController (×2 more) | `0x44C3...`, `0xe916...` | same V3 bytecode (4340 bytes) |
| RaiseToken V3 | `0x9b52d1c25c002ba6ff5b68e8f9ff4f2a27099e8f` | standard ERC20Burnable, no fees, no mint post-deploy |
| RaiseToken V4 | `0x53669dc11b3e8dd4dd18e910409dc2ba8f2ff688` | ERC20 + one-time setMinterOnce + revokeMintingForever |
| AllocationNFT | `0xacd122...` (active) / `0xb2529a...` (V4) | ERC1155 pass, owner-only airdrop, maxSupply cap |
| Treasury (shared) | `0x9da325c485c35ecde4c2328232b3d890d8662f8b` (EOA) | receives premiums + team cut |

## Pipeline (the actual product)

1. **AllocationNFT** airdrops $50 passes to selected wallets
2. **RaiseController.contribute(usdc)** — burns `ceil(amount/50)` passes, forwards USDC to treasury, records entitlement
3. **finalize()** (owner-gated in V3, permissionless in V4) — computes tokensSold + 15% team cut, V3 burns excess pre-funded supply / V4 mints + revokes minting forever
4. **claim()** — contributors swap USDC-recorded entitlement for RaiseToken at 1 USDG = 1 token
5. **MonkeyBet** sells **put options on that same RaiseToken**: pay 0.10–0.20 USDG premium per tier → right to hand back 1 RaiseToken + NFT for 0.80–1.05 USDG after 90-day wait + 48h claim window

## Actors & Trust

| Actor | Address | Powers | Trust |
|---|---|---|---|
| MB owner | `0xa4996d8eb469b3f75670a32344fefc52a7681097` (EOA) | openSale/closeSale, depositReserve, withdrawExcessReserve, sweepUnclaimed, pause, URIs | **Single key. Docs claim multisig — on-chain is EOA.** |
| RC owner (V3 active) | `0x64d5b76db945516093fee755a34d73eb265da0af` (EOA) | openRaise/closeRaise, finalize | Single key over $218K raise |
| RC owner (V4) | `0x660fb2fbc58a0cee420b1f3e3a9bb802c0c6b506` (EOA) | openRaise/closeRaise (finalize permissionless) | Single key |
| AllocNFT owner (active) | `0x210426297dc2c5c8c8cfa219b6926c86a07228ef` (EOA) | airdrop passes | Single key — can mint unlimited passes up to maxSupply |
| Buyers/contributors | anyone with passes/USDG | contribute, claim, buy puts, redeem | — |

**⚠️ Docs-vs-on-chain mismatch:** RaiseController + MonkeyBet docs both state the owner is *"the same multisig that controls TaxHook's treasury timelock."* On-chain, **every** owner is a plain EOA (verified via `eth_getCode` — all return 0 bytes). Either the docs are aspirational/stale or deployments used the wrong key.

## Live state (2026-08-30)

- **MonkeyBet V2:** Closed Aug 23, 5,091 units sold, totalLiability **5,334.50 USDG**, contract USDG balance **exactly 5,334.50** (excessReserve = 0). Claim window Nov 21–23.
- **MonkeyBet V1:** Open, 3 units sold, liability 2.75, balance 3.00 (0.25 excess).
- **RaiseController V3:** $218,341 raised, finalized, token supply 251,092 (= 218,341 + 15%), RC holds 1,736 residual, treasury holds 33,275 team cut. Claims happening **today**.
- **RaiseController V4:** $10,001 raised, finalized.
- All owners EOAs; treasury EOA; RaiseToken standard (no fees/hooks).

## V1→V2 diff (MonkeyBet)

**Only metadata URI handling changed** (generic `setURI` → per-tier `setTier0/1/2URI`). Zero changes to buy/redeem/reserve/claim logic. No security fix hidden in the version bump.

## Reserve accounting (verified sound)

- `buy()` checks `usdg.balanceOf(this) >= totalLiability + newLiability` BEFORE minting — can never mint more liability than the reserve covers
- `redeem()` CEI ordering: burn → decrement liability → pull RaiseToken → pay USDG
- `withdrawExcessReserve()` only takes `balance - totalLiability` — can never drain below liability
- `closeSale()` reverts while paused; pause is locked after Close → redeem() can never be owner-blocked
- `sweepUnclaimed()` only after `claimWindowEnd()` — no race with in-window redeems
- Solvency: balance == liability at all times by construction (verified: 5,334.50 == 5,334.50)

## Accepted risks (by design)

- Premiums flow to treasury; reserve is owner-funded separately (`depositReserve`)
- No minimum raise, no refunds (USDC never touches the controller)
- 48h claim window, then owner sweeps everything unclaimed
- Protocol writes **naked puts on its own token** — if RaiseToken trades below buyback at claim time, every holder exercises and drains the reserve (fully collateralized, so no insolvency, but the treasury loses the reserve)
- `renounceOwnership` disabled everywhere

## Open questions

- RaiseToken DEX liquidity (Cloudflare-blocked) — determines whether puts are practically exercisable
- TaxHook contract existence (referenced in docs as the "real" multisig holder)
