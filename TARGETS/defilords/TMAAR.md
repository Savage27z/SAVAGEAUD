# DefiLords — TMAAR (Trust Model, Actors, Assumptions, Accepted Risks)

## Protocol Overview

DefiLords = AI-powered ERC-4626 vault protocol on Arbitrum (+ Ethereum). Users deposit USDC, AI allocates across strategies:
- **dlGROWTH** → UniV3 USDC/WETH 0.05% LP (auto-compound via GrowthVaultV5)
- **dlFLOW Balanced** → UniV3 USDC/WETH 0.05% LP with flow-derived rebalancing (FlowVaultBalanced)
- **dlFLOW Hybrid V2** → Same LP but with 3 yield split modes (FlowHybridVault V2)
- **dlFLOW Hybrid V1** → Same as V2 but retired (buggy — holds residual funds)
- **dlSTABLE** → Aave v3 USDC (unverified on Blockscout)
- **dlNEUTRAL** → Morpho Gauntlet USDC Core (unverified on Blockscout)

Total TVL: ~$2,300 (all time low, ~$4K peak)

## Actors

| Actor | Role | Trust Level |
|-------|------|-------------|
| **Owner** | Deploys/upgrades adapters, sets fees, pauses, drains yield reserve | Single EOA (constructor: msg.sender) |
| **Keeper** | Deploys idle, harvests, rebalances, records ticks | EOA set by owner |
| **Fee recipient** | Receives performance fee shares | EOA set by owner |
| **Users (LPs)** | Deposit USDC, earn yield | Untrusted |
| **Adapter** (UniV3/Flow) | Manages UniV3 LP position | Separate deployed contract |
| **Uniswap V3 Pool** | USDC/WETH 0.05% | External dependency |

## Trust Model

1. **Owner can**: change adapter, keeper, fee recipient, performance fee (cap 20%), reserve ratio (cap 50%), deposiCap, minDeposit, pause/unpause, drain yield reserve. Single EOA — no timelock or multisig visible.
2. **Keeper can**: deploy idle into LP, harvest (trigger LP fee collection + PPS increase), rebalance LP position, record tick. Cooldown on harvest (15 min in Hybrid). Keeper = owner or separate EOA set by owner.
3. **Adapter contracts**: not audited here (separate deployment). This TMAAR covers the vault layer only. Adapter trust: if adapter is malicious, it can rug LP position (deposit→withdrawAll to drain).
4. **UniV3 pool risk**: standard — IL, manipulation during rebalance window, swap fees.

## Key Assumptions

| Assumption | Failure Mode |
|------------|-------------|
| Adapter behaves as documented (getTVL returns LP value, withdrawAll returns all funds, harvest returns realized profit only) | Malicious adapter can report fake TVL, rug LP, report fake harvest amounts |
| Owner multisig or timelock protects vault parameters | Single EOA = single point of compromise |
| Keeper runs rebalance honestly (Flow vaults) | Keeper can rebalance to extreme ticks causing IL or MEV extraction |
| realizedYieldReserve < vaultBalance (solvency) | V1 has bug where deployIdle depletes reserve → harvest permanently reverts |
| Owner will not drainYieldReserve then abandon | Users left with claimable they can't claim |
| Uniswap V3 AMM continues functioning on Arbitrum | Chain issues / sequencer downtime prevent LP operations |

## Accepted Risks (documented by protocol)

- Performance fee up to 20% — standard for active vaults
- LP IL risk — LPs accept market risk of USDC/WETH pool
- Adapter handles all LP math — vault treats adapter as black box
- V1 Hybrid vault is retired but holds user funds (known buggy)
- No timelock on owner operations — documented but not mitigated

## Dependencies

- **USDC** (bridged/原生 on Arbitrum)
- **Uniswap V3 Pool** (USDC/WETH 0.05%)
- **Adapter contracts** (separate, not audited here)
- **Chainlink oracles** (via Uniswap pool TWAP — indirect)
