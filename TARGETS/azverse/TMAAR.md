# TMAAR — AZverse AssetVault (Arbitrum One)

Target Audit Assessment Report — generated 2026-08-31 by SAVAGEAUD hunter process.

## 1. Target identification

- **Protocol:** AZverse (azverse.xyz) — "high-performance orderbook DEX" ecosystem; partners: Moomoo, Cobo, Canton, Failsafe, Capbridge, Kaia.
- **Contract:** AssetVault — withdrawal settlement vault for the AZverse trading platform.
- **Chain / addresses:**
  - Proxy (ERC-1967 minimal): `0x91ba525861c16aa8cd4d6974e4058cc846f42ebe`
  - Implementation (UUPS): `0x94a99081475d0b5b887c5a03fcd9b81e52c264de`
  - Creation tx: `0x73f4d5e4fa2fe3cafae97ff1f3334c17266a76448351867c943466a3cf15c083` (blk 482030474, 2026-07-09)
  - Impl verified (Blockscout `getsourcecode`, Solidity 0.8.25); Sourcify exact_match.
- **TVL (DefiLlama):** $51.7M — methodology: "Arbitrum Asset Vault and third-party qualified-custodian wallets, plus BTC hot wallet". **On-chain vault actually holds ~$108K** (verified via RPC): 56,896 USDT0 + 51,782 USDC + 3.38 USDe + 50 USDT + 0.002 ETH.
- **Audits:** none found (DefiLlama audits: 0; site/docs no security page; search no audit reports).
- **Activity:** live — requestWithdraw/batchFlushWithdrawals txs every few seconds on 2026-08-31; 201 WithdrawExecuted events since deployment, all micro (0.5 USDT0 typical).

## 2. Code review

Full 874-line flattened source read (line-by-line). Key logic:

- `depositOnBehalf` (DEPOSIT_ROLE, Safe) — pulls tokens, emits `DepositOnBehalf`.
- `requestWithdraw` (OPERATOR + validators) — nonce check → token valid → hot-amount refill → withdrawal-exists check → balance check → digest `keccak("requestWithdraw", id, chainid, address(this), token, amount, fee, receiver, isForcePending, nonce)` → `_verifyValidatorSignature` → store `Withdrawal` → execute immediately if not pending.
- `batchFlushWithdrawals` (OPERATOR + validators) — digest over ids/chainid/this/nonce; executes pending withdrawals (bypasses challenge period; cannot bypass `paused`).
- `executeExpiredPendingWithdrawal` — **permissionless**; only pending, non-executed, non-paused withdrawals past `pendingWithdrawChallengePeriod` (1 day); receiver fixed at request time.
- `rebalanceWithdraw` (OPERATOR + validators) — to fixed `rebalanceReceiver` (currently unset → disabled).
- `batchTogglePendingWithdrawal` — pause/unpause pending withdrawals (no pausing after challenge expiry).
- `batchResetWithdrawHotAmount` (OPERATOR + validators) — zero the hot-amount budget.
- `withdrawFees` (ADMIN) — accumulated per-token fees out.
- Hot-amount: `usedWithdrawHotAmount` vs `hardCap = balance * hardCapRatioBps/10000`; refill `hardCap * refillRateMps * elapsed / 1e6`.
- Validators: `addValidators`/`removeValidators`/`updateValidatorRequiredPower` (VALIDATOR_ROLE, timelocked); sorted-set hash; power-weighted ECDSA verification with monotonic index walk (duplicate sigs can't double count).
- UUPS `_authorizeUpgrade` gated UPGRADE_ROLE (1-day timelock).

## 3. On-chain verification (live, 2026-08-31)

- Roles mapped via full RoleGranted/RoleRevoked log scan (creation → latest). **Current:**
  - DEFAULT_ADMIN+TOKEN+DEPOSIT+PAUSE → Gnosis Safe 1.4.1 L2 `0x4a335bb7f44fc27bf4fbb5705e71014bace924ec`, threshold 3, owners = 4 EOAs (`0x8a04...`, `0xe8ac...`, `0xe031...`, `0xa91f...`).
  - ADMIN → Timelock `0x7a1b6891269ed1699f93e25296a6e23d6f4f7386` (minDelay 1800s; proposer/canceller = Safe; executor = address(0) + deployer; DEFAULT_ADMIN self-held by the timelock).
  - UPGRADE → Timelock `0x92996ea56590b0e659d695d9736db62cae843b51` (minDelay 86400s; executor = anyone).
  - VALIDATOR → Timelock `0x383a6439f966d67edc6140d12024334616ddc276` (minDelay 1800s).
  - OPERATOR → 3 EOAs.
- Validator set: single `ValidatorsAdded` at blk 484459974; same set live today: 3 EOAs × power 20, totalPower 60, **requiredPower 40 → 2-of-3**. Never rotated/removed.
- Token config: USDT0/USDC/ETH `hardCapRatioBps=10000`, `refillRateMps=12`; `usedWithdrawHotAmount` ~0 (force-pending pipeline), `lastRefillTimestamp` recent.
- `pendingWithdrawChallengePeriod` = 86400; `paused` = false; `rebalanceReceiver` = 0.
- Impl slot unchanged since creation (1 `Upgraded` event, creation block only).
- Custody wallets (`0x03a7...`, `0xc2a2...`, `0xdc37...`) are EOAs (no code) — off-chain qualified custodian accounts; BTC hot wallet is a Bitcoin address.

## 4. Attack surface analysis

All value-exit paths:
1. `requestWithdraw` (instant) — OPERATOR + ≥2/3 validators + balance + hot-cap (unless force-pending).
2. `requestWithdraw` (pending) → `batchFlushWithdrawals` — OPERATOR + ≥2/3 validators.
3. Pending → `executeExpiredPendingWithdrawal` — anyone, after 1 day, receiver fixed.
4. `rebalanceWithdraw` — OPERATOR + validators, receiver = ADMIN-set (disabled now).
5. `withdrawFees` — ADMIN (timelocked), CEI.
6. Upgrade — UPGRADE (timelocked 1 day).

No path reachable by a single key; no unauthenticated value movement; pending-execution path cannot redirect funds.

## 5. Findings

### F1 — EOA trust anchor for the withdrawal multisig (Informational / operational)
Withdrawals require **1 of 3 operator EOAs + 2 of 3 validator EOAs**. The validator keys are the real custody keys; if the signing backend or two validator keys are compromised (phishing, infra, insider), the vault drains. Validator set has never been rotated since deployment. *Recommendation: HSM/MPC signing, key rotation policy, withdrawal anomaly monitoring.*

### F2 — Hot-amount cap effectively disabled (Informational)
`hardCapRatioBps = 10000` → hot budget = 100% of vault balance; operators force-pend all withdrawals (`isForcePending=true` observed), so the instant-budget accounting (`usedWithdrawHotAmount`) rarely binds. The 1-day challenge period is the only speed brake. Design choice; no exploit found.

### F3 — On-chain exposure is ~$108K, not $51.7M (Informational)
DefiLlama TVL includes off-chain custody EOAs. Only the hot balance is contract-reachable. A contract bug cannot drain custody wallets; conversely, custody wallet risk is off-chain (not Solidity-auditable).

### F4 — Governance quality (positive)
Safe 3-of-4 for the omnipotent role; ADMIN/VALIDATOR 30-min timelocks; UPGRADE 1-day timelock; deployer revoked from all roles; timelocks self-administering. Above-average for a fresh protocol.

### F5 — Nits (no impact)
- `ReentrancyGuard` (non-upgradeable OZ) in an upgradeable contract — works, but should be the `Upgradeable` variant for consistency.
- `receive()` unrestricted — anyone can inflate ETH balance/hard cap; harmless with gated withdrawals.
- A pending withdrawal with `fee >= amount` can never be executed (transfer reverts) — operator-created only, stuck state per ID.

## 6. Verified non-findings

- Reentrancy: CEI + nonReentrant on all mutating paths; ETH via `sendValue` (2300 gas).
- Signature replay: digests bind action name + chainid + contract + nonce; EIP-191 prefixed; cross-action replay impossible.
- Duplicate/out-of-order signatures: monotonic validator walk prevents double-counting.
- Permissionless pending-execution: receiver is fixed at request time → no fund redirection.
- Nonce reuse: `nonceUsed` global, reverts on reuse.
- Overflow: hot-cap/refill arithmetic bounded well below uint256 max.
- Fee logic: `fees[token]` CEI; ADMIN-timelocked withdrawal; `fee >= amount` rejected.

## 7. Conclusion

🟡 **Informational.** Well-engineered custody contract with solid governance (Safe + timelocks) and correctly-gated withdrawal paths. No critical/high/medium Solidity vulnerability found. Main exposure is operational: EOA-based operator/validator keys (1+2 = full drain) and the fact that most TVL is off-chain and un-auditable from the contract. Nothing to disclose to a bounty; worth a note to the team on F1 (validator key security/rotation).
