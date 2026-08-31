# tx Chain / XRPL Bridge — Case Study (Aug 9, 2026, ~$200K XRP)

**Lesson:** Off-chain relayer verification logic is part of the trust model. Every relayer
ran the same flawed check: they confirmed the *memo format* instead of confirming the
*destination address and asset*. Majority consensus on shared wrong input = authorized drain.

## The mechanism

- 28 relayers sign off on withdrawals from the bridge's XRPL reserve wallet (17 needed).
- Deposit verification checked **memo formatting** (the bridge's expected memo pattern)
  but never confirmed the transaction's destination was actually the bridge vault,
  or that the expected asset/amount arrived.
- Attacker submitted fabricated deposit actions with the right memo → relayers (running
  the same flawed logic) attested the phantom deposits → 21/28 attested the first one.
- tx-side bridge logic credited **unbacked bridged XRP** against those phantom deposits
  — "issuing the receipts without putting anything into the vault" (CoinDesk) —
  then the attacker redeemed them for REAL XRP from the reserve wallet.
- 94 multisig-authorized withdrawals in 97 minutes (19:16–20:53 UTC): reserve dropped
  from ~200,410 XRP to 493.5 XRP. ~198,716–199,916 XRP stolen (~$200K).
- Funds moved through THORChain and Tornado Cash.
- XRPL "DefaultRipple" feature was also involved in the flaw chain.
- Team response: bridge halted, verification patched, FBI IC3 complaint filed.

## Why this matters for audits

- **No keys stolen, no on-chain exploit** — the code was "audited" (internal + third-party)
  and the flaw survived. The vulnerability was in the off-chain verification logic: what
  the relayers were asked to confirm.
- Any relayer/validator/keeper bridge with a majority-threshold model inherits this
  failure mode: **if all nodes run the same buggy check, the threshold is meaningless.**
- The generic pattern: "check the format" vs "check the fact". Memo present ≠ funds
  arrived. Signature valid ≠ message true.

## Checklist additions

1. **What exactly does the verification confirm?** Destination address? Asset type?
   Amount? Confirmations? Or just a formatted memo/field? Every field that can be
   attacker-supplied without on-chain consequence is a phantom-deposit vector.
2. **Majority on shared logic = single point of failure**: N-of-M relayers only help if
   the N nodes can disagree. Homogeneous software = one bug, M votes.
3. **Cross-check "receipts issued" vs "assets in vault"**: unbacked credit is the core
   invariant — like the Allbridge case, the bridge must pay only against observed value,
   never against declarations.
4. Non-EVM (XRPL) — for this class the audit surface is the relayer/observer software,
   not Solidity. Same trust-model review applies: what is treated as proof?
