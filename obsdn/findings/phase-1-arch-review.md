# OBSDN — Phase 1 Findings

## 1. Architecture Overview

OBSDN is a hybrid perpetual DEX (off-chain matching, on-chain settlement) on Monad. It supports crypto, equity, and ETF perp trading with multi-collateral (USDC, BTC, ETH), cross/isolated margin, sub-accounts, and vault staking.

### Contracts (8 total)

| Contract | Proxy | Impl | Notes |
|----------|-------|------|-------|
| **Obsdn** | `0x90c374...BE45` | `0x166670...DA95` | Main entry, 6 internal modules, 59 functions |
| **Matching** | `0x227adD...4C03` | `0x5BA057...60c5` | Order matching engine |
| **PerpLedger** | `0x336Ed4...CfC59C` | `0x48E461...1BC` | Position tracking |
| **SpotLedger** | `0x8d1565...6723` | `0x69d8d5...064b4` | Collateral balances |
| **VaultManager** | `0xedF8C3...4591B` | `0xe72f23...fD79` | Vault operations |
| **AccessControl** | `0x8dbb54...A77d` | `0x64D00c...749C1D` | Role-based access |
| **SigValidator** | `0x823f79...8bba` | `0x0000...` | Not deployed (impl=0) |
| **DlnDepositAdapter** | `0x871904...ab3` | `0x0000...` | Not deployed (impl=0) |

## 2. Trust Model

### ✅ Strengths
- **4/6 Gnosis Safe** for all upgrades (ProxyAdmin owned by multisig)
- **ReentrancyGuard** on all mutative functions
- **EIP-712** typed signatures for order validation
- **AccessControl** for role separation (ADMIN, SEQUENCER, FEE_SETTER)
- **USDC** as quote token (standard 6-decimal ERC-20)

### ⚠️ Risks
- **SigValidator & DlnDepositAdapter** not deployed — may be pending features or disabled
- **Sequencer role** controls order execution — single point of trust for order ordering
- **Off-chain matching** means sequencer sees all orders before on-chain settlement
- **No DEFAULT_ADMIN found** on-chain — roles may be renounced or managed differently

### 🔴 Concerns for Deeper Analysis
1. Can the sequencer front-run user orders?
2. What prevents signature replay across markets?
3. Who can update funding rates and how?
4. How are liquidations triggered and priced?
5. What happens if the sequencer goes down?

## 3. Upgrade Path

```
EOA Deployer (0xa96a63...4603)
  └── deployed all proxies
       └── ProxyAdmin (0x499d05...5340) — Ownable contract
            └── Owner: Gnosis Safe (0x82fe7e...b826)
                 ├── 6 owners
                 └── Threshold: 4/6
```

Any 4 of 6 multisig signers can upgrade any contract to a new implementation. This is the standard and accepted risk for upgradeable proxies.

## 4. Initial Verdict

**OBSDN passes Phase 1 (Architecture & Trust Review).**

The architecture is standard for a hybrid perp DEX. The multisig setup is decent. No obvious red flags at this level.

**Next:** Source code review (Phase 2) needed to verify:
- Signature replay protection (nonce scheme)
- Funding rate calculation integrity
- Liquidation logic fairness
- Access control correctness per function
- Cross-contract reentrancy paths
- Price oracle integration
