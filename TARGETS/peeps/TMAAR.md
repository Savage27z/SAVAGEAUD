# TMAAR — Peeps ($PEEPS)

## Actors

| Actor | Address | Role | Trust Level |
|-------|---------|------|-------------|
| **Owner** | Factory owner (Ownable2Step) | Controls factory fees, pause state, caps, migrator/router settings | EOA — single key |
| **Router** | Set by owner | Entry point for all buys/sells/creates; only address that can call `buy()`/`sell()`/`createToken()` on curves/factory | EOA or contract |
| **Migrator** | Set by owner | Handles graduation to Uniswap V3; registers LP positions in vault | Contract |
| **Creator** | Per-token (chosen at launch) | Receives 1% trade fee + 40% of post-grad LP fees | EOA |
| **Treasury** | Set in factory constructor | Receives protocol share of LP fees | EOA/multisig |
| **Marketing Wallet** | Set in vault constructor | Receives 20% of protocol LP fee share | EOA |
| **Buyback Wallet** | Set in vault constructor | Receives 20% of protocol LP fee share | EOA |
| **Traders** | Any | Buy/sell on bonding curves | Untrusted |
| **Any caller** | Any | Can trigger `sweepProtocolFees()`, `collect()`, `executeFurnaceBurn()` | Untrusted |

## Trust Model

### Owner Powers (Factory)
- Can pause creates and buys (`pauseCreates`, `pauseBuys`)
- Can change fees (creation, graduation, caller reward) within caps
- Can change router, migrator, V3 swap router, treasury
- Can change per-token ETH cap, global ETH cap, trade fee
- Can change anti-snipe parameters

### Owner Limitations
- Cannot mint tokens or modify deployed curves
- Graduated tokens are permanently on Uniswap V3 with locked LP
- Each curve is immutable after deployment (fees are hardcoded immutables per curve)

## Assumptions

1. **Router is trusted** — Only the router can call `buy()`/`sell()`/`createToken()`. A malicious router could steal user funds.
2. **Migrator is trusted** — Handles graduation and LP position registration.
3. **Uniswap V3 position manager is trusted** — LP fee collection depends on it.

## Accepted Risks

1. **Owner controls fee parameters and caps** — Within pre-set bounds
2. **`onERC721Received` auto-registers positions** — Any NFT sent to LP Fee Vault gets registered (mapping collision risk documented in findings)
3. **Furnace burn before graduation only** — Unburned furnace fees after graduation stay in the curve contract
