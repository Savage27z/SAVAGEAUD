# Cosmos EVM shared-module bug — MANTRA/TAC/KiiChain +3 chains, ~$15–21M (Aug 20–22, 2026)

**Lesson:** The fix existed **3 months before the exploit** and still three chains fell —
because a silent backport with vague release notes ("important security fixes") is not a
fix. If you find a critical in *shared infrastructure*, the severity framing + halt
guidance **is** the mitigation. Mechanically this is the same family as Provenance
(state divergence between two balance views): Cosmos bank (locked vs spendable vs
delegated) and the EVM statedb disagree, and the **sync arithmetic** between them
underflows. Audit the seams between two sources of truth, not each side alone.

Sources: rekt.news MANTRA/TAC/KiiChain investigations, BlockSec Aug newsletter, Cosmos
Labs postmortem (Aug 28), GHSA-7g4w-cg88-2cq2.

## The cluster (all times UTC, all from ONE shared cosmos/evm bug)

| Chain | Date | Drained | Value | Notes |
|---|---|---|---|---|
| MANTRA | Aug 20 | 720.9M OM | ~$3.6M | two wallets: 600M from burn addr + 120.9M genesis multisig; halt 14 min after 2nd drain; 94.7% hit one exchange; no recovery |
| TAC | Aug 22 | 2.986B TAC (~28% supply) | ~$7.5M | bonded-token pool; bridged to BNB in **95 seconds**; halt 4h12m later |
| KiiChain | Aug 22 | 148.3M KII | ~$9.7M nominal | **18 repeats vs 18 targets**; 54.4% frozen by halt, 45.6% bridged to BSC; only ~$1.6M realized |
| Nesa + 2 undisclosed | same week | — | — | Cosmos Labs postmortem: **six networks exploited** ecosystem-wide |

Loss sums: BlockSec ~$14.8M (three disclosed chains); rekt-news nominal sum ~$20.8M.
Values are pre-exploit spot — realized take was far lower (KiiChain sold 64.6M KII for
~$1.6M after the price collapse).

## The bug (plain English)

Cosmos accounts have *locked* and *spendable* balances. Locked tokens can't transfer,
but **can be delegated** to validators. The EVM side only tracks the spendable balance
and re-syncs it from Cosmos. The sync did the subtraction wrong: it subtracted the
delegated amount from the **existing spendable balance even when the delegation came
out of locked balance**.

1. Vesting account with 1 token delegates **1 wei more** than its spendable balance
   through the staking precompile → EVM-side balance **underflows to ~2²⁵⁶**.
2. Attacker sends that wrapped 2²⁵⁶ balance to a victim account → addition **overflows
   to zero** → victim's real balance lands on the attacker, victim left at zero.
3. Both fire inside **one supply-neutral transaction** — no new supply ever created,
   each drain capped at the victim's actual holdings.

The trick to trigger it: an ordinary wallet can't over-delegate. Attacker
**precomputes** the address a contract would deploy to, converts that *not-yet-existing
address* into a vesting account, then deploys the contract onto it — the contract
inherits vesting status on arrival and can over-delegate.

## Why three chains — the disclosure failure chain

| Date | Event |
|---|---|
| May 13–15 | Cosmos Labs PR #1176 "harden statedb balance…" — fix merged to main |
| Jul 27 | Berardinelli publishes full write-up "Printing Infinite Money on the Cosmos Blockchain" (had reported via HackerOne) |
| Aug 13 | Backport to release branches finally begins (PR #1254) |
| Aug 19 | v0.7.2 ships — notes only "important security fixes," recommends "coordinated upgrade" — **no CVE, no advisory, no severity** |
| Aug 20 07:16 | Public PR on Push Chain's fork of cosmos/evm describes vuln + exploit path (~12h before first attack) |
| Aug 20 19:04 | MANTRA hit |
| Aug 22 | TAC + KiiChain hit (TAC exploit 19:46:37) |
| Aug 24 | Cosmos Labs first acknowledges an "ongoing security incident" |
| Aug 25 | Cosmos Labs advises chains below v0.6.2/v0.7.2 to **halt** — 6 days after shipping the "fixed" release |
| Aug 28 | Postmortem: six networks exploited; CEX accounts frozen; no recovery figures |

Cosmos Labs' initial assessment "wrongly concluded the vulnerability did not threaten
production funds." MANTRA reported the live exploit directly; private patch notice went
out ~2h later **recommending upgrade, not halt**; the halt recommendation came ~1h after
Cosmos Labs learned TAC was also hit. By then the TAC bridge-out had already happened —
**95 seconds** from theft to BNB Chain.

## On-chain receipts

- MANTRA attacker: `mantra13n9sk3p8x7tpq9adgxvzv9q0qev953mld0hwva`
- TAC attacker (same on both chains): `0xecb0af97644d2c28c58369c663007a1b77c77c84`
- TAC theft: `0xae4e9b708ecef134a18aef8a1da9b4d24aa2a0e87f98d02695beae588cda46fc`
- TAC bridge (500M): `0xa0581dbd3bd988ae28b7f397f83623d11b1870c05230e2dc04f27c9e581174c4`; bridge (2.486B): `0xce24d86fe536b5e04616795aa5cb923e5d3f7e2305be61c2ecdfd9c904b89e7c`; TON (49.9M): `0xe7ec92b8a6c19d94863e6c4bf3ad49428006e50549dd5387665f665be077b2d7`
- KiiChain attacker (Kii & BSC): `0x0e7a96227fcf09f53d644ba6462d8c73993ef246`; helpers `0x8f37701914d60cee95ccaa39af959561045cf9e8`, `0x77308955c6cbc4cdef2e53defc7d78a007f29739`, `0x8cdab0fa359ac467c80c19de3fee5a543e258365`
- MANTRA halt: block 17,444,907 → 17,449,159 attack blocks; KiiChain halt: block 9,355,723 @ 22:50:58; TAC halt: block 24,671,475 @ 23:58:11

## Checklist additions

1. **Two sources of truth for one balance → audit the sync arithmetic.** Cosmos bank
   (locked/spendable/delegated) ↔ EVM statedb; marker struct ↔ bank module
   (Provenance). Subtraction on sync paths without guards = underflow to 2²⁵⁶. Grep
   every place a balance is recomputed from another system's view.
2. **"Fixed in main months ago" is not fixed for users.** Track whether security fixes
   are backported to *release* branches, whether advisories name severity, and whether
   operators are told to halt vs upgrade. The exploit hit 12h after a public fork PR
   described the path — public description + unpatchable production = countdown.
3. **Address-assumes-status attacks**: converting a *precomputed future contract
   address* into a vesting account means the contract inherits vesting semantics on
   deploy. Anywhere an account's type/status is set before code exists at that address
   is a seam.
4. **Expect one exploit kit to hit every fork.** TAC parameterized victim/beneficiary
   as calldata (MANTRA had them baked in as immutables) — "more reusable, not less."
   One chain's exploit = audit every sibling deployment of the same module/version.
5. **Validator records lied**: TAC's chain still showed 2.986B TAC as bonded while the
   backing pool held zero. On-chain "supply" invariants that read ledger state instead
   of actual module balances will miss the hole.

## Sources
- https://rekt.news/mantra-rekt / https://rekt.news/tac-rekt / https://rekt.news/kiichain-rekt
- https://blocksec.com/blog/defi-security-incidents-cosmos-evm-moonwell
- GHSA-7g4w-cg88-2cq2; Cosmos Labs postmortem Aug 28
