# Drift Protocol $285M — Admin Compromise Case Study (Apr 1, 2026, Solana)

**Lesson:** The most expensive "contract" bug of 2026 was not a contract bug. Audit-clean
code (Trail of Bits, Neodyme, ClawSecure) drained in ~12 minutes because the *signing
pipeline* and *admin capabilities* were the actual attack surface.

## What happened

- **Attack:** Apr 1 2026, 16:05:18–16:05:19 UTC — two txs, one second apart, took full
  admin control of Drift (Solana perps DEX, ~$550M TVL). Then 31 withdrawals in ~12 min
  drained **$285.26M** (JLP $155M, USDC $60–90M, cbBTC $11M, + SOL/WETH/USDT/Fartcoin...).
  Largest hack of 2026; 2nd largest in Solana history.
- **Attribution:** North Korea (UNC4736/TraderTraitor — same group as Radiant $50M and
  Bybit $1.4B). ~6-month social-engineering op: fake quant firm, in-person conferences,
  $1M+ "ecosystem deposit" to build trust, compromised ≥2 contributor devices
  (malicious repo exploiting a VS Code/Cursor vuln + fake TestFlight app).
- **Funding:** 10 ETH from Tornado Cash → bridged to Solana. **"Turned $500 into $285M."**

## The chain of failures

1. **Blind signing:** signers pre-signed routine-looking txs; Solana **durable nonces**
   made those signatures valid indefinitely (unrevocable unless nonce advanced).
2. **Zero-timelock 2-of-5 migration (Mar 26–27):** planned Security Council rotation
   replaced 4 of 5 signers, lowered threshold to 2-of-5, **no timelock**. SlowMist's
   alert literally says: "One week prior, the protocol migrated to a 2/5 multisig
   (1 old + 4 new signers) without a timelock."
3. **Apr 1 16:05:18 tx1** (`2HvMSg...`): create + approve malicious admin-transfer proposal.
4. **16:05:19 tx2** (`4BKBm...`): approve + execute → admin key to attacker
   (`H7PiGqqUaanBovwKgEtreJbKmQe6dbq6VTrw6guy7ZgL`).
5. **Admin powers abused:** `updateWithdrawGuardThreshold` ×7 → withdrawal guards raised
   to ~$500 TRILLION (effectively off); `initializeSpotMarket` for a **fake token CVT**
   (750M supply minted for ~$1.19, $500 Raydium seed, weeks of wash-trading to fake a
   $1 price) pointed at an **attacker-controlled oracle** (Neodyme 2024 had flagged
   "admin can set arbitrary oracle" as informational).
6. Deposited ~500–785M CVT as "collateral" at the fake $1 price → withdrew everything real.

## On-chain receipts

- Takeover txs: `2HvMSgDEfKhNryYZKhjowrBY55rUx5MWtcWkG9hqxZCFBaTiahPwfynP1dxBSRk9s5UTVc8LFeS4Btvkm9pc2C4H` (blk 410344005), `4BKBmAJn6TdsENij7CsVbyMVLJU1tX27nfrMM1zgKv1bs2KJy6Am2NqdA3nJm4g9C6eC64UAf5sNs974ygB9RsN1` (blk 410344009)
- Migration tx: `9zJGhyotEes1Ni5i4Qki5zUjApWhvWcr5rxJfiLhVGtnDuVzn9eFy1XzvtrZaj8r2SZYRmMQGftGQvDS1o2pPwE`
- Compromised admin: `H7PiGqqUaanBovwKgEtreJbKmQe6dbq6VTrw6guy7ZgL`; CVT mint `G84LEhbNMR1yYbHgHbnNYNSK8mpTKcazh5jcW5yMPQKo`; drainer `HkGz4KmoZ7Zmk7HN6ndJ31UJ1qZ2qgwQxgVqQwovpZES`
- Laundering: CCTP (~$230M to Ethereum), Wormhole (~$150M), then Tornado Cash; ~105,969 ETH consolidated
- SlowMist alert: x.com/SlowMist_Team/status/2039514728045982168 ("losses exceeding $200M... migrated to a 2/5 multisig (1 old + 4 new signers) without a timelock... minted fake CVT tokens")

## Checklist additions (admin/ops compromise class)

1. **Timelock on ALL privileged changes** — including multisig migrations, threshold
   changes, withdraw-guard raises. A 24–48h delay on the migration would have stopped this.
2. **Multisig threshold**: 2-of-5 for admin-over-user-funds is too low. 3-of-5+.
3. **Signing pipeline audit**: durable nonces / pre-signed txs that never expire;
   wallet legibility (what the signer actually approves); device separation.
4. **Admin capability enumeration**: what CAN a compromised admin do? If the answer
   includes "list arbitrary collateral, set arbitrary oracle, raise withdrawal guards
   to $500T", those capabilities need their own guards/caps/timelocks.
5. **Collateral admission**: new spot markets need minimum liquidity + TWAP history +
   multi-oracle quorum, not admin whim. "Fake token with wash-traded history" is the
   standard laundering-into-collateral play.
6. **Migration windows are attack windows** — social engineering concentrates there.
