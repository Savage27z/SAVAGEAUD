# backed.is ($BACKED) — Robinhood Chain — Target README

**Status:** ⏳ Scaffolded — source retrieved & saved. Phase 0.5/1 pending user go.

| | |
|---|---|
| Target | backed.is ($BACKED) — reserve-backed token, tokenized-stock vault |
| Chain | Robinhood Chain (4663) |
| Reserve | ~$51.8K in tokenized stocks at stackaudit check (2026-07-25); token trades ~2.4x backing |
| Category | RWA-ish reserve token (tokenized equities backing) |
| Age | Deployed ~mid/late July (checked 2026-07-25 by thestackaudit) — ~6 wks old, over the 30d filter |
| Audits | None found; thestackaudit.xyz T2 full scan (2026-07-25) — structural, not logic-deep |
| Source | ✅ **VERIFIED on Blockscout, non-proxy, solc 0.8.26** — saved in `source/` |
| Team | backed.is — web thin; vault owner single hot EOA `0x9ca5B125…` (no multisig/timelock) |
| Activity | LIVE — approve txs to token at block 53,762,724 (~2026-09-03) |

## Contracts (all verified, non-proxy)
- **BackedToken** `0x7168563b0e70124f0c7c0cf2f13a8d1861baf4a5` — ownerless, fixed 1B supply minted once in constructor, burn-only on redeem (supply already 956M from real redemptions)
- **StockVault** `0x49ef9869fc358b6e755c722ea8514a574bd8ce8e` — immutable reserve; redemption fee ≤10% hard cap (currently 5%); keeper + fee setter owner powers
- **BackedRouter** `0xd6486d8115f8602e19fb00349143d40ed4113360` — router

## Mechanism (per thestackaudit + source)
3% each-way ETH tax on the BACKED/ETH Uniswap V4 pool → vault; keeper buys tokenized blue-chip stocks (NVDA/AAPL/MSFT…) via Rialto into the vault; holders redeem **in-kind pro-rata** for a slice of every stock, burning $BACKED → backing-per-token rises for remaining holders.

## StockVault function map (from source)
- redeem/redeemTo(uint256 amount[,address to]) → _redeem — **the money function** (pro-rata across stock basket, burn $BACKED)
- previewRedeem; _trySend(tok,to,amt) — dust/edge handling; _safeBalanceOf
- buyStocks(minOuts[]) — V4 pool ETH→stocks w/ **unlockCallback** (callback surface)
- buyStocksRialto(RialtoBuy[]) / _rialtoBuy / _resolveRouter / resolvedRouterSafe — Rialto settlement-router path
- addStock(stockToken,fee,tickSpacing,hooks) / removeStock(i) / pruneRedeemable(stockToken)
- setKeeper(k,on) / setRedemptionFeeBps(bps) / setMaxSpendPerBuy(v)
- stocksLength/stockTokenAt/redeemableLength/redeemableAt/reserves

## Wave-pattern lens (P1/P2/P3) → where to look first
1. **P2 two-sources-of-truth**: vault's own stock balances vs V4 pool state; redeemable list vs stocks list; reserve per token math. Redemption rounds pro-rata across a multi-asset basket with heterogeneous decimals — rounding/dust asymmetries; first/last-redeemer skew; _trySend edge cases.
2. **P1 default-state authz**: keeper flag, fee cap enforcement path (can fee exceed 10% via any path?), owner powers bounded but single EOA.
3. **P3 balance-arrival paths**: stock tokens arriving by direct transfer (donation) vs buyStocks — do donations corrupt redemption math? pruneRedeemable guard ("reverts unless balance zero").
4. **Reentrancy/callback**: V4 unlockCallback path; SafeERC20; CEI on redeem.
5. **Router**: tax hooks, BACKED/ETH pool mechanics, router↔vault trust.
6. **Rialto**: per-buy spend cap; router resolution (registry ownerOf(featureId)); taker-submitted orders = who can grief/steal the buy?

## Evidence
- `source/` — flattened verified sources: token_flattened.sol (1.9KB), vault_flattened.sol (21KB), router_flattened.sol (3.8KB) + raw API jsons
- thestackaudit.xyz/p/backed-is.html (T2 full scan 2026-07-25)
- Explorers: rh-scan.com, robinhoodchain.blockscout.com (CF-walled; API via r.jina.ai)
