#!/usr/bin/env python3
"""Extract text + finding metadata from all Shieldify audit PDFs."""
import os, re, json, glob
import pymupdf

SRC = os.path.expanduser("~/.hermes/workspace/study/shieldify/reports")
OUT = os.path.expanduser("~/.hermes/workspace/study/shieldify-txt")
os.makedirs(OUT, exist_ok=True)

# generic finding header patterns across firms
HDR = re.compile(
    r'(?m)^\s*(?:\[)?((?:C|H|M|L|I|NC|G|CR|HI|MED|LO|INFO)[-_]?\d{1,3})(?:\])?\s*[-–—:.)]\s*(.{3,140})$',
    re.I)
SEV_WORD = re.compile(r'(?i)\b(critical|high|medium|low|informational|informational|gas)\b')

rows = []
for p in sorted(glob.glob(os.path.join(SRC, "*.pdf"))):
    name = os.path.basename(p)
    try:
        d = pymupdf.open(p)
    except Exception as e:
        rows.append(dict(file=name, error=str(e))); continue
    pages = [pg.get_text() for pg in d]
    txt = "\n\f\n".join(pages)
    open(os.path.join(OUT, name[:-4] + ".txt"), "w").write(txt)
    # de-dupe headers: TOC repeats them
    hdrs = []
    seencount = {}
    for m in HDR.finditer(txt):
        title = re.sub(r'\s+', ' ', m.group(2)).strip()
        hdrs.append((m.group(1).upper(), title))
    rows.append(dict(file=name, pages=len(pages), chars=len(txt),
                     n_headers=len(hdrs), headers=hdrs))
    d.close()

json.dump(rows, open(os.path.expanduser("~/.hermes/workspace/study/shieldify-index.json"), "w"),
          indent=1, ensure_ascii=False)
print("reports:", len(rows))
print("bytes of text:", sum(r.get('chars', 0) for r in rows))
print("errors:", [r['file'] for r in rows if r.get('error')])
