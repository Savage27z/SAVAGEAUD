# Finding Template

## Reality Gate (Check before writing)

- [ ] I have a concrete exploit path — not speculation
- [ ] I can reproduce this on a fork or via on-chain call
- [ ] I have exact line numbers for the vulnerable code
- [ ] I have tested the happy path AND the exploit path
- [ ] This is not "owner can steal" (design choice)
- [ ] This is not "centralization risk" without exploitability

## Title
`[Bug Class] in [Contract/Function] allows [attacker] to [action]`

*Example: "Rounding Manipulation in redeem() allows depositor to extract 1 additional wei per cycle"*

## Severity
[Critical / High / Medium / Low / Informational]

See Impact Tiers in METHODOLOGY.md:
- T0: Critical — drain all funds, mint unlimited, brick contract
- T1: High — drain specific users, steal fees, grief withdrawals
- T2: Medium — drain dust, grief specific users, temporary DoS
- T3: Low — informational rounding, non-exploitable edge case
- T4: None — DO NOT REPORT (gas, style, missing events)

## Status
[Unverified / Confirmed / Fixed / Acknowledged / Disputed]

## Impact Litmus Test
> "An attacker can **\_\_\_\_\_** , resulting in **\_\_\_\_\_**."

## Summary
One or two sentences explaining the bug. Use plain language — analogies, no jargon.

## Vulnerability Detail
- **File:** `path/to/file.sol`
- **Function:** `functionName()`
- **Lines:** L123-L145

Detailed explanation of the vulnerability, how it works, and under what conditions it can be triggered. Start simple — imagine explaining to a builder who knows their code but hasn't thought about this edge case.

## Impact
What an attacker can achieve, and the financial impact (funds at risk, who is affected).

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
- [ ] No prior disclosure found

## Recommendation
How to fix the issue. Be specific — exact code change or logical pattern to add.

## References
- Link to relevant documentation
- Similar CVEs or disclosures
- Related CHECKLIST.md items
