# TMAAR — death.fun (Mines-style on-chain casino, Abstract L2)

## Actors & Trust Levels

| Actor | Trust Level | What They Can Do | What Happens If Compromised |
|-------|-------------|-------------------|------------------------------|
| Owner (single EOA, `Ownable`/`OwnableUpgradeable`) | High | Upgrade the proxy implementation, `addAdmin`/`removeAdmin`, `withdrawFunds` (full bankroll) | Total — can rewrite all game logic, drain the entire bankroll directly |
| Admins (backend signer(s), owner-appointed via `addAdmin`) | High | Sign `createGame`/`cashOut`/`markGameAsLost`/`increaseBet` messages authorizing player actions; can also call `cashOut`/`markGameAsLost` directly with NO signature at all (bypassed via `isAdmin[msg.sender]` check); `payReferral` | A compromised admin key can directly call `cashOut` on any active game for any `payoutAmount` up to the bankroll balance — no additional check beyond `isAdmin` |
| Players | None | `createGame` (pay bet), `cashOut`/`markGameAsLost` (with valid admin signature), `increaseBet` (with valid admin signature) | Can attack signature-verification gaps in `increaseBet` — see F01 |
| Off-chain backend (not on-chain, holds admin signing key(s)) | High (must be honest and must correctly gate what it signs) | Determines game outcomes off-chain (mines-style tile logic), decides what `payoutAmount`/`amount` to sign | Everything about "provable fairness" here rests on this backend signing only what it actually intends — the on-chain contract enforces almost nothing about the RELATIONSHIP between real payments and signed amounts (see F01) |

## Key Assumptions

1. **A signed `increaseBet` message is only ever submitted once, for the amount of ETH the
   player actually sends alongside it.**
   - *What if it fails?* **This is F01.** Confirmed false by direct source read: `increaseBet`
     is `payable` but never checks `msg.value == amount`, and never marks a (gameId, amount,
     deadline) tuple as consumed — the same valid signature can be submitted repeatedly until
     its deadline, each time crediting `amount` to `game.betAmount` regardless of what (if
     anything) was actually paid.
2. **`game.betAmount` (the on-chain record) is either purely informational, or if the backend
   trusts it for anything (odds, payout sizing, limits, reconciliation), that trust is safe
   because the on-chain value can't be manipulated for free.**
   - *What if it fails?* On-chain, nothing derives `payoutAmount` from `betAmount` — `cashOut`'s
     payout is independently admin-signed every time, so THIS contract's own logic doesn't turn
     a free `betAmount` inflation into a direct drain. But we have no visibility into the
     off-chain backend (closed-source) — if IT reads on-chain `betAmount` or the `BetIncrease`
     event to decide odds/limits/anything, F01 becomes a direct path to a bigger drain. This is
     an explicit, acknowledged unknown — flagged rather than assumed either way.
3. **Admin private key(s) are held securely and not reused elsewhere.**
   - *What if it fails?* Total loss — admin can single-handedly authorize arbitrary payouts up
     to the bankroll. Standard centralization risk for this architecture (RULES.md #6 — not
     itself a finding, this pattern is explicit/inherent to how signed-settlement casino
     contracts work), but worth noting there's no multisig/timelock visible, and `cashOut`
     specifically allows an admin to bypass signature verification ENTIRELY when calling
     directly.
4. **Signed messages are correctly scoped to this specific deployed contract.**
   - *Checked, not assumed — verified false in the general sense but not currently exploitable.*
     `messagePrefix` is a plain string with no binding to `address(this)` or `block.chainid`
     anywhere in the hash construction (`DeathFun.sol` L178-189, L248-258, L304-312, L354-361).
     Directly compared the OLD contract (`0x0D55076685EcB11c0Caf4fa749D26823B509d03E`) against
     the current one (`0x27EDd16eE56958fddCBA08947f12C43DDeC2B20C`) via live `eth_call`:
     `messagePrefix()` differs (`"DeathFun"` vs. `"DeathRaceGame:createGame"`), so cross-contract
     replay between these two specific contracts does NOT work in practice today. But nothing
     stops a future redeploy from reusing the same prefix — this is a real hardening gap
     (missing EIP-712-style domain separation), not a live exploit. Worth fixing regardless.

## Accepted Risks

1. **Off-chain, closed-source RNG/settlement backend.** Same category of limitation as this
   repo's Astro entry (FINDINGS.md #29) — the actual "mines" outcome logic isn't verifiable from
   what's public. The client-side `death-fun-provably-fair` repo only verifies a hash
   after the fact; it can't prove the backend didn't see the bet before committing the seed, or
   that seeds are genuinely unpredictable. Documented as an explicit limitation, not assumed
   safe.
2. **Upgradeable proxy, single owner, no timelock observed.** Standard early/mid-stage
   centralization risk for a contract holding real live TVL (~$44K).

## Attack Surface Summary

- **Primary trust assumption to attack:** the binding (or lack thereof) between what an admin
  signs and what actually happens on-chain — F01 is exactly this seam (access control on WHO
  can call `increaseBet` is fine; the ECONOMIC content of what a valid call actually costs is
  not enforced).
- **Most powerful attacker:** any player who has ever received one valid `increaseBet`
  signature from the backend (i.e., anyone who has ever used the normal "add to bet" UI flow
  once) can replay it indefinitely before its deadline, for free.
- **Can the protocol survive if F01 is exploited repeatedly?** Depends entirely on the
  unverifiable off-chain question in Assumption 2 above. If the backend trusts on-chain
  `betAmount`/`BetIncrease` for anything payout-relevant: no, this is a direct bankroll drain
  path. If not: it's "only" a public, permanently-falsifiable on-chain record (misleading
  `getGameDetails()` output, fake `BetIncrease` event volume) — still worth fixing, lower
  stakes.
