# Longbow — curated Morpho lending on Robinhood Chain (TARGET, recon complete)

**Chain:** Robinhood Chain (Orbit L2), chainId **4663**, RPC `https://rpc.mainnet.chain.robinhood.com`
**App:** https://www.longbow.cash — "The RWA lending layer for Robinhood Chain"
**DefiLlama:** `longbow` — Lending, **audits: 0**, listed 2026-09-07 (6 days old at open)
**Opened:** 2026-09-13
**Status:** 🔬 Recon complete, audit starting. **0 confirmed findings yet.**

## Why this target (and why not the others)

Picked from a DefiLlama sweep (8,243 protocols → 130 candidates ≤60 days old, $5K–$3M TVL, `audits=0`).

The filter that decided it was **source readability**, not TVL:

| Candidate | Chain | TVL | Why it lost |
|---|---|---|---|
| **Levr Bet** (prediction market, 2d old) | Monad | $1.9M | **Monad has no free source route.** `explorer.monad.xyz` is a JS SPA (not Blockscout); `api.monadscan.com` V1 is dead; Etherscan V2 needs a key we don't have. Capped at black-box work — the exact ceiling that limited nar.bet. |
| **Longbow** (lending, 6d old) | Robinhood Chain | $2.49M | ✅ **Free verified source** (Blockscout API via real headless Chrome — see Recon unlocks). Real TVL, zero audits, fresh. |
| **Murk Finance** ($61K), **Drake Exchange** ($226K, has an audit), Gage / Oter / Hookers / Twofold | Monad / RH | small | Monad = blocked as above; RH ones are smaller than Longbow with thinner custom code. |

Longbow's own docs name its unaudited surface for us: *"Longbow configures audited base protocol — Morpho
Blue and an unmodified Morpho Vault V2; **the only team-deployed contracts are the oracle adapters**, and they
are deployed pending third-party audit."*

## Architecture (all verified on-chain this session)

```
Morpho Blue (singleton, verified v0.8.19)      0x9D53d5E3bd5E8d4Cbfa6DB1ca238AEA02E651010
  owner = 0x060595638692de6CCd47ca04094F1772D3D39728   (171-byte contract ⇒ Safe-proxy shape)
  feeRecipient = 0x0
  ↳ 28 isolated markets, ALL loanToken = USDG, ALL irm = 0x2BD3d5965B26B51814AC95127B2b80dD6CcC0fa1
     each market has its OWN oracle  ← Longbow's deployed surface

MetaMorphoV1_1 curator vaults (vanilla, verified)
  USDG vault  0x8cb8AA35228c96C1C4E956E69AbAEBCc2aA7Dcfe  asset=USDG  totalAssets=8,022,515 ($8.02)  supplyQueue=28
  WETH vault  0x93777a9b917be3c8259c84456222f43a01dd6492  asset=WETH  totalAssets=0
  on BOTH: owner = curator = 0x1bf704707e9F3f407EbC9364fDAeD08C39893770  ← **EOA, codesize 0**
           guardian 0x67f79ccc109667CEBd25a1E2F8C365345EB3e918 · feeRecipient 0xA4C8E4ed1d6a85b68032F4B921b20a664Ea36413
           fee = 1e17 (10%) · timelock = 86,400s (1 day)
```

**Doc/code mismatch (minor, confirmed):** the site says "Morpho Vault **V2**"; the deployed vault is
**`MetaMorphoV1_1`** (compiler v0.8.26). Also "oracle adapters" understates it — 26 are Chainlink proxies,
but 2 are Longbow's own contracts (below).

## The 28 markets — collateral, LLTV, and the two custom oracles

All collaterals are 18-decimal tokens. `★` = custom oracle (not a Chainlink proxy).

| # | Collateral | LLTV | Oracle feed | Feed kind |
|---|---|---|---|---|
| 0 | WETH | 0.77 | `0x78F3556b…` | Chainlink "ETH / USD" |
| 1 | NVDA | 0.625 | `0x379EC4f7…` | Chainlink "RHNVDA / USD" |
| 2 | AMZN | 0.625 | `0xD5a1508c…` | Chainlink |
| 3 | SLV | 0.625 | `0x209b7390…` | Chainlink |
| 4 | GOOGL | 0.625 | `0xA04EE5c4…` | Chainlink |
| **5** | **CASHCAT** (memecoin) | **0.385** | **`0x709400Ed…`** | **★ 5,207 B, UNVERIFIED, "Uniswap V3 Pool Price in USD", 18 dp, roundId 0** |
| 6 | SPCX (pre-IPO SpaceX) | 0.385 | `0x42a95341…` | Chainlink "Robinhood SPCX / USD" |
| 7 | SPY | 0.625 | `0xa68CA834…` | Chainlink "RHSPY / USD" |
| 8 | QQQ | 0.625 | `0x41ed2c58…` | Chainlink |
| 9 | GME | 0.625 | `0x42A4652D…` | Chainlink |
| 10 | USO | 0.625 | `0x6D054DEC…` | Chainlink |
| 11 | MSFT | 0.625 | `0xaD6D88ea…` | Chainlink |
| 12 | SGOV | **0.86** | `0xa0DF4ee0…` | Chainlink |
| 13 | USAR | 0.385 | `0xA994d368…` | Chainlink |
| 14 | TSLA | 0.625 | `0x4A1166a6…` | Chainlink |
| 15 | META | 0.625 | `0x7C38C00C…` | Chainlink |
| 16 | AMD | 0.625 | `0x943A29E7…` | Chainlink |
| 17 | MU | 0.625 | `0x425EEFdC…` | Chainlink |
| 18 | PLTR | 0.625 | `0x820ABedF…` | Chainlink |
| 19 | INTC | 0.625 | `0x3f390C5C…` | Chainlink |
| 20 | SNDK | 0.625 | `0xfb133Fa4…` | Chainlink |
| **21** | **ORCL** | **0.625** | **`0x4a9aBC75…`** | **★ 23,186 B, VERIFIED as `DualAggregator`, 8 dp, roundId 1956** |
| 22 | COIN | 0.625 | `0xA3a468A4…` | Chainlink |
| 23 | TSM | 0.625 | `0x874cF94a…` | Chainlink |
| 24 | MSTR | 0.625 | `0x2521a77F…` | Chainlink |
| 25 | CRCL | 0.625 | `0x6652eDf6…` | Chainlink |
| 26 | ASML | 0.625 | `0xB4106147…` | Chainlink |
| 27 | BABA | 0.625 | `0x62Cc8F9b…` | Chainlink |

**All 28 share ONE quote feed:** `0x61B7e5650328764B076A108EFF5fa7282a1B9aD2` = "USDG / USD", 8 dp.
A defect there would mis-price every market at once — highest-leverage single contract in the system.

### Oracle construction is numerically CORRECT (checked, negative)

All 28 oracles are `MorphoChainlinkOracleV2` (Morpho's own, GPL-2.0, v0.8.21 — verified source read).
No vaults, samples = 1, `SCALE_FACTOR = 1e24` for every stock market. That equals
`10^(36 + quoteDec(6) + fpQ(8) − baseDec(18) − fpB(8))` = 1e24 ⇒ **feed decimals match, scaling is right.**

Decoded `price()` vs. sanity: WETH **$2,503.0**, NVDA **$218.32**, SPY **$765.35**, TSLA **$365.95**,
SLV **$58.10**, SGOV **$101.04** — all sane. ⇒ **no decimals/scale misconfiguration.** (Recorded as a negative.)

## Money map (ground truth, not DefiLlama's)

- **USDG actually held by Morpho Blue: `48,525.483821025` = $48,525.48** ← the entire lendable side.
- **Collateral posted** (Morpho's token balances): SPCX **4,928.09** (≈$739K @ $149.97) · NVDA **2,872.82**
  (≈$627K @ $218.32) · GOOGL 697.81 · WETH 28.02 (≈$70.1K @ $2,503) · CASHCAT **230,386.95** (≈$37.9K @
  $0.16459) · SPY 1.33 · MSTR 429 · rest dust · SLV/QQQ/GME/TSM/CRCL/ASML/BABA = **0**.
  ⇒ Collateral ≈ **$1.7M+ at oracle prices**.
- **This resolves the DefiLlama puzzle:** their `$2.49M` TVL is the **collateral leg**, not deposits.
  Their `borrowed = 621,614.98` **cannot be reconciled** with only $48.5K of USDG ever supplied — treat
  their Longbow adapter as unreliable. (Their number, not a Longbow defect — *not* a finding.)
- **The structural asymmetry is the thing to attack:** ~$1.7M of borrower collateral posted against
  **$48.5K** of actual lending. If any collateral is worth less than the oracle says, that gap is
  outsider-reachable theft of lender funds — not abstract bad debt.

## Audit surface (ranked by expected value)

1. **★ ORCL `DualAggregator` (`0x4a9aBC75…`, verified, 23KB).** A "dual" source aggregator is a
   primary/fallback design — exactly where a real bug lives (picks the wrong side, falls back to a stale
   source, no cross-check between sources). Read the source first: it is free and verified.
2. **★ CASHCAT Uniswap adapter (`0x709400Ed…`, 5,207 B, UNVERIFIED).** Bytecode contains
   `observe(uint32[])` (`0x883bdbfd`) and **does not** contain `slot0()` — so it is a **TWAP, not a spot
   read**. Open: TWAP window length, pool depth, whether a sustained push is cheap, and whether the
   window is long enough that the answer is honest. Impact is bounded by Morpho's **isolation** — market 5
   holds only ~$5 of USDG, so price inflation there buys nothing. Verify that bound before spending time.
3. **★ Shared quote feed "USDG / USD" (`0x61B7e565…`, 8 dp).** 28 markets depend on it. Confirm it is a
   genuine Chainlink feed (phase-encoded roundId, advancing) and not something re-usable/writable.
4. **Staleness / liveness (hypothesis, not yet a finding).** `MorphoChainlinkOracleV2.price()` validates
   only `answer > 0`; the equity feeds freeze outside market hours — **measured: the NVDA feed's
   `updatedAt` was 44.1 hours old while the ETH feed was current.** Two consequences to test on a fork:
   (a) positions can't be liquidated during a gap at a price that *should* have moved; (b) a dead /
   deprecated aggregator is indistinguishable from a live one, so the market keeps operating on a frozen
   price forever.
5. **Curator is a single EOA** (`owner` = `curator`, codesize 0) with 10% fee and a 1-day timelock on
   cap/guardian changes. Enumerate which vault powers are **instant** (`setIsAllocator`, `setCurator`,
   `setFee`, `setFeeRecipient`, `setSupplyQueue` vs `reallocate`) and whether any instant path can move
   the vault into a hostile market. Vault currently holds $8, so severity is low — but the mechanism is
   reusable at scale.
6. **Collateral-vs-real-market price** (H3, highest impact if it holds): do the tokenized equities trade
   near their oracle price on-chain? If a token is obtainable far below its oracle price, buy → post →
   borrow is a direct theft path.

## Open questions / blocked

- `ChainlinkDataFeedLib.getPrice()` — does it check `updatedAt`? (Oracle main file is verified; the lib is
  not in the returned source. Resolve from Morpho's public `morpho-blue-oracles` repo, not by assumption.)
- CASHCAT adapter is unverified ⇒ reverse-engineer (bytecode + immutables; `observe` selector present).
- `DualAggregator` source not yet read (verified ⇒ fetch + read).
- Per-market supply/borrow split: my 6-field `market()` decode gave inconsistent share/asset ratios
  (supply pair consistent at 1e6, borrow pair at 1.139e6 — impossible for Morpho's virtual-share math).
  **Don't quote per-market borrow figures until that's reconciled.** Ground-truth numbers above are
  token `balanceOf` reads and are safe.

## Recon unlocks (durable — reuse on every Robinhood Chain target)

1. **`~/.hermes/scripts/cfetch.sh <url>`** (mirrored at `TOOLS/cfetch.sh`): fetches through **real headless
   Chrome**, which passes Cloudflare. `robinhoodchain.blockscout.com` **403s curl** ("Just a moment…")
   from this datacenter IP — with Chrome it returns full verified source. This one script is what made
   this entire target map possible.
2. **Verification test = the response FIELD, never the HTTP status.** Blockscout `/api/v2/smart-contracts/<a>`
   returns a **36-key object including `is_verified`** when verified, and a **6-key object** (with
   `creation_bytecode`, no name) when unverified. A 500 `"Internal server error"` appeared
   **intermittently for both verified and unverified addresses** — I first read it as "unverified" and
   had to retract it when the control flipped. *Calibrate on a known-verified contract in the same batch.*
3. **Monad is not free-source.** `explorer.monad.xyz` serves an SPA (no Blockscout API); `api.monadscan.com`
   V1 is dead (404 for everything) → Etherscan V2 + key is the only route. Consequence: Monad candidates
   are capped at black-box/ABI work (as with nar.bet) and should be de-prioritised while RH/Monad-with-key
   alternatives exist.
