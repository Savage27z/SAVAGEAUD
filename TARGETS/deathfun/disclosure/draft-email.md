**To:** (no security contact found — see note at bottom)
**Subject:** Confirmed bug in DeathFun's increaseBet() — free bet inflation via signature replay — private disclosure

Hi death.fun team,

I'm an independent security researcher. I found and confirmed a real bug in your deployed
DeathFun contract (`0x27EDd16eE56958fddCBA08947f12C43DDeC2B20C` on Abstract). Sending this
privately before any public writeup, standard responsible-disclosure practice. Everything below
was verified on a local fork of your actual deployed bytecode — nothing was run against
mainnet, no real funds were touched, and no admin signature was requested or produced.

**The bug — `increaseBet()`**

This function lets a player add more ETH to an active game, authorized by a signed note from
your backend. It's missing two checks:

1. It never verifies that the ETH actually sent matches the amount the note says. Your
   `createGame()` function does this correctly (it signs `msg.value` into the hash); `increaseBet`
   doesn't.
2. It never marks a note as used. There's no record anywhere of which signed notes have already
   been redeemed.

Put together: anyone who has ever gotten ONE legitimate "increase bet" note from your backend can
resubmit that exact same note to the contract as many times as they want, before it expires,
paying nothing after the first time. Each resubmission adds the full amount to their recorded bet
for free.

**Proof, read-only version** — attached (`F01-attacker-view.js`) is a small script that
constructs the exact call this requires: the message hash your contract expects, and the raw
calldata for calling `increaseBet` with 0 ETH attached. It does not send anything anywhere — no
signer, no broadcast — it's there so you can see exactly what fields matter without needing to
trust us or set up any tooling. Run it yourself, it's pure local computation.

**Proof, fully executed version** — we also ran this end-to-end against your real deployed
contract on a local zkEVM fork (Abstract's chain type needs a patched Foundry build to do this at
all, which was its own project — happy to share that too if useful to you). Result: a test
account paid 1 wei total for a real game, then replayed one legitimately-obtained
`increaseBet` signature 7 times, ending with a recorded bet of 35 ETH. Zero additional ETH ever
required after the first wei.

**One honest caveat, worth telling you directly:** we played through your app's actual UI for a
bit and never found a button that triggers `increaseBet` at all — it doesn't look like your
current website exposes this feature to regular players. That doesn't make the bug less real
(it's a public function on a public contract; anyone with a wallet and a script can call it
directly, no UI required), but it may mean current real-world exposure is lower than the function
itself suggests. Wanted to be upfront about that rather than overstate it.

Whether this becomes a real drain depends on something we can't see from outside: does your
backend ever trust the on-chain `betAmount` (or the `BetIncrease` event) for anything — payout
sizing, odds, limits? If so, this is a direct path to draining funds from the ~$44K bankroll. If
your backend keeps its own independent ledger and ignores this on-chain value, the practical
impact is smaller (a falsifiable public record / fake wagered-volume stats), but the missing
checks are real either way and worth fixing.

**Fix is small** — two lines: check `msg.value == amount`, and track used signatures (e.g. a
`mapping(bytes32 => bool)` keyed on the message hash). Happy to share the exact diff.

No ask here beyond getting this in front of you. We'll hold off on anything public until you've
had a chance to look at it.

Thanks,
[your name / handle]

---
*Note: no security contact page, bug bounty program, or security.txt found on death.fun or their
GitHub org (`github.com/Death-fun`, which only hosts a client-side hash-verifier tool). Sending
via [their support/Twitter/whatever channel you pick] — swap this note out once you've picked a
delivery channel.*
