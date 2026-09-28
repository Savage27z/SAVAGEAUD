#!/usr/bin/env python3
"""TayDex pass3: re-fetch bundle chunks, persist raw, mine the ABI + EIP-712 signing flow.
Why: the frontend MUST encode the fixer/enum + build the EIP-712 signature. Its own code is
the cheapest source for (a) the ABI of 0x3ade22fa.. and (b) the exact typed-data struct fields
-> the binding table. Read-only: GETs of public static assets, no writes, no txs.
"""
import json, os, re, sys, urllib.request

TGT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "taydex")
RAW = os.path.join(TGT, "raw")
os.makedirs(RAW, exist_ok=True)

UA = ("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36")

bundle = json.load(open(os.path.join(TGT, "pass1_bundle.json")))
urls = bundle["chunks"]

fetched = {}
for u in urls:
    name = u.rsplit("/", 1)[-1]
    path = os.path.join(RAW, name)
    if os.path.exists(path) and os.path.getsize(path) > 0:
        fetched[u] = open(path, encoding="utf-8", errors="replace").read()
        continue
    try:
        req = urllib.request.Request(u, headers={"User-Agent": UA,
                                                 "Referer": "https://taydex.fun/",
                                                 "Accept": "*/*"})
        body = urllib.request.urlopen(req, timeout=45).read()
        open(path, "wb").write(body)
        fetched[u] = body.decode("utf-8", errors="replace")
        print(f"[ok]  {len(body):>9,}B  {name}")
    except Exception as e:
        print(f"[ERR] {name}: {e}")

print(f"\nfetched {len(fetched)}/{len(urls)} chunks, {sum(len(v) for v in fetched.values()):,}B total\n")

def hits(pattern, label, flags=re.I, ctx=160, cap=14):
    rx = re.compile(pattern, flags)
    out = []
    for u, src in fetched.items():
        for m in rx.finditer(src):
            a = max(0, m.start() - ctx)
            out.append((u.rsplit("/", 1)[-1], src[a:m.end() + ctx]))
    print(f"=== {label}: {len(out)} hits ===")
    for f, s in out[:cap]:
        print(f"  [{f}] ...{s.strip()[:300]}...")
    print()
    return out

# --- 1. ABI-shaped fragments: the core contract's function signatures ---
hits(r'"name"\s*:\s*"(claim|dispute|cancelMarket|setSigner|setFeeRecipient|markets|getMarket|nonces|resolveMarket)"',
     "ABI entry names (core surface)", cap=30)

# --- 2. EIP-712 typed data: the binding table ---
hits(r'primaryType', "EIP-712 primaryType", cap=10)
hits(r'EIP712Domain', "EIP-712 domain", cap=10)
hits(r'types\s*:\s*\{[^}]{0,80}', "typed-data `types:` blocks", cap=10)

# --- 3. The outcome index the frontend passes to claim ---
hits(r'claim\w*\s*[:(]\s*[\[{]', "claim call sites", cap=10)
hits(r'(outcome|winningOutcome|resolvedOutcome|outcomeIndex)\s*[:=]', "outcome index refs", cap=18)

# --- 4. signer / signing endpoints ---
hits(r'(sign|signature|requestSignature)\s*[:(]\s*["\'/]', "signing endpoints", cap=14)
hits(r'/api/[a-zA-Z0-9_\-/]{2,40}', "api routes", cap=40)

# --- 5. UMA wiring + addresses ---
hits(r'optimisticoracle|uma\.|OOv3|0x[A-Fa-f0-9]{40}', "addresses/oracle", cap=6)
print("=== distinct 0x addresses seen ===")
addrs = {}
for u, src in fetched.items():
    for m in re.finditer(r'0x[0-9a-fA-F]{40}', src):
        addrs.setdefault(m.group(0).lower(), set()).add(u.rsplit("/", 1)[-1])
for a, fs in sorted(addrs.items()):
    print(f"  {a}  ({len(fs)} file(s))")
