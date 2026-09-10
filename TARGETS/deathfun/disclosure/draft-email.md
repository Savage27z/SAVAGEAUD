**To:** (no security contact found — see note at bottom)
**Subject:** DeathFun `increaseBet()` — missing payment check and missing replay protection (private disclosure)

> **STATUS: DRAFT — CORRECTED 2026-09-10.** The previous revision claimed a player could
> exploit this by replaying a note they obtained through normal app use. That claim was
> wrong and has been removed. See the correction note at the bottom for what changed and why
> — do not send the old version.

Hi death.fun team,

I'm an independent security researcher. I found a defect in your deployed DeathFun contract
(`0x27EDd16eE56958fddCBA08947f12C43DDeC2B20C` on Abstract). Sending this privately before any
public writeup. Nothing was ever run against mainnet, no real funds were touched, and no admin
signature was requested or forged.

**The issue — `increaseBet()`**

This function adds ETH to an active game, authorized by a signed note from your backend. Two
checks are missing:

1. **The payment is never verified.** The function is `payable`, but nothing compares `msg.value`
   to the `amount` it credits. Your `createGame()` gets this right — it signs `msg.value` into the
   hash, so the signature is bound to a specific payment. `increaseBet` signs only `amount`.
2. **The note is never consumed.** There is no record of which signed notes have been redeemed.
   The only bound is `deadline`.

Combined, the contract permits the same signed note to be submitted repeatedly, each time
crediting the full `amount` to `betAmount`, with no payment attached after the first. The
contract relies entirely on the off-chain caller to choose the correct `msg.value`.

**What we verified, and how**

We confirmed the contract's behaviour end-to-end on a local zkEVM fork of your deployed
bytecode (Abstract needs a zkEVM-aware Foundry build; getting that working was its own project,
and I'm happy to share it). Using a test key installed as an admin **on the fork copy only** via
`vm.store`, a test account paid 1 wei for a real game, then replayed a single signed
`increaseBet` message 7 times, ending with a recorded bet of 35 ETH and no further ETH ever
required.

**Important, and I want to be precise about it:** that fork test demonstrates what the *contract*
permits **given a valid signature**. It does not demonstrate that an external party can obtain
one — the test grants itself admin rights to get there. So please read the proof as "the
function is missing its guards," not "someone can already do this."

**That precondition matters, so here is everything we know about it**

- Your client bundle contains **no code that handles `serverSignature`** — every occurrence in
  the shipped JavaScript is inside an ABI definition, and the only `createGame` call-site is a
  gas estimate built on placeholder arguments. The browser never receives a note.
- The session-key grant in your app names the **server wallet** as the signer, so the backend
  builds, signs and submits these calls.
- I scanned the full history of the contract. `increaseBet` was called **7,329 times between
  11 March and 12 April 2026**, then **not once in the five months since**. There is no player-
  facing button for it today, and no API route for it either.
- Across all 7,329 calls: every one attached exactly the signed amount, and **no signature was
  ever reused.** So this was not exploited, and there is no bad state to clean up.

**Why I'm still reporting it**

The function is public, live on your proxy, and unguarded. Its safety currently depends on your
backend always choosing the right `msg.value` — which is a property of the caller, not of the
contract. Any new caller breaks that: a future client, a partner integration, the operator/
provider mode, or simply a third deposit function copy-pasted from `increaseBet` (it already
diverges from `createGame`, and there are no nonces anywhere in the contract).

**Fix is small** — bind `msg.value` into the signed hash, and track consumed signatures (e.g.
`mapping(bytes32 => bool)` keyed on the message hash). Happy to share the exact diff.

No ask beyond getting this in front of you. I'll hold off on anything public until you've had a
chance to look at it.

Thanks,
[your name / handle]

---

### Correction note (kept for the record, not for sending)

The first revision of this email stated that *"anyone who has ever gotten ONE legitimate note
from your backend"* can replay it, and described the fork signature as
*"legitimately-obtained."* Both were wrong:

- The fork PoC installs its own test key as admin (`vm.store`, `isAdmin` slot) — it manufactures
  the signature rather than obtaining one.
- The live client never handles a signature, so no player ever holds a note to replay.

The underlying defect (two missing checks) is unchanged and still real. Only the exploitability
claim changed. Sending the old version would have been a false claim that the team could disprove
in minutes.

*Note: no security contact page, bug bounty program, or security.txt found on death.fun or their
GitHub org (`github.com/Death-fun`, which only hosts a client-side hash-verifier tool). Sending
via [their support/Twitter/whatever channel you pick] — swap this note out once you've picked a
delivery channel.*
