# BonkDAO Vote-Capture — Case Study (Jul 6, 2026, $20M, Solana)

**Lesson:** A treasury governed by token-weighted voting is worth the market cost of a
temporary majority. With no timelock, "proposal passes" and "funds leave" are the same
transaction. **"If that number is ever favorable to an attacker, and nothing sits between
'proposal passes' and 'funds leave', you do not have a treasury. You have an order book."**

## The mechanism

- BonkDAO ran on Solana's SPL Governance (Realms). One token, one vote.
- Attacker spent **~$4.4M buying BONK** (~1% of supply, sized to clear quorum with
  minimal excess) through exchange wallets over several days, quietly.
- Submitted **BIP-76 "Sowellian BonkDAO"** — dressed as a turnaround plan (new council,
  monetize holdings, "yes" voters get a BONK reward — the reward was theater). The real
  payload: transfer **4.43 trillion BONK (~$20M)** from the treasury to the proposer's wallet.
- Proposal sat **public for 6 days**. Turnout: **2.9%** (7 wallets voted; 18,000+ members
  didn't). Final tally: 882.38B yes vs 879.95B quorum — **bought the exact margin, 99.9% yes**.
- **No timelock, no veto, automatic execution** → the transfer ran the moment the vote
  resolved. Late, quiet vote = no time for the minority to react.
- No contract bug, no key leak, no flash loan needed. "The code did exactly what it was
  told, by whoever paid the most to tell it."

## Why this matters for audits

- This is the same governance-capture family as Term Finance, but with a LIQUID vote
  market instead of an empty electorate: cost-to-control was $4.4M vs $20M treasury
  (the "BonkDAO ratio"). The ratio is public math — auditors can compute it for any DAO.
- The missing controls: **timelock** (a delay between pass and execute = interruptible),
  **real participation floor**, and **treasury-vs-vote-cost awareness**.
- Audits certify code is bug-free while the system is trivially capturable — **capture
  is not a bug**, but it's the finding that matters. Same meta-lesson as Term Finance:
  the governance layer is the attack surface.

## Checklist additions

1. **Compute the takeover ratio for every DAO-governed treasury**: (market cost of a
   quorum-crossing majority) vs (value controlled). If favorable to an attacker → finding,
   even with perfect code.
2. **Timelock between proposal-pass and execution** — mandatory. Without it, a
   late-resolving vote is an atomic drain.
3. **Participation floor on what basis?** (Term: 5% of wrapped supply = free.
   Bonk: quorum in absolute tokens = buyable.) Measure against something the attacker
   can't cheaply satisfy.
4. **Proposal payload review**: treasury-moving instructions inside "community" proposals
   — the auditor's equivalent of reading the fine print. Any proposal with a transfer
   instruction to a proposer-controlled address is a red flag to simulate.
