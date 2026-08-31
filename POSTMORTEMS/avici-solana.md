# Avici — $190 → $670K Signature-Verification Bug (Solana, Aug 29-31, 2026, ongoing)

**Lesson:** A cross-instruction signature check that points at the WRONG instruction
verifies the attacker's own signature — and grants admin on 1,100+ user accounts.
Individual-user drains, one at a time: 8,857 transactions and counting.

## The mechanism (Officer's Notes)

- Wallet created Aug 28 13:40 UTC, funded with $190 USDC (gas only). Drain started
  16:49. Same pattern on every account:
  1. submit a signature bundle
  2. call `AddCollateralAdmin` and become admin
  3. withdraw
- **The second signature check pointed back at instruction 0** — Solana verified the
  attacker's own signature a second time. The program credited an admin key it should
  never have accepted. Attacker became admin on **1,100+ collateral accounts**.
- Median take $24; largest in sample $5,268. First ~$576K left between 18:19-18:34 UTC.
- **Not a treasury drain, not a stolen upgrade key** — every dollar came from
  individual user accounts.

## Checklist additions (Solana/Anchor program verification)

1. **Cross-instruction signature verification**: when a CPI/instruction verifies a
   signature, WHICH instruction's signer list does it read? If it reads `instruction 0`
   (or a hardcoded index) instead of the current instruction, an attacker can satisfy
   the check with their own signature. Verify the index is the current instruction.
2. **Admin-grant paths**: any `AddXAdmin`/role-grant instruction must re-verify the
   caller's authority against the CURRENT instruction's signers, not a stale bundle.
3. **Per-account impact thinking**: a bug that grants admin on ONE account is worth
   the median account balance × 1,100 accounts — enumerate the blast radius.
4. Same class as our Solana forensics methodology: pin deployed program vs repo;
   check instruction discriminators for the admin path.

## Receipts
- Officer's Notes: x.com/officer_secret/status/2093746738360185011
- Wallet: created Aug 28 13:40 UTC; drain from 16:49; ~$576K out 18:19-18:34 UTC
