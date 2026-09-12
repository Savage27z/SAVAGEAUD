# TOOLS/shieldify-corpus — corpus mining pipeline

Reusable pipeline for turning an audit firm's **public report portfolio** (100+ PDFs) into a
severity-weighted pattern ranking. Built and validated on Shieldify's 125-report portfolio
(1022 findings). Output: `POSTMORTEMS/shieldify-125-corpus-2026.md` +
`POSTMORTEMS/refs/shieldify-125-pattern-ranking.md`.

## Run order

```bash
# 0. get the reports
git clone --depth 1 https://github.com/shieldify-security/audits-portfolio /tmp/shieldify
#    -> PDFs land in /tmp/shieldify/reports/

# 1. extract text from every PDF (pymupdf)        -> <corpus>-txt/*.txt + <corpus>-index.json
python3 extract_shieldify.py

# 2. parse findings per report (ID/title/severity/status)  -> <corpus>-findings.json
python3 parse_shieldify.py

# 3. optional: keyword classifier (fast, LOW accuracy — see warning)  -> clusters + unclassified list
python3 cluster_shieldify.py

# 4. LLM-label a 150-title sample to MEASURE the keyword classifier   -> labels-hybrid.json
python3 label_hybrid.py

# 5. LLM-label ALL titles (the authoritative run)                     -> labels-all.json
python3 label_all.py

# 6. final ranking: family counts + severe density                    -> final-llm.json
python3 final_shieldify.py
```

Edit the `SRC`/`OUT` paths at the top of scripts 1–2 for a different corpus.

## Hard-won pitfalls (these cost real time)

1. **Parse finding BODIES, not the summary table.** A title regex that spans the summary table will
   silently swallow the next finding (`[\s\S]` crossing into a sibling's body). Fix: make the title
   group refuse to cross a `[` — `((?:(?!\[)[\s\S]){0,300}?)`. Symptom: one finding missing and a
   neighbour carrying the wrong severity. Validate by hand against one report you've read.
2. **TOC matches the same patterns as bodies.** Never `t.find("Findings Summary")` (hits the contents
   page). Key off the bodies.
3. **Format variants exist inside one portfolio.** One report used bracket-less IDs
   (`M-01\nM-01\nMEDIUM\nFIXED\n<Title>\nDescription`) and uppercase `SEVERITY`. Add a fallback regex
   and then prove it by re-checking that report against its own summary counts.
4. **Always validate parsed counts against the report's own "N High / N Medium" bullets.** Achieved
   105/116 exact here; the mismatch list is itself a finding (mostly Info-band over-counts).
5. **MEASURE your classifier before publishing its output.** The keyword scorer looked plausible and
   scored **59.3%** agreement vs an LLM on 150 seed-fixed titles. Publish only the measured run, and
   keep the accuracy number in the writeup.
6. **The LLM endpoint here is a reasoning model.** With `max_tokens=4000` it spends ~9k tokens
   thinking and returns **empty content** — looks like a parse bug, is a budget bug. Use
   `max_tokens=32000` with batches of ~25 and concurrency 3. Retry thin batches; save incrementally.
7. **`classify()` in `cluster_shieldify.py` returns a TUPLE `(family, score)`.** Unpack `[0]` if you
   reuse it — otherwise you get 0 matches and 0% agreement with no error.
8. **Image-only PDFs are invisible to pymupdf** (~2 chars/page). Detect via chars-per-page < 100 in
   the index. RapidOCR needs its ONNX models cached; if the fetch stalls it burns CPU forever with no
   output — check for `.onnx` on disk before starting, and don't let it run unattended.
