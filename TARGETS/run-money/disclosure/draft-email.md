**To:** info@runmoney.app
**Subject:** Two confirmed bugs in ClubPool's bonus accounting (funds not at direct risk, but claims are broken) — private disclosure

Hi Run Money team,

I'm a independent security researcher. I looked at your deployed ClubPool contract
(`0x1089Db83561d4c9B68350E1c292279817AC6c8DA` on Base) and found two real bugs in the
bonus-distribution logic. Sending this privately before any public writeup, per standard
responsible-disclosure practice. Everything below was verified on a local fork against your
actual deployed bytecode — nothing was run against mainnet, no funds were touched.

Both bugs live in `recordActivity()`, in how it snapshots an athlete's stake when marking them
compliant/non-compliant.

**Bug 1 — an athlete can inflate their share of the weekly bonus pool**
When someone is marked compliant, the contract locks in whatever their stake happens to be *at
that exact moment* and uses it forever after to size their share of that week's yield payout.
Nothing stops someone from temporarily staking a large amount right before that check, then
withdrawing it straight back out afterward — the frozen number sticks around for the rest of
the week regardless. In our fork test, an account with only 10 USDC of real, ongoing stake
walked away with about 100x the bonus of an account that genuinely staked 1,000 USDC the whole
week.

**Bug 2 — one member's normal activity can break bonus claims for everyone else that week**
This one doesn't need anyone doing anything wrong. If a member adds more to their stake after
being marked compliant, then later has an off week and gets marked non-compliant, the contract
subtracts their *current* stake from the shared pool total instead of the amount that was
actually counted when they joined it. Depending on the numbers, this either:
- zeroes out the shared total, which makes *every other compliant member's* bonus claim revert
  for that week, or
- underflows and reverts outright, which permanently locks that member as "compliant" for the
  rest of the week no matter what they actually do afterward.

One more note for realism: the PoC uses a large inflated stake just to make the ratio obvious in
a test. Against the pool's actual current size, someone wouldn't need anywhere near that — a
much smaller amount briefly parked would already dominate the real compliant-stake total, so
this isn't a whale-only concern.

Separately, unrelated to the two bugs above but noticed while reading: `mint()` calls
`_safeMint()` (which can trigger a callback into the caller) before finalizing the athlete's
stake record and before the ETH is wrapped into Aave. If a contract reenters `stake()` during
that callback, its deposit goes through for real, but `mint()` then overwrites the athlete's
record back to zero right after, permanently losing track of that stake (no function can
recover it afterward). This one only hurts whoever triggers it, not other users — just worth
fixing the order of operations while you're in there.

Neither of the two main bugs touches staked principal directly — deposits are always withdrawable through your
normal `unstake()` — but both break the actual product (fair, working weekly rewards), and Bug 2
in particular can happen from completely ordinary use, no bad actor required.

We noticed your app's live TVL widget is currently showing $0.00 even though the contract itself
still holds roughly $2,088 USDC and 0.35 ETH — wanted to flag that alongside this, in case it's
related to the Strava/DB migration issue you posted about in June. Whatever's going on there,
real funds are still sitting in a contract with these open issues, so figured it was worth
reaching out even without a live bounty program.

Happy to share the actual PoC code (Foundry tests run against a Base fork, reproducible,
"don't trust me, run it yourself") if useful. No ask here beyond getting this in front of you —
let me know if you'd like the details, and we'll hold off on anything public until you've had a
chance to look.

Thanks,
[your name / handle]
