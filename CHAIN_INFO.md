# Chain Info

## Robinhood Chain (RH)

| Property | Value |
|----------|-------|
| Chain ID | 4663 |
| RPC | `https://rpc.mainnet.chain.robinhood.com` |
| Explorer | `https://robinhoodchain.blockscout.com` |
| Explorer API | `https://robinhoodchain.blockscout.com/api` |
| Native Token | ETH (wrapped: `0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73`) |
| USDG | `0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168` |
| Type | Arbitrum Orbit L2 |
| Launched | July 1, 2026 |

### Key Contracts

| Contract | Address |
|----------|---------|
| WETH | `0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73` |
| USDG | `0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168` |
| Uniswap V3 Factory | `0x1f7d7550B1b028f7571E69A784071F0205FD2EfA` |
| Uniswap V3 SwapRouter02 | `0xCaf681a66D020601342297493863E78C959E5cb2` |
| Uniswap V4 PoolManager | `0x8366a39CC670B4001A1121B8F6A443A643e40951` |

### RPC Notes
- Rate limit on `eth_call` — add `sleep(2)` between calls
- Use `keccak256` from `pycryptodome` (NOT `hashlib.sha3_256`) for correct selectors

---

## Monad

| Property | Value |
|----------|-------|
| Chain ID | 143 |
| RPC | `https://testnet-rpc.monad.xyz` (testnet) / `https://rpc.mainnet.monad.xyz` (mainnet) |
| Explorer | `https://explorer.monad.xyz` |
| Native Token | MON |
| USDC | Deployed per standard |
| Type | EVM L1 |
| Launched | May 2026 |

### RPC Notes
- Monad testnet RPC is rate-limited. Use `sleep(1)` between calls.
- Mainnet RPC may require API key — check docs.
- Used for: OBSDN audit (Perpetual DEX, $220K TVL)

---

## Ethereum

| Property | Value |
|----------|-------|
| Chain ID | 1 |
| RPC | Standard public RPC per provider |
| Explorer | `https://etherscan.io` |
| Explorer API | `https://api.etherscan.io/api` |
| Native Token | ETH |
| Type | EVM L1 |

### RPC Notes
- Use forked node (Anvil) for testing — do not test on mainnet
- Used for: Cleave audit (Options splitting protocol, $76 TVL)

---

## Arbitrum One

| Property | Value |
|----------|-------|
| Chain ID | 42161 |
| RPC | `https://arb1.arbitrum.io/rpc` |
| Explorer | `https://arbiscan.io` |
| Native Token | ETH |
| Type | EVM L2 (Optimistic rollup) |

### RPC Notes
- Arbitrum RPC is unreliable for `anvil --fork-url` — timeouts are common
- If fork fails, rely on static analysis + manual review
- Used for: Basalt Vault audit ($119K TVL, delta-neutral yield)

---

## Base

| Property | Value |
|----------|-------|
| Chain ID | 8453 |
| RPC | `https://mainnet.base.org` |
| Explorer | `https://basescan.org` |
| Native Token | ETH |
| Type | EVM L2 (Optimism stack) |

### RPC Notes
- Coinbase L2 — good RPC reliability
- Growing ecosystem with early-stage protocols
- Used for: openOracle, Arcis Protocol

---

## Berachain

| Property | Value |
|----------|-------|
| Chain ID | 80094 |
| RPC | `https://rpc.berachain.com` |
| Explorer | `https://berascan.com` |
| Native Token | BERA |
| HONEY | Berachain stablecoin |
| Type | EVM L1 (Polkadot SDK + EVM) |

### RPC Notes
- Reliable public RPC
- Growing DeFi ecosystem — many unaudited protocols
- Used for: SukukFi audit (RWA Lending, $54 TVL)
