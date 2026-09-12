#!/usr/bin/env python3
"""v2: parse findings from Shieldify reports by keying off finding BODIES."""
import os, re, json, glob
from collections import Counter

TXT = os.path.expanduser("~/.hermes/workspace/study/shieldify-txt")
OUT = os.path.expanduser("~/.hermes/workspace/study/shieldify-findings.json")

ID_RE = re.compile(r'\[([A-Z]{1,4}-\d{1,3})\]')
# body header: ID, then a title, then a Severity marker within the next ~600 chars
# body header: ID, then a title (must NOT contain another [ID] bracket — that stops the
# regex from spanning out of the summary table and across sibling findings), then Severity.
BODY = re.compile(r'\[([A-Z]{1,4}-\d{1,3})\]\s*((?:(?!\[)[\s\S]){0,300}?)\s*\n\s*Severity\s*\n\s*(.{0,80}?)\n', re.S)

# Fallback format variant (e.g. OffYield): "M-01\nM-01\nMEDIUM\nFIXED\n<Title>\nDescription"
BODY_ALT = re.compile(
    r'(?m)^([A-Z]{1,3}-\d{1,3})\n\1\n(CRITICAL|HIGH|MEDIUM|LOW|INFO)\n'
    r'(FIXED|ACKNOWLEDGED|RESOLVED|OPEN|PARTIALLY FIXED|UNFIXED)\n'
    r'((?:(?!\nDescription)[\s\S]){3,400}?)\n\s*Description', re.S)

def norm(s):
    s = re.sub(r'-\n', '', s)          # join hyphenation across lines
    s = re.sub(r'\s+', ' ', s)
    return s.strip(' .,:;')

reports = {}
for p in sorted(glob.glob(os.path.join(TXT, "*.txt"))):
    name = os.path.basename(p)[:-4]
    t = open(p, errors='ignore').read()
    counts = {}
    for m in re.finditer(r'[•\-\*]\s*(Critical|High|Medium|Low|Info(?:rmational)?)\s*issues?\s*:?\s*(\d+)', t, re.I):
        k = m.group(1).lower()
        counts['info' if k.startswith('info') else k] = int(m.group(2))
    seen, findings = set(), []
    for m in BODY.finditer(t):
        fid = m.group(1)
        if fid in seen:      # bodies appear once; guard against any repeat
            continue
        seen.add(fid)
        title = norm(m.group(2))
        sevblob = m.group(3).lower()
        sev = ('critical' if 'critical' in sevblob else
               'high' if 'high' in sevblob else
               'medium' if 'medium' in sevblob else
               'low' if 'low' in sevblob else
               'info' if ('info' in sevblob or 'gas' in sevblob or 'non-crit' in sevblob) else '?')
        st = t[m.end():m.end()+900]
        sm = re.search(r'\n\s*(Fixed|Acknowledged|Resolved|Open|Partially[ _]Fixed|Won\'t[ _]?Fix|Mitigated|Closed|Unmitigated)\s*\n', st, re.I)
        findings.append(dict(id=fid, title=title, severity=sev,
                             status=(sm.group(1) if sm else '')))
    # fallback pass for the alternate (bracket-less / uppercase) format
    for m in BODY_ALT.finditer(t):
        fid = m.group(1)
        if fid in seen:
            continue
        seen.add(fid)
        findings.append(dict(id=fid, title=norm(m.group(4)),
                             severity=m.group(2).lower(),
                             status=m.group(3).title()))
    # natural order: C, H, M, L, I  then numeric
    order = {'C': 0, 'H': 1, 'M': 2, 'L': 3, 'I': 4, 'N': 5, 'G': 6, 'A': 7, 'NC': 8}
    findings.sort(key=lambda f: (order.get(f['id'].split('-')[0], 9), int(f['id'].split('-')[1])))
    reports[name] = dict(counts=counts, findings=findings, n=len(findings), chars=len(t))

json.dump(reports, open(OUT, 'w'), indent=1, ensure_ascii=False)
print("reports:", len(reports), "| findings:", sum(r['n'] for r in reports.values()))
sev_tot = Counter(f['severity'] for r in reports.values() for f in r['findings'])
print("severity:", dict(sev_tot))
empty = [k for k, v in reports.items() if v['n'] == 0]
print("0-parsed reports:", len(empty), empty)
low = sorted(((v['n'], k) for k, v in reports.items()))[:10]
print("smallest reports:", low)
print("\n-- Abster --")
for f in reports['Abster-Security-Review']['findings']:
    print("  ", f['id'], '|', f['severity'], '|', f['title'][:80])
