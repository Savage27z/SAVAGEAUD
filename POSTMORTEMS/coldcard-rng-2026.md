# Coldcard hardware wallets — firmware RNG fallback, ~2,055 BTC / $130M+ (Jul 30, 2026 – ongoing)

**Lesson:** A security device had a **software fallback** when its hardware RNG wasn't
wired up — and the fallback was seeded from *public device state* (chip UID XOR timer),
so every seed generated over 5+ years lived in a brute-forceable space. "Offline" meant
nothing: attackers ran the search on their own machines and matched candidate
addresses against the public chain. Two audit takeaways: (1) in a security device,
**fail closed** — no hardware entropy, no key, ever, no "fallback"; (2) `#ifndef X`
checks only whether a macro **exists**, not whether it's non-zero — a define-as-zero
board flag silently selected the wrong RNG for years.

Sources: rekt.news/coldcard-rekt, Galaxy Research (Jul 31–Aug 3), Coinkite advisories,
Alex Thorn tallies.

## Timeline

- **Mar 17, 2021** — firmware v4.0.0 ships the libNgU ("Number Go Up") migration; the
  RNG bug enters production. Affects every seed generated **v4.0.0–v4.1.9** on Mk2/Mk3,
  and partially Mk4/Q/Mk5 (2022 reseed added secure-element entropy but only 32 bits
  reached the generator state).
- **Jul 30 01:10–01:51 UTC** — Wave 1: **1,196 addresses drained for 1,082.65 BTC** in
  41 minutes (blocks 960,183–960,191). Block's engineering team starts investigating
  from user reports same day; Galaxy maps flows the next day.
- **Jul 31** — Coinkite CEO (NVK) apology; guidance: **seeds generated before the patch
  must be replaced outright** — a firmware update does not fix already-generated seeds.
- **Aug 2** — Coinkite destroys remaining vulnerable inventory, halts shipments,
  releases patched firmware.
- **Aug 3** — Galaxy: losses exceed $100M; high-confidence tally 1,596 BTC from ~7,300
  addresses across 3 confirmed waves + 14 smaller incidents; candidate-inclusive
  estimate ~2,055 BTC (~$130M), potential >2,300 BTC (~$145M).
- **Aug 4–7** — At least **15 separate attackers** exploiting the flaw; 64.9 BTC into
  Wasabi, 200 ETH into Tornado Cash; 250+ victim reports to Alex Thorn; Galaxy tracking
  25+ attack patterns.

## The bug (plain English)

Coldcard's design: hardware TRNG only, no software randomness. The libNgU code checked
`#ifndef MICROPY_HW_ENABLE_RNG` before compiling — but Coldcard's board config
**defined that macro as 0** (they had their own hardware-RNG wrapper). `#ifndef` only
tests existence, not value. The reference resolved to MicroPython's built-in
`rng_get()` — the **Yasmarang software PRNG** — instead of the STM32 hardware RNG.

Yasmarang was seeded from:
- low 32 bits of the chip's **fixed UID**, XORed with the SysTick counter,
- mixed with two RTC register values,
- XORed against a second Yasmarang stream seeded from four **hardcoded public-source
  constants**.

None of those inputs is secret; none refreshes mid-stream. Attack economics: Mk2/Mk3
~**40-bit** search space (Coinkite estimate); Mk4/Q/Mk5 ~72-bit under Coinkite's
assumptions, but Block's limiting case: if UID, timer state, and RNG-call history are
known, generation is deterministic (2⁰ candidates); timer inputs are "correlated,
potentially observable." At most 2³² output streams once fallback state is fixed →
~2³¹ average trials. No phishing, no malware, no stolen device — just math against the
public blockchain.

## Receipts / verification handles

- Wave 1 blocks: 960,183–960,191 (41 min window)
- Tallies: 1,196 addresses / 1,082.65 BTC (Jul 30); 1,596 BTC / ~7,300 addresses (Aug
  3, high-confidence); ~2,055 BTC candidate-inclusive; 15+ attackers
- Affected: Mk2/Mk3 seeds from v4.0.0–v4.1.9 (no secure reseed, ~40-bit); Mk4/Q/Mk5
  partially (32-bit reseed)
- Sources: https://rekt.news/coldcard-rekt, Galaxy Research, Coinkite advisories

## Checklist additions (any code that generates secrets)

1. **No software fallback for hardware entropy.** If the TRNG is unavailable the
   device must refuse to operate, not quietly route to a PRNG. Look for any code path
   where randomness can come from a non-cryptographic source — grep `#ifndef`,
   fallback branches, and `random()` implementations in security contexts.
2. **`#ifdef`/`#ifndef` on possibly-zero macros.** Verify the *value*, not just
   existence: `#if MICROPY_HW_ENABLE_RNG` instead of `#ifndef`. Board-flag/compile-time
   config is a classic silent-wrong-path source.
3. **Seeds/keys generated under a vulnerable build are compromised forever.** A patch
   fixes future keys only; the remedy for past ones is rotation/replacement. Any
   "update will fix it" claim for generated secrets is wrong.
4. **Brute-force-ability is a function of seed entropy, not signing security.** When
   entropy collapses to device state, attackers search offline and match against the
   public chain — no interaction with the victim needed. Audit the *entropy source and
   seed*, not just the signature scheme.
5. **The real attack surface in 2026 is keys/signers/people, not contract code** —
   Drift $285M (admin key), KelpDAO $290M (RPC/infra), AFX $24M (validator keys),
   Coldcard $130M (RNG). Smart-contract audits matter; key-management and entropy
   audits matter as much or more.

## Sources
- https://rekt.news/coldcard-rekt
- Galaxy Research reports (Jul 31 – Aug 3, 2026)
- Coinkite / NVK public advisories (Jul 31 – Aug 2, 2026)
