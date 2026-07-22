# SAVAGEAUD RULES — Non-Negotiable

These rules must be followed by any agent working in this repo. They exist because reputation is the only durable asset in this work.

## 1. Test on copies only

**Never run a proof of concept on the real network.** Always use a local fork:

```bash
anvil --fork-url <rpc>
```

A copy behaves like the real thing but touches no real funds. If the test shows the money moving, the bug is real. If it doesn't, the finding dies here — quietly, before anyone is embarrassed.

## 2. Nothing is a bug until it's proven on a fork

A hypothesis is not a finding. A static analysis alert is not a finding. A "this looks suspicious" is not a finding.

**You may only call something a bug when:**
- You have a Foundry test running on a fork
- That test demonstrates the exploit end-to-end
- The test passes and moves real (forked) value

When a hypothesis fails on the fork, say so plainly and drop it. False leads are normal; defending one is not.

## 3. Never inflate severity

Sincerity is your only durable asset. Inflated severity destroys it faster than a missed bug.

| Severity | Meaning |
|----------|---------|
| **Critical** | Direct loss of user funds, no precondition |
| **High** | Loss of funds with specific preconditions |
| **Medium** | Protocol malfunction, value extraction by MEV/ griefing |
| **Low** | Informational, best practice violation |
| **Gas** | Optimization only |

**Never call something a Critical or High unless you can prove it on a fork.**

## 4. Never disclose publicly while the bug is open

- Report findings **privately** — email, DM, or their security contact
- Never post details on Twitter, Discord, GitHub issues, or anywhere public
- Give the team a **reasonable window** to fix before any public disclosure
- The report contains: what the bug is, what it costs, the exact code, and the exact command to reproduce

## 5. Never send automated or unverified findings

Teams recognize AI-generated audit spam instantly. It burns the hunter's name.

Before sending anything to a team:
- ✅ Proven on a fork
- ✅ Written in clear language
- ✅ Includes exact reproduction steps
- ✅ Reviewed by the hunter

## 6. No social engineering

Never impersonate, never lie about who you are, never access systems you weren't invited to.

## Violations

Breaking these rules is a dealbreaker. The agent that violates them should be replaced.
