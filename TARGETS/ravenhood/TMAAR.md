# TMAAR — Ravenhood Protocol

## Actors

| Actor | Address | Role | Trust Level |
|-------|---------|------|-------------|
| **Owner** | `0xf65227639636288f3ec7d1368dbf6e6f7a99b533` | Controls Vault — can call `claimBurn()` to burn LP liquidity | EOA — single key |
| **DAO Wallet (deployer)** | `0x097ba31b7ACfFd75B909fc7BEf2e55424d2dAcdc` | Controls StakingPool (owner), is DEPLOYER of Vault (can lock NFT once), received initial RVH supply | EOA — "interim, moving to multisig" per DefiLlama |
| **Stakers** | Any | Deposit RVH into StakingPool, earn rewards | Untrusted |
| **Traders** | Any | Trade RVH/WETH on Uniswap V3, generating LP fees | Untrusted |
| **Any caller** | Any | Can call `claimFees()` on Vault (fees go to owner) | Untrusted |

## Trust Model

### Owner Powers (Vault — `0xf652...b533`)
- Can call `claimBurn()` to burn 0.5% of LP liquidity per call, extracting resulting tokens
- Cannot unlock the LP NFT (no withdraw/unlock function exists)
- Cannot redirect fees (they always go to `owner`)

### Owner Powers (StakingPool — DAO wallet `0x097...cdc`)
- Can stop reward emissions (`stopReward`)
- Can change reward rate (`updateRewardPerSecond`)
- Can drain unclaimed rewards (`emergencyRewardWithdraw`)
- Can pause/unpause deposits and withdrawals
- Can change tax receiver address
- Can recover non-RVH tokens accidentally sent

### Owner Powers (RVH Token — renounced to `address(0)`)
- **None.** Token ownership was renounced. Supply is permanently fixed at 100M.

## Assumptions

1. **Uniswap V3 Position Manager is trusted** — all Vault operations depend on the Position Manager behaving correctly
2. **LP position is permanently locked** — the Vault has no withdraw/unlock function, confirmed by code
3. **The buyback mechanism is off-chain** — the Vault only collects fees; actual buyback/burn depends on the owner performing it off-chain
4. **Tax receiver is trusted** — the 5% early withdrawal tax goes to the multisig address

## Accepted Risks

1. **Owner can drain unclaimed staking rewards** via `emergencyRewardWithdraw` — documented in natspec
2. **`claimBurn()` has no slippage protection** — `amount0Min: 0, amount1Min: 0` means MEV can sandwich the burn
3. **Vault `claimFees()` is permissionless** — anyone can trigger it, but fees always go to owner
4. **No on-chain buyback** — the "deflationary burn engine" relies on the owner to convert fees into buybacks
5. **Vault owner is a different address** than the DAO wallet — creates two separate trust anchors
