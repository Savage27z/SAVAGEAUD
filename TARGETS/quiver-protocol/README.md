# Quiver Protocol

**Status:** ✅ Analyzed — nothing reportable
**Chain:** Robinhood Chain (4663)
**Category:** AI-managed concentrated-liquidity vaults
**Deployment:** Implementation contracts only — no vaults live yet

## Contracts Analyzed

| Contract | Address | Notes |
|----------|---------|-------|
| Vault Implementation | `0xd71d01f4AE53D1A1d751103e50DA97cc176Dc982` | Verified, immutable |
| Strategy Implementation | `0x944d5F280ED8Bcb5C0D83fE1E525d1332184ade6` | Verified, immutable |
| FeeConfig | `0x777bBe1F53ae75f478DaF22b0E5A5d9513e98E31` | Live on-chain, deployed via constructor |
| Agent Keeper | `0x11eBB184C68699ed45245B98074322f80f08D4C8` | EOA, not a contract |

## Findings

### ✅ Defenses (solid)
1. **First-depositor attack** — seedDeposit mints to DEAD address. Classic attack vector closed.
2. **Donation attacks** — `totalLiquidity()` reads actual Uniswap position, not token balance. Can't inflate PPS by donating.
3. **CEI pattern** — `withdraw()` burns shares before calling external `strategy.divest()`. No reentrancy.
4. **nonReentrant** — Both `deposit()` and `withdraw()` use `ReentrancyGuard`.
5. **Sandwich protection on compound** — Swap price limited to calm band edge (TWAP ± maxTickDeviation).
6. **Keeper sandwich protection** — `RangeMustBracketPrice()` guarantees rebalance is a small composition adjustment, not a full one-sided flip.
7. **Emergency exit** — Zero swaps, zero oracle reads. Works mid-manipulation.
8. **Immutable vault** — No proxy, no upgrade path. Strategy is swappable behind 48h timelock.

### ⚠️ Watched (non-reportable)
1. **Rounding direction** — Both deposit and withdraw round down (against user). Maximum 1 wei loss per transaction. Quantified: at PPS=1.1, 1 wei lost per cycle. Not exploitable.
2. **isCalm() single gate** — The entire deposit/rebalance security depends on this function. Parameters not verifiable until vaults deploy.
3. **Keeper is EOA** — No contract-enforced rate limits. Strategy guards limit the damage but keeper key compromise enables spam-rebalancing.
4. **0% caller fee** — `defaultCallerBps = 0`. Depositors pay harvest gas with no compensation. Design choice, not a bug.

### ❌ Not reportable
- "Owner is privileged" — they document this in beta.
- Rounding loss (1 wei) — economically irrelevant.
- No live vaults to test against.

## Docs
- Website: https://quiverprotocol.finance/learn/contracts
