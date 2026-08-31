# Casino & Gambling Contract Exploits — Case Study Library

Ten verified cases across the gambling/casino/prediction class. Hot-wallet key thefts
(Stake $41M, BC.GAME infrastructure) excluded — these are CONTRACT-LEVEL bugs.

## The canonical RNG classes

### 1. SmartBillions lottery — blockhash prediction (Ethereum, Sep 2017, ~400 ETH)
Winner chosen from `blockhash(block.number)` known **in advance**. Attacker's proxy
replicated the exact RNG, computed the winner index before buying tickets, and **only
bought tickets in rounds where the precomputed winner was himself**. Every losing round
skipped for free; winning round paid the full jackpot.
→ **On-chain entropy is not randomness.** Any game using blockhash/block data for
outcomes can be gamed by a contract that computes first and commits selectively.

### 2. EOSBet ×2 — forged transfer notification (EOS, Sep+Oct 2018, ~$538K)
`apply()` accepted `transfer` actions from ANY contract code (not just `eosio.token`).
Attacker's contract invoked EOSBet's transfer handler with a **fake notification — no
EOS moved** — casino credited a phantom deposit and paid out real prize EOS.
→ **The EOS analog of Allbridge**: the "proof of deposit" (a transfer notification the
attacker can forge) was trusted instead of observed value. Fix: one assertion
(`code == eosio.token`).

### 3. DEOS Games — RNG replication (EOS, Sep 2018, ~$24K)
Deterministic chain → attacker ran the same code with the same parameters, computed the
roll, bet only on wins. House edge inverted.
→ Same class as #1: any on-chain-derived randomness is precomputable by a sibling contract.

### 4. EOS.WIN / EOSPlay wave — txid prediction + rollback + congestion (EOS, 2018-19, ~$1M+)
RNG mixed `txid`, `tapos_block`, `bet_id` resolved via deferred tx. Attacker ran 6
contract accounts sharing identical block metadata; **5 probe accounts checked the
outcome notice — if it lost, they processed normally; if it won, they raised an
exception so the whole tx rolled back, preserving the winning `bet_id` for the final
large bet.** Win rate 20% → ~74%. EOSPlay variant: staked ~900K EOS via REX to congest
the network, becoming the only party able to transact → RNG from previous blocks fully
predictable → "win every roll".
→ **Transaction rollback as an oracle**: the ability to revert based on outcome =
free option. Any game where the loser can avoid committing loses its edge.

### 5. Chainlink VRF subscription re-roll (2023, white-hat, $300K bounty)
Malicious subscription owner could **block the randomness callback from being mined,
inspect the value, then re-submit until favorable** (re-roll).
→ Integrating VRF is not the end of the review: subscription ownership, fulfillment
gas, and the request→callback state machine must prevent selective fulfillment.

### 6. Fomo3D — block stuffing + PRNG (Ethereum, Aug 2018, ~10,469 ETH prize)
High-gas contracts filled blocks near game end so rival key purchases couldn't mine →
attacker guaranteed last buyer. Plus an exploitable airdrop PRNG.
→ **Block stuffing** (fee-market manipulation) is a state-machine attack on
time-based games; jackpot PRNG from on-chain state is exploitable by contracts.

## The economic / settlement classes

### 7. ZKasino — no withdrawal path (Ethereum, Apr 2024, ~$33M)
"Bridge" accepted ETH with a 2x-bonus promise; after deposit phase, team locked funds
"for staking", never provided a redeem function. Operator controlled the vault; Dutch
FIOD arrested the founder.
→ **The ABSENCE of a user-facing withdrawal state machine is itself a critical
finding.** "Locked" is a state — who can transition it, and does the user have a path?

### 8. Polymarket/UMA — $7M false resolution via oracle vote concentration (Polygon, Mar 2025)
"Will Ukraine agree to Trump's mineral deal before April?" — settled YES by ~25% of UMA
votes from one actor (5M UMA across 3 accounts), 9¢ → 100%. No cryptographic proof the
event occurred; token-weighted settlement is purchasable.
→ Prediction-market settlement design (bond size, quorum, whitelisted proposers,
vote timing) is a first-class security property.

### 9. Polymarket Paris weather — oracle SOURCE manipulation (Polygon, Apr 2026, ~$34K)
A hair dryer pointed at the Charles de Gaulle temperature sensor (captured on video!)
triggered settlement of Paris daily-temperature markets in favor of pre-created accounts.
Météo France filed a criminal complaint.
→ **The oracle layer is the attack surface, including its physical inputs.** Contracts
must enforce source redundancy/aggregation.

### 10. BC.GAME — third-party game bug (multi-chain, Mar 2026, $4,326,700)
Exploit of "a vulnerability in a third-party game"; provider never disclosed. Attacker
doxxed within hours, moved $1.7M to Hyperliquid, shorted ETH 18x, lost ~90% in <20h.
→ Opaque third-party game integrations = unvetted RNG/odds/settlement. The only
documented casino-specific 2026 loss.

## Checklist for gambling targets (add to every game/casino audit)

1. **Where does the outcome come from?** Blockhash/block data → precomputable.
   VRF → check subscription ownership + re-roll. Off-chain server → trust model.
2. **Can the loser avoid committing?** If a bet can revert after seeing the outcome
   (rollback, deferred tx, gas griefing), the house edge is an option the attacker sells.
3. **Selective participation**: can the player skip losing rounds and only enter
   winning ones? (SmartBillions pattern.)
4. **What is "proof of deposit"?** Actual token movement into the vault, or a
   notification/message the caller can forge? (EOSBet / Allbridge pattern.)
5. **Is there a user withdrawal path at all?** No redeem function = rug-shaped.
6. **Who can settle, and what proves the outcome?** Single source, aggregatable
   data, token-weighted votes — all capturable.
