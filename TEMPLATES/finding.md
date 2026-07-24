# Finding Template

## Reality Gate (Check before writing)

- [ ] I have a concrete exploit path — not speculation
- [ ] I can reproduce this on a fork or via on-chain call
- [ ] I have exact line numbers for the vulnerable code
- [ ] I have tested the happy path AND the exploit path
- [ ] This is not "owner can steal" (design choice)
- [ ] This is not "centralization risk" without exploitability
- [ ] I've documented the trust model assumptions this finding relies on

## Title
`[Bug Class] in [Contract/Function] allows [attacker] to [action]`

*Example: "Rounding Manipulation in redeem() allows depositor to extract 1 additional wei per cycle"*

## Severity
[Critical / High / Medium / Low / Code Quality / Gas / Informational]

## Impact × Likelihood

| Axis | Rating | Rationale |
|------|--------|-----------|
| **Impact** | [Critical / High / Medium / Low] | What's at stake? Funds? Locked state? User grief? |
| **Likelihood** | [High / Medium / Low] | How easy is it to trigger? Any prerequisites? |

**Final severity** is the intersection of both axes per the matrix in METHODOLOGY.md.

*Example: High impact + Low likelihood → Medium severity*

## Status
[Unverified / Confirmed / Fixed / Addressed / Acknowledged / Won't Do / Disputed]

| Status | Meaning |
|--------|---------|
| Unverified | Not yet confirmed on fork |
| Confirmed | Reproduced on fork or via on-chain call |
| Fixed | Team deployed fix |
| Addressed | Team acknowledged and plans to fix |
| Acknowledged | Team noted it, no fix planned |
| Won't Do | Team decided not to fix (documented risk) |
| Disputed | Team disagrees this is a bug |

## Root Cause Classification
What category does this bug fall under?
- [ ] Access control / authorization
- [ ] Arithmetic / rounding
- [ ] Validation / input sanitization
- [ ] Reentrancy / cross-function
- [ ] Oracle / price manipulation
- [ ] Bridge / cross-chain
- [ ] Upgrade / proxy
- [ ] MEV / front-running
- [ ] Design / economic
- [ ] Logic / state machine

## Impact Litmus Test
> "An attacker can **______** , resulting in **______** ."

## Summary
One or two sentences explaining the bug. Use plain language — analogies, no jargon.

## Vulnerability Detail
- **File:** `path/to/file.sol`
- **Function:** `functionName()`
- **Lines:** L123-L145
- **Audited commit:** `<hash>` (commit this was found against)

Detailed explanation of the vulnerability, how it works, and under what conditions it can be triggered. Start simple — imagine explaining to a builder who knows their code but hasn't thought about this edge case.

**Root cause:** What was the developer's mistake? What check was missing?
**Consequence:** What happens as a result of the bug?
**Remediation:** How to fix it (exact code or logical pattern).

## Proof of Concept
```solidity
// Foundry test demonstrating the exploit
// Must be copy-pasteable — triager runs it and sees the same result
// Minimal: shortest sequence of calls that proves impact
function testExploit() public {
    // Setup
    // Attack
    // Assert
}
```

## Dedup Check
- [ ] Searched Solodit for this bug class on this protocol type
- [ ] Checked target's changelog / release notes
- [ ] Checked target's GitHub Issues for similar reports
- [ ] Checked Macro audit library for similar findings
- [ ] No prior disclosure found

## Recommendation
How to fix the issue. Be specific — exact code change or logical pattern to add.

For Macro-style clarity, structure as:
```diff
- // Before (buggy code)
+ // After (fixed code)
```

## Team Response
[From the team after disclosure — what they said they'd do]

## References
- Link to relevant documentation
- Similar CVEs or disclosures
- Related CHECKLIST.md items
- Macro library report (if applicable)
