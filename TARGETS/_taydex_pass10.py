#!/usr/bin/env python3
"""TayDex pass10: close two questions.
 (1) what address does Eq() return (the accessor every encoder calls)? -> decides whether the
     app's ABI is meant for 0x3ade22fa (=> live trade path has no implementation) or another
     deployment.
 (2) is THIRDWEB_SECRET_KEY an actual leaked value in the client bundle, or just an env lookup
     stub? A real secret in client JS is its own finding.
Read-only: local bundle mining.
"""
import json, os, re

TGT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "taydex")
RAW = os.path.join(TGT, "raw")
src = {f: open(os.path.join(RAW, f), encoding="utf-8", errors="replace").read()
       for f in os.listdir(RAW) if f.endswith(".js")}

ADDR = "0x3ade22fa1ef5ac75437a3734d91ba588e54875dd"

# ---------- (1) module 59652 body ----------
print("=" * 100)
print("(1) MODULE 59652  (defines Eq)  -- full body up to the next module")
print("=" * 100)
for f, s in src.items():
    m = re.search(r'59652:\(e,n,t\)=>\{', s)
    if not m:
        continue
    start = m.start()
    # capture a generous window, then stop at the next  '<digits>:(e,t,n)=>' module boundary
    win = s[start:start + 4000]
    nxt = re.search(r'\},\d{4,6}:\(', win)
    body = win[:nxt.start() + 2] if nxt else win
    print(f"--- {f} ---\n{body}\n")

# ---------- every occurrence of the core address, with context ----------
print("=" * 100)
print("(2) EVERY CONTEXT OF THE CORE ADDRESS")
print("=" * 100)
for f, s in src.items():
    for m in re.finditer(re.escape(ADDR), s, re.I):
        a = max(0, m.start() - 500)
        print(f"\n--- {f} @{m.start()} ---\n{s[a:m.end() + 500]}")

# ---------- (3) real secret-looking values ----------
print("\n" + "=" * 100)
print("(3) SECRET/KEY MATERIAL ACTUALLY PRESENT IN THE CLIENT BUNDLE?")
print("=" * 100)
PATTERNS = {
    "THIRDWEB_SECRET_KEY ref": r'THIRDWEB_SECRET_KEY',
    "NEXT_PUBLIC_ refs":       r'NEXT_PUBLIC_[A-Z0-9_]+',
    "privy/app secret refs":   r'[A-Z_]*(SECRET|PRIVATE_KEY|SERVICE_ROLE|API_KEY)[A-Z_]*\s*[:=]',
    "supabase URL":            r'https://[a-z0-9]{15,}\.supabase\.co',
    "supabase anon jwt":       r'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9\.[A-Za-z0-9_\-]{20,}\.[A-Za-z0-9_\-]{20,}',
    "sk- style key":           r'sk-[A-Za-z0-9]{20,}',
    "0x64 hex private key":    r'["\']0x[0-9a-fA-F]{64}["\']',
    "thirdweb clientId":       r'clientId\s*[:=]\s*["\'][0-9a-f]{20,}["\']',
}
for label, pat in PATTERNS.items():
    found = 0
    for f, s in src.items():
        for m in re.finditer(pat, s):
            found += 1
            if found <= 6:
                a = max(0, m.start() - 120)
                print(f"\n  [{label}] [{f}]\n     ...{s[a:m.end() + 160]}...")
    print(f"  ==> {label}: {found} hit(s)")

# ---------- (4) is there a chain gate on trading? ----------
print("\n" + "=" * 100)
print("(4) CHAIN GATE / ENV CONFIG for the contract address")
print("=" * 100)
for kw in ["NEXT_PUBLIC", "process.env", "activeChain", "defaultChain",
           "8453", "84532"]:
    for f, s in src.items():
        for m in re.finditer(re.escape(kw), s):
            a = max(0, m.start() - 80)
            seg = s[a:m.end() + 180].replace("\n", " ")
            if any(k in seg for k in ["Eq", "contract", "address", "0x3ade", "0x4be0",
                                      "0x85e2", "CHAIN", "chain"]):
                print(f"  [{f}] {kw:<14} ...{seg[:260]}...")
                break
