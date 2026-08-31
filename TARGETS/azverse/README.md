# AZverse AssetVault — Arbitrum One

**Verdict: 🟡 Informational — no critical/high/medium logic vulnerabilities found**

| | |
|---|---|
| Target | AssetVault (withdrawal settlement vault) |
| Chain | Arbitrum One (42161) |
| Proxy | `0x91ba525861c16aa8cd4d6974e4058cc846f42ebe` (ERC-1967) |
| Implementation | `0x94a99081475d0b5b887c5a03fcd9b81e52c264de` (UUPS) |
| Solidity | 0.8.25 (flattened, verified — Blockscout exact source) |
| Deployed | 2026-07-09 (impl never upgraded) |
| Audits | None found (DefiLlama: 0; no docs/security page surfaced) |
| TVL | $51.7M per DefiLlama — but on-chain vault holds only **~$108K**; the rest sits in off-chain custody wallets |
| Activity | **Live** — withdrawal requests every few seconds (Aug 31 2026) |

## What it is

AZverse (azverse.xyz) is an orderbook DEX ecosystem ("AZ Axis" L1, EVM chain, custody partners incl. Cobo). The Arbitrum AssetVault is the **on-chain withdrawal settlement layer**: users' withdrawal requests are submitted by operator EOAs with ECDSA signatures from a power-weighted validator set; funds pay out from the vault's hot balance. DefiLlama counts the vault + 3 custody EOAs + a BTC hot wallet as TVL.

## Governance (verified on-chain)

| Role | Holder | Protection |
|---|---|---|
| DEFAULT_ADMIN, TOKEN, DEPOSIT, PAUSE | Gnosis Safe 1.4.1 L2 `0x4a33...2ec` | **3-of-4 EOA owners** |
| ADMIN (fees, challenge period) | TimelockController `0x7a1b...386` | 30 min delay, proposer = Safe |
| UPGRADE (UUPS) | TimelockController `0x9299...b51` | **1 day delay**, proposer = Safe |
| VALIDATOR (validator sets) | TimelockController `0x383a...c276` | 30 min delay, proposer = Safe |
| OPERATOR (requests) | 3 EOAs (`0x32fc...`, `0x9bbc...`, `0x9276...`) | — |
| Validator signers | 3 EOAs (`0x6CC5...`, `0xDa1b...`, `0xF29C...`) | 2-of-3 (power 40 of 60) |

Timelocks are self-administering (minDelay change requires a scheduled proposal → Safe → delay). Withdrawals need **any 1 operator + 2 of 3 validator keys**.

## Findings

- **F1 (Info, the real one): EOA trust anchor.** The whole vault drains with 1 operator key + 2 validator keys. Validator set registered once (Jul 9), never rotated. Validator signing is presumably automated backend infra — that infra is the system's true security boundary. Recommend HSM/MPC signing, rotation, and tx monitoring.
- **F2 (Info): hot-cap layer effectively off.** `hardCapRatioBps = 10000` (100% of balance) and operators always use `isForcePending=true` — instant-withdrawal budget never binds; every withdrawal flows through pending → flush. The 1-day challenge period + operator flush is the only brake.
- **F3 (Info): on-chain exposure ≠ TVL.** Only ~$108K is in the auditable contract; $50M+ is in off-chain qualified-custodian EOAs (Cobo-style). Contract bugs here can't touch the custody wallets.
- **F4 (positive): governance is well-built.** Safe 3/4 + timelocked admin/upgrade/validator, UPGRADE at 1 day, DEFAULT_ADMIN self-revoked on deployer, timelocks self-administering.
- **F5 (nit):** non-upgradeable OZ `ReentrancyGuard` in an upgradeable contract; `receive()` unrestricted (inflates ETH hard cap, harmless); a pending withdrawal with `fee >= amount` can never execute (operator-caused only).

## Verified clean (no finding)

- Reentrancy: CEI everywhere + nonReentrant on all state-changing paths; ETH pays out via 2300-gas `sendValue`.
- Signature scheme: digests bind action + chainid + `address(this)` + nonce (EIP-191); no cross-chain/cross-contract replay; duplicate signatures cannot double-count power (monotonic validator walk).
- Pending withdrawals: permissionless `executeExpiredPendingWithdrawal` only runs pre-authorized withdrawals to the fixed receiver — no theft vector; paused withdrawals can't be flushed/executed.
- Nonce system, fee accounting (`fees[token]`), hot-amount refill math — no overflow/underflow paths found.
- Implementation never upgraded; upgrade path sits behind 1-day timelock.

**Bottom line:** this is a well-engineered custody contract with genuinely decent governance. The honest risk is operational (EOA keys for operators/validators), not in the Solidity. Nothing to disclose.

Full report: `TMAAR.md` · Source: `AssetVault.sol` (flattened, Blockscout-verified)
