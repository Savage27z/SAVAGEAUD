# TMAAR — Trust Model, Assumptions & Accepted Risks

Use this template at the start of every target audit. Fill it out in `TARGETS/<name>/TMAAR.md` before reading any contract code.

> Methodology inspired by Macro (0xmacro) audit reports.

## Actors & Trust Levels

| Actor | Trust Level | What They Can Do | What Happens If Compromised |
|-------|-------------|------------------|---------------------------|
| Protocol Owner/Admin | [High / Medium / None] | [e.g., Upgrade contracts, pause, withdraw] | [e.g., Can drain all funds if single EOA] |
| Users | None | [e.g., Deposit, withdraw, trade] | — |
| Vault Manager | [High / Medium / None] | [e.g., Allocate funds across pools] | [e.g., Can steal deposited capital] |
| Oracle/Resolver | High (must be correct) | [e.g., Settle outcomes, provide prices] | [e.g., Can manipulate settlement] |
| Relayer/Bot | [Medium / None] | [e.g., Submit messages, trigger actions] | [e.g., Can front-run or censor] |
| Bridge (LZ, CCIP, etc.) | High | [e.g., Relay cross-chain messages] | [e.g., Forge arbitrary messages] |
| Other actors | [Level] | [What they do] | [Failure mode] |

## Key Assumptions

These are things that MUST hold for the protocol to be secure. If any assumption fails, the protocol breaks.

1. **[Assumption 1]** — e.g., "Oracle returns correct prices within 60 seconds of any request"
   - *What if it fails?* — e.g., "Users can trade on stale prices, potentially causing losses"
2. **[Assumption 2]** — e.g., "Bridge messages cannot be forged"
   - *What if it fails?* — e.g., "An attacker can mint unbacked tokens on the destination chain"
3. **[Assumption 3]**
   - *What if it fails?*

## Accepted Risks

What the protocol acknowledges as out of scope or intentionally accepts:

1. **[Risk 1]** — e.g., "Users may lose funds if they sign arbitrary messages"
   - *Mitigation:* Users are warned in UI
2. **[Risk 2]** — e.g., "Owner can upgrade parameters within ±10% bounds"
   - *Mitigation:* Timelock on upgrade, no arbitrary code changes
3. **[Risk 3]**

## Attack Surface Summary

Given the trust model, what's the most interesting attack surface?

- **Primary trust assumption to attack:** [e.g., "Owner key is single EOA" or "Oracle fallback isn't gated"]
- **Most powerful attacker:** [e.g., "Compromised relayer + flash loan" or "Malicious vault manager"]
- **Can the protocol survive if [X] fails?** [Yes / No / Partially]
