# TMAAR — Sentry Launch Factory

## Actors & Trust Levels

| Actor | Trust Level | What They Can Do | What Happens If Compromised |
|-------|-------------|------------------|---------------------------|
| Owner (proxy deployer) | **High** | Upgrade implementation, change fee params, set fee recipients, change treasury, add/remove base tokens, update pool managers, update NPM | Single EOA can rug all uncollected fees or upgrade to malicious code that drains LP positions |
| Token creator | None | Launch tokens, collect 65% of LP fees via factory | — |
| Traders | None | Trade tokens on Uniswap V3 pools | — |
| Fee recipient | Medium | Collect creator's fee share | Can migrate fee recipient once |
| TsunamiPoolManager | **High** | Provides initial price/ticks for pool creation | Can set manipulated initial price and extreme tick ranges |
| Uniswap V3 NPM | **High** | Manages LP positions, collects fees | Standard Uniswap contract, audited |
| Treasury | Medium | Receives 35% of LP fees | Can be changed by owner |

## Key Assumptions

1. **Owner is benevolent** — Single EOA address with upgrade power. No timelock, no multisig visible.
   - *What if it fails?* Owner can upgrade to malicious implementation and drain all LP positions.
2. **TsunamiPoolManager returns valid minting params** — Controls initial pool price.
   - *What if it fails?* Malicious pool manager could set initial price to steal value or create manipulated markets.
3. **Uniswap V3 contracts are secure** — Factory depends on NPM for pool creation and fee collection.
   - *What if it fails?* Beyond scope — Uniswap V3 is battle-tested.
4. **LP is permanently locked** — No function to transfer or burn LP NFTs out of factory.
   - *What if it fails?* Upgrade could add unlock function, but that's an owner action.

## Accepted Risks

1. **Owner upgrade power** — Standard for proxy pattern. No timelock.
2. **Owner sets fee parameters** — Creator fee can be changed from 0% to 100%.
3. **Owner controls fee recipient assignments** — Can override per-pool fee recipients via adminSetFeeRecipient.

## Attack Surface Summary

- **Primary trust assumption to attack:** Single-EOA owner with full upgrade power
- **Most powerful attacker:** Compromised owner key
- **Secondary attack surface:** Pool manager params manipulation at launch
- **Interesting edge cases:** Fee routing when recipient is 0x, batch collection gas grief, NFT creator tracking correctness
