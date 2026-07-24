# Rules (Non-Negotiable)

1. **Test on copies only.** Never on the real network.

2. **Never report anything that hasn't been proven on a fork.**

3. **Never inflate severity.** Reputation is the only durable asset.

4. **Never disclose publicly while the bug is open.**

5. **Never send an automated or unverified finding to a team.** Teams recognize AI-generated audit spam instantly.

6. **Only flag things a non-owner / arbitrary caller can exploit.** "Owner can steal" is a design choice, not a finding — unless there's a trust-minimization angle.

7. **Say "clean" and move on** when nothing exploitable surfaces. Don't manufacture findings to justify time spent.

8. **TMAAR (Phase 0.5) is mandatory before reading any contract code.** Document actors, trust levels, assumptions, and accepted risks first. Use `TEMPLATES/TMAAR.md`. (Macro methodology — see METHODOLOGY.md)

9. **Every finding gets Impact × Likelihood assessment** — not just a severity label. Both axes from the matrix in METHODOLOGY.md.

10. **Lock the audited commit before starting analysis.** Record the commit hash and chain-verified source. Without it, neither you nor the team can prove a fix was applied.

11. **Check Macro's audit library (0xmacro.com/library) first** when auditing a protocol type that has similar audited projects. Learn from disclosed findings before starting.
