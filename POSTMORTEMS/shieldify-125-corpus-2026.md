# Shieldify public portfolio — 125 audits, 1022 findings, mined for a severity-weighted pattern ranking (2024 – Sept 2026)

**Lesson:** **finding volume and finding severity are almost unrelated — and the corpus proves it.**
The single most common family in 125 real audits (`input_validation`, 115 findings) is **3% severe**.
The family that actually carries money (`reward_accounting`, 56 findings) is **39% severe**. If you
triage by how often a bug class appears, you will spend your time on the cheapest bugs. **Rank by
severe density, then read volume only to decide how much to care about the tail.** Four families —
docs, events, pause polish, auctions — account for 96 findings and **zero** Criticals or Highs.
They belong in a report; they do not deserve depth.

**Second lesson, and the more uncomfortable one:** the highest-severity cluster in the whole corpus
(10 of 34 Criticals) is one shape repeated — **an authorization layer that validates against the
attacker's own state.** Session-key modules that read the *caller's* expiry, never check whether a
key is already owned by another wallet, and never consume the signature. That is the same bug the
filed `pattern-trace-2026-09` Pattern 1 describes (Provenance, Term Finance) and the same shape as
the OLY import's F3/F11. **Third appearance in three weeks, in a different domain each time:
governance, then vault accounting, now ERC-4337.** The pattern is not rare. The *domain* is what
changes.

---

## What this is

`github.com/shieldify-security/audits-portfolio` — Shieldify Security's **public portfolio of 125
completed audits** (147 Solidity entries + 7 Solana/Rust, 1 Move, 1 Vyper, 1 Cosmos/Go, plus 4
penetration tests and 3 off-chain reviews), dated from 2024 through September 2026, 5 undisclosed.
The index carries ID, protocol, type, and date for 165 entries; `reports/` holds 125 PDFs (408 MB).

Unlike a single firm report, this is a **distribution over many protocols** — which is why it can
answer "what actually goes wrong in real engagements" instead of "what went wrong once".

## Method (and what I threw away)

1. **Extract.** pymupdf over all 125 PDFs → 2,725,702 chars, 0 extraction errors.
2. **Parse findings.** Keyed on finding bodies (`[ID] … Severity`) rather than the summary tables —
   a table-first regex silently spanned the table into a body and swallowed a finding (caught because
   Abster's `H-01` went missing and `L-03` came back with the wrong severity). Fixed with a
   bracket-negative title. One report used a bracket-less/uppercase format; added a fallback.
   **Result: 1022 findings.**
3. **Validate against the reports' own numbers.** Each report prints "N High, N Medium…" bullets.
   Parsed counts match **exactly for 105 of 116** reports that print them. The 11 mismatches are
   mostly Informational over-counts (a report's summary counts 17 Infos while its body writes 26),
   three are ±1 in Medium/Low. Residual error is small and confined to the non-severe band.
4. **Classify — and discard the first classifier.** A weighted keyword scorer over 27 families
   looked good until it was measured: **59.3% agreement** with an LLM pass on a seed-fixed 150-title
   sample. That is not publishable. All 1022 titles were then LLM-classified into the fixed taxonomy.
   The 59.3% figure is kept in the ranking doc deliberately — a 59%-accurate classifier produces
   confidently wrong priority lists, and the only reason this one didn't ship is that it was measured.

## The corpus in numbers

- **1022 findings** across 118 reports (7 with none: 3 image-only scans, 4 clean passes).
- **Critical 34 (3.3%) · High 98 (9.6%) · Medium 269 (26.3%) · Low 381 (37.3%) · Info 237 (23.2%).**
- **106 of 125 reports contain no Critical finding.** Criticals live in 19 reports.
- Most findings in one report: Futaba 38 · CrushTrading 35 · PearProtocol-Vault 33 · GeodeFinance 31.
- Most Criticals in one report: **Etherspot Credible Account Module, 8.**

## The ranking (severity-weighted)

Full table with examples: `POSTMORTEMS/refs/shieldify-125-pattern-ranking.md`.

| family | n | % corpus | C | H | severe | % of family severe |
|---|---|---|---|---|---|---|
| reward_accounting | 56 | 5.5% | 7 | 15 | **22** | **39%** |
| access_control | 106 | 10.4% | 8 | 13 | **21** | 20% |
| funds_locked_dos | 98 | 9.6% | 3 | 17 | **20** | 20% |
| fee_tax | 40 | 3.9% | 2 | 8 | 10 | 25% |
| web2_offchain | 40 | 3.9% | 0 | 9 | 9 | 22% |
| rounding_precision | 26 | 2.5% | 3 | 4 | 7 | 27% |
| slippage_mev | 44 | 4.3% | 2 | 4 | 6 | 14% |
| input_validation | **115** | **11.3%** | 0 | 4 | **4** | **3%** |
| gas_optimization | 88 | 8.6% | 1 | 0 | 1 | 1% |
| docs_spec / events_returns / pause / auction | 96 | 9.4% | 0 | 0 | **0** | **0%** |

**Read it twice.** `reward_accounting` is 5.5% of the corpus and 39% severe. `input_validation` is
the largest family and 3% severe. `gas_optimization` is 8.6% of the corpus by count and produces
one severe finding in 125 audits.

### The shapes worth carrying forward

- **`reward_accounting`** — the vault/reward-accrual gauntlet from the OLY import (F8) is the same
  thing: who is eligible, when, computed from what, with what rounding, and can a zero/dead stake
  break a guard. Highest-yield family in the corpus, and it is *checkable* on any staking system.
- **`funds_locked_dos`** — the only family in both the top-3 by volume and top-3 by severity. Locked
  funds are the most common *severe* outcome: not theft, just funds nobody can move. Under-audited
  because it looks like a UX bug.
- **`rounding_precision`** — 2.5% of corpus, 27% severe. Small, sharp, cheap to check. Includes
  `convertToShares` rounding the wrong way on withdrawal (ERC-4626 mandates round-up) and missing
  decimal normalisation when comparing balances of different tokens (OLY H-04/H-07, exact same bug).
- **`fee_tax`** — 25% severe. Referral/fee routing is consistently wrong: fees charged to the
  protocol instead of returned, fees paid when not due, config able to dodge fees entirely.
- **`web2_offchain`** — 0 Criticals, 9 Highs. Frontend/parameter/decimals handling and error
  handling on the off-chain side is a **High**, not a footnote. Worth stating because it is
  systematically under-audited.
- **`reentrancy`** — 12 findings, 1 severe across 125 audits. In this corpus it is the *lowest*-yield
  famous bug class. That is a claim about *this corpus*, not about Solidity generally — but it is a
  reminder that the classic checklist order is not the risk order.

## The Etherspot cluster — 10 of 34 Criticals

`Etherspot - Credible Account Module` (23 findings, 8 Criticals), `- CAM-Migration`, and
`- Gas Tank Paymaster Module`. Every Critical is the same shape: **the module trusts something the
attacker supplies.**

- `enableSessionKey()` — no uniqueness check → silently overwrites existing session data
- `enableSessionKey()` — never checks the key isn't already registered to **another wallet** →
  **an attacker can hijack any active session key** and point it at their own wallet
- `disableSessionKey()` — reads `sessionData[_sessionKey][msg.sender].validUntil`, i.e. the *caller's*
  expiry, which is always 0 for the disabler role → the check becomes `0 >= block.timestamp` → always
  false → validation effectively skipped for the privileged path
- `onInstall`/`onUninstall` — `msg.sender` is never authenticated; `sender` is parsed out of calldata
  and treated as real → **anyone can install/uninstall the validator module on any wallet**
- `validateUserOp()` — the signature proof is never consumed → replayable
- `validateUserOp()` — insufficient checks → drain the modular wallet

Root cause in one line: **`msg.sender` is not the caller when the caller is a module, and a key's
identity is not its value.** Both are the "assume the honest path" failure — and they are the
highest-consequence bugs in this corpus because a modular smart wallet holds everything.

## Directly useful to us

**Robinhood Chain has 4 public reports in this portfolio: `Up`, `OffYield`, `Topaz Dex`, `Trace`.**
OffYield parsed fully (2 Medium / 4 Low / 6 Info — Morpho-Vault-V2 provisional-interest exposure,
unpausable exits, `p.spent` ledger disagreement). `Up` is an image-only scan (see gaps).
Abstract-chain protocols are heavily represented (Onchain Heroes, DEPTH, Souls.club, Spellborne,
Pudgy Strategy, Aborean, Infinite Beyond, Roots of Embervault, Shiny, Dropster, Tollan Universe) —
relevant because we audited death.fun on Abstract. Also Berachain (Berally, BeraRoot, Beraji-KO)
and Hyperliquid (Harmonix, Pear, Crush Trading, HLOS, Buoy).

This is a **prior-art map for two of our hunting grounds**: before touching any Robinhood Chain or
Abstract target, read what already broke on those stacks. BountyForge's "What Changed" method —
read disclosed reports for similar protocols before starting — now has a corpus to draw from.

## Known gaps (do not paper over)

1. **3 reports are image-only scans with no text layer** — `Bankroll-Vault` (41p), `Buoy` (37p),
   `Up` (21p) = 99 pages. RapidOCR was attempted: it stalled for 20+ minutes producing zero output
   (ONNX models not cached, fetch never completed) and was killed rather than left burning CPU.
   So the extraction covers **122 of 125** reports. **`Up` is a Robinhood Chain protocol — the
   single highest-value remaining gap.** Needs a working OCR path (`pip install rapidocr-onnxruntime`
   alone is not sufficient on this box; the model fetch must succeed).
2. **4 reports are genuine clean passes** (Ambire, Beef's Finance, Berally-StakingV2, Terplayer-BeraBTC
   Token) — 5–6 pages, no findings. These are correctly zero, not extraction failures.
3. Corpus is **Solidity-dominant**. 7 Solana/Rust reports are in scope but the taxonomy was designed
   around EVM vocabulary; Solana-specific families (account validation, PDA seeds, CPI) are
   under-represented. Don't read these rankings as cross-language.
4. Family labels are single-label per finding. Real findings are often two families at once
   (e.g. "unchecked return + funds locked"). Counts in one family therefore understate the
   prevalence of the underlying behaviour.

## Receipts

- Source tweet: https://x.com/jeffsecurity/status/2098477013451337824 (Jeff Security, 2026-09-11,
  linking shieldify-security/audits-portfolio)
- Repo: https://github.com/shieldify-security/audits-portfolio (125 PDFs in `reports/`, 408 MB)
- Totals verified against each report's own summary bullets: 105/116 exact match on the severities
  the report itself prints.
- Criticals enumerated and individually read: 34. Reports with ≥2 Criticals: Etherspot-CAM 8,
  Guanciale-Stake 3, HarmonixFinance-Hyperliquid 3, Futaba 2, GeodeFinance-WM 2, PudgyDAOs 2, Yeet 2.
- Standalone Criticals read in full include: Harmonix C-01 (first-depositor share inflation) and C-02
  (`convertToShares` rounds down on withdrawal), PearProtocol-Vault C-01 (withdraw/redeem burns any
  owner's shares, no authz), PudgyDAOs C-01 (`claim()` drains vested tokens via unvalidated `dao`
  address), Terplayer-BVT C-01 (ceiling division underflow locks **all** withdrawals), Guanciale-Stake
  C-01 (UD60x18 scalars never scaled → voting power always equals stake), Futaba C-01 (light-client
  `verify()` skips account-proof verification depending on a mapping branch), Yeet C-01 (`stake()`
  called externally → `msg.sender` becomes the contract → rewards lost).
- Local artifacts + reusable scripts: `~/.hermes/workspace/study/`
  (`extract_shieldify.py`, `parse_shieldify.py`, `cluster_shieldify.py`, `label_hybrid.py`,
  `label_all.py`, `final_shieldify.py`; data: `shieldify-findings.json`,
  `shieldify-labels-all.json`, `shieldify-final-llm.json`). Mirrored into the repo under
  `TOOLS/shieldify-corpus/`.
- Companion files: `POSTMORTEMS/refs/shieldify-125-pattern-ranking.md` (grep-able ranking + examples),
  `POSTMORTEMS/oly-pashov-66-2026.md` (single-report import, 66 findings, 12 shapes),
  `POSTMORTEMS/pattern-trace-2026-09.md` (Pattern 1 — authz from the attacker's default state).
