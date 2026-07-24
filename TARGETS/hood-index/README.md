# Hood Index — On-Chain MAG7 Index on Robinhood Chain

| Field | Value |
|-------|-------|
| **Chain** | Robinhood Chain (4663) |
| **TVL** | $75 (DeFiLlama) / $7.5K+ rewards distributed |
| **Category** | Indexes |
| **Age** | ~7 days (listed Jul 17, 2026) |
| **Audit** | None found (20/20 unit tests + 2/2 fork tests) |
| **Team** | @TheHoodIndex (1.3K followers, verified, active) |
| **Website** | hmag7.com |
| **Twitter/X** | @TheHoodIndex |

## Contracts Audited

| Contract | Address | Lines | Role |
|----------|---------|-------|------|
| **IndexVault** | `0x43e4aa3204A2d3cee2E12532195E9a6b766a3639` | 216 | hMAG7 ERC-20 token, in-kind mint/redeem, fee accrual |
| **IndexFactory** | `0x4667E480371A9BeD712f7d03dB1F0863262d9fb4` | 46 | Permissionless index creation |
| **NavLens** | `0x105E49777B284f7aF8bd711517d9F62d736f5567` | 105 | View-only NAV via Chainlink |
| **FeeConverterV4** | `0x7FcF57D68a11B9087597e6b180bFA47272E9B4F1` | 340 | Fee → buyback & burn engine via Uniswap V4 |
| **ZapV4** | `0x299d70339C4108c1E120AF9e54c4975ba989d76C` | 339 | One-click ETH→hMAG7 and hMAG7→ETH via V4 |
| **M7Staking** | Not deployed (listed as "Publishing at launch") | — | Stake $M7, earn WETH |

---

## TMAAR (Trust Model, Actors, Assumptions, Accepted Risks)

### Actors

| Actor | IndexVault | FeeConverterV4 | ZapV4 |
|-------|-----------|---------------|-------|
| **Owner** | Sets fees (within hard caps), changes feeCollector, owns the contract (Ownable2Step) | Sets target token/pool (one-time), staking pool (one-time), component feeds, slippage, manages keepers | **None** — no owner, no upgrade, no whitelist |
| **Keeper** | N/A | Executes fee conversion pipeline (redeemFees → sellComponent → buybackAndBurn) | N/A |
| **User** | Mints/redeems hMAG7 in-kind with components | N/A | One-click ETH↔hMAG7 via Uniswap V4 |
| **Chainlink Oracle** | N/A (vault has no oracle dependency) | Price floor for component sales | N/A |
| **Uniswap V4** | N/A | All swap routing | All swap routing |

### Trust Model

**Minimal.** This is one of the best-designed protocols I've audited:

- **IndexVault:** The basket is IMMUTABLE — set once in the constructor, never changeable. Fees are hard-capped at compile-time constants (1% mint, 1% redeem, 2% streaming/yr). The owner can adjust fees within those caps and change the feeCollector, but can NEVER modify the basket or withdraw underlying assets. No upgradeability, no pause, no rescue function.

- **FeeConverterV4:** No withdrawal function exists. Protocol fees can ONLY leave via the buyback & burn pipeline: redeem shares → sell components with Chainlink price floor → buy target token → burn. The target pool is one-time-set by the owner, preventing keeper routing manipulation.

- **ZapV4:** No owner, no upgrade, no whitelist. Pool keys come from the caller — a bad key just fails the tx. ETH refunds always go back to caller.

- **IndexFactory:** Permissionless — anyone can deploy an index.

### Assumptions

1. **Chainlink feed correctness** — NavLens and FeeConverter both rely on Chainlink prices
2. **Uniswap V4 pool integrity** — Zap and FeeConverter both route through Uniswap V4
3. **Robinhood Chain stock tokens follow ERC-8056** — corporate actions handled via multiplier
4. **Sequencer uptime** — Chainlink feeds on Arbitrum Orbit depend on sequencer
5. **Owner bootstraps correctly** — FeeConverter's target pool, staking pool, and component feeds must be configured correctly at setup

### Accepted Risks

1. **Owner sets initial fees** — During bootstrap, the owner chooses fee levels (within hard caps). Users can evaluate before participating.
2. **Owner picks feeCollector** — The feeCollector receives mint/redeem/streaming fees. If compromised, fees go to attacker. However, the attacker still cannot touch the underlying assets.
3. **FeeConverter's Chainlink floor has 1% wiggle** — The default slippageBps = 100 (1%). A sandwiched swap could lose up to 1% of value before the floor triggers. This is transparent and documented.
4. **No audit** — The protocol has only unit tests, no external security review.

---

## Phase 1 — Code Reading

### IndexVault.sol (216 lines)

**Constructor (L62-89):** Sets immutable basket. Deduplicates components via `unitsPerShare[token] != 0` check. Sets initial fees within caps. Sets feeCollector. Records `lastAccrual` for streaming fee. ✅

**mint (L127-141):** `nonReentrant`. Calls `_accrueStreamingFee()`. Transfers components from user via `safeTransferFrom`. Calculates mint fee in shares (mints to feeCollector). Mints net shares to user. CEI: transfers happen BEFORE minting. ✅

**redeem (L145-165):** `nonReentrant`. Burns shares, calculates redeem fee (transfers fee shares to feeCollector via `_transfer`), sends components pro-rata. ⚠️ **Important:** The fee is paid in SHARES, not in components. The feeShares are transferred BEFORE the burn. This means the feeCollector gets shares, which they can redeem later for components. ✅

**streaming fee (L198-211):** Calculates pro-rata fee based on time elapsed. Mints new shares to feeCollector. This inflates supply, diluting other holders. Standard pattern for ETF/index protocols. ✅

**amountsForMint (L102-107):** Uses `_ceilDiv` — rounds UP, so the vault always gets enough. 💡

**amountsForRedeem (L113-120):** Pro-rata based on ACTUAL vault balances, floor-division. Rounding dust stays in the vault, benefiting remaining holders. Vault can never go insolvent. ✅

**setFees (L175-178):** Only owner. Respects hard caps. Accrues streaming fee first. ✅

### NavLens.sol (105 lines)

**totalNavUSD8 (L51-58):** Simple: sum of (token balance × Chainlink price). Stale feed reverts.

**breakdown (L79-96):** Returns all component data without reverting on stale feeds — marks them as stale. Good for frontend.

**Key design choice:** NavLens is a SEPARATE contract from IndexVault. The vault has NO oracle dependency. This is intentional and excellent — mint/redeem work correctly regardless of oracle status.

### FeeConverterV4.sol (340 lines)

**redeemFees (L164-167):** Calls `vault.redeem()` to convert fee shares into underlying components. Keeper-only.

**sellComponent (L174-197):** The core swap: component → ETH via Uniswap V4. Protected by Chainlink price floor: `fairOut = (amountIn * tokenUsd) / ethUsd`, then `floorOut = fairOut * (10000 - slippageBps) / 10000`. If actual output < floor, tx reverts. ✅

**buybackAndBurn (L204-225):** Takes WETH, splits staking share, converts rest to native ETH, swaps via V4 to target token, sends to DEAD address. `nonReentrant`. ✅

**unlockCallback (L234-247):** Only callable by PoolManager. Dispatches to SELL or BUYBACK based on Action enum.

**_sell (L250-283):** Handles component → ETH (possibly via USDG intermediate). Uses exact-input swap. Settles component debt. If proceeds are USDG, does a second swap USDG → ETH within same unlock.

**_buyAndBurn (L286-296):** ETH → targetToken via targetPool (owner-set, immutable). Sends bought tokens directly to DEAD address.

**Key protections:**
- `targetPool` is one-time-set → keeper can't redirect buyback
- Chainlink price floor → keeper can't sandwich for profit
- `nonReentrant` on all keeper functions
- No withdrawal function → fees can only be burned or sent to stakers

### ZapV4.sol (339 lines)

**zapMint (L107-153):** ETH → buy components via V4 → mint hMAG7. All inside one `unlock`. After unlock, approves vault and mints. Refunds leftover ETH and component dust.

**zapRedeem (L160-196):** Redeem hMAG7 → get components → sell via V4 → ETH. All inside one unlock. `minEthOut` protects against slippage.

**unlockCallback (L199-264):** For MINT: buys each component via exact-output swap, pays in ETH or USDG. Then buys USDG debt with ETH. Settles ETH debt. Takes components.

**Key:** No owner, no upgrade. Pool keys from caller — worst case = tx failure. ETH refunds protected against griefing via `msg.value > left ? msg.value - left : 0`.

---

## Phase 2 — Multi-Perspective Hunt

### 1. Access Control
**IndexVault:** Owner can set fees (capped) + change feeCollector + transfer ownership (2-step). Cannot touch basket, cannot withdraw components. ✅
**FeeConverterV4:** Owner configures everything (one-time-set for critical params). Keeper executes pipeline. No withdrawal function. ✅
**ZapV4:** No owner at all. ✅

### 2. Reentrancy
**IndexVault:** `nonReentrant` on mint and redeem. `_accrueStreamingFee` called internally — no external calls before state changes. ✅
**FeeConverterV4:** `nonReentrant` on redeemFees, sellComponent, buybackAndBurn. WETH operations are standard. Uniswap V4 unlock is safe (state managed by PoolManager). ✅
**ZapV4:** `nonReentrant` on zapMint and zapRedeem. ✅

### 3. Math/Accounting
**IndexVault:** Ceil-div for mint (vault gets enough), floor-div for redeem (dust stays). Streaming fee mints new shares (dilution). All correct. ✅
**FeeConverterV4:** Chainlink-based price floor with configurable slippage. 👀 One thing: `fairOut = (amountIn * tokenUsd) / ethUsd` — `tokenUsd` and `ethUsd` are both 8-decimal Chainlink prices. `amountIn` is token amount (18 dec). So fairOut = (18dec * 8dec) / 8dec = 18dec ETH. Correct. But tokenUsd/ethUsd division happens first mathematically... actually `amountIn * tokenUsd` overflows? tokenUsd is uint256, amountIn is uint256. Stock tokens have 18 decimals but prices in 8 decimals (like $333.22 → 33322000000). So amountIn * tokenUsd ≈ 1e18 * 3.3e10 = 3.3e28, well under uint256 max (~1e77). ✅

### 4. Timing/MEV
**FeeConverterV4:** Chainlink price floor with 80h staleness window. During rapid market movements, the floor could be stale. But 80 hours is intentionally wide (weekend pauses). The fee pipeline is keeper-triggered, not time-sensitive. ✅
**ZapV4:** `minSharesOut`/`minEthOut` protect users against sandwiching. Pool keys from caller — sandwich risk depends on caller choosing good routes. ✅

### 5. Oracles
**Chainlink feeds:** 24h heartbeat + 80h staleness window (handles weekends). Stock feeds have corporate-action multipliers built in. ✅
**IndexVault has NO oracle dependency** — mint/redeem work without oracles. ✅

### 6. User Funds Safety
**IndexVault:** Components held by vault. No withdrawal function for owner. No rescue. No pause. Funds are always redeemable in-kind. ✅
**FeeConverterV4:** No withdrawal. Fees can only be burned or staked. ✅
**ZapV4:** Holds nothing between transactions. Always refunds leftovers. ✅

---

## Findings Summary

Verdict: **🟢 Clean** — no reportable vulnerabilities.

This is one of the best-designed protocols I've audited. The immutable basket + hard-capped fees + no upgradeability + no admin withdrawal + Chainlink price floor + one-time-set critical params is a model architecture for index protocols.

### Key Observations

| # | Observation | Severity | Impact × Likelihood |
|---|------------|----------|-------------------|
| 1 | No external audit — only unit tests | Low | Low / Low |
| 2 | FeeConverter Chainlink floor has configurable 1% slippage gap | Informational | Low / Low |
| 3 | ZapV4 pool keys from caller — relies on user choosing good routes | Informational | Low / Medium |
| 4 | Dust accumulation in IndexVault from floor-division redeem | Informational | Low / Certain |
| 5 | FeeConverter target pool one-time-set — owner bootstrap mistake is permanent | Informational | Low / Low |
| 6 | NavLens 80h feed staleness window may mask stale data during volatile weekends | Informational | Low / Low |

### Multi-Pass Check

- ✅ **Pass 1 (Full read):** All 5 contracts read line-by-line. Clean.
- ✅ **Pass 2 (Access/Reentry):** All mutating functions guarded. No withdrawal paths for attacker.
- ✅ **Pass 3 (Economic):** Fee math correct. Price floor prevents sandwiching. Streaming fee dilution is standard.
- ✅ **Pass 4 (MEV/Oracles):** Chainlink provides adequate protection. ZapV4 slippage params from user.

---

## Files

| File | Description |
|------|-------------|
| `code/IndexVault.sol` | Core hMAG7 index token — immutable basket, in-kind mint/redeem |
| `code/IndexFactory.sol` | Permissionless factory for creating new indexes |
| `code/NavLens.sol` | View-only NAV calculator via Chainlink |
| `code/FeeConverterV4.sol` | Fee → buyback & burn engine via Uniswap V4 |
| `code/ZapV4.sol` | One-click ETH↔hMAG7 via Uniswap V4 |
| `README.md` | This file |

## On-Chain Verification

All 5 contracts verified on Blockscout ✅
