#!/usr/bin/env python3
"""TayDex pass4: extract (a) the core contract ABI, (b) the exact createMarket tx construction,
(c) the server-signed request/response shape, (d) the unique /api route list.
Read-only: local bundle mining only.
"""
import json, os, re

TGT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "taydex")
RAW = os.path.join(TGT, "raw")
CORE = "0x3ade22fa1ef5ac75437a3734d91ba588e54875dd"

src = {f: open(os.path.join(RAW, f), encoding="utf-8", errors="replace").read()
       for f in os.listdir(RAW) if f.endswith(".js")}

out = {}

# ---------- (a) ABI blobs ----------
# viem ABIs appear as arrays of {inputs:[...],name:"...",outputs:[...],stateMutability:"...",type:"..."}
print("=" * 78)
print("(a) ABI BLOBS")
print("=" * 78)
abi_rx = re.compile(r'\[\s*\{\s*"inputs"')
for f, s in src.items():
    for m in abi_rx.finditer(s):
        # walk to the matching close bracket
        start = m.start()
        depth, i = 0, start
        while i < len(s):
            if s[i] == "[":
                depth += 1
            elif s[i] == "]":
                depth -= 1
                if depth == 0:
                    break
            i += 1
        blob = s[start:i + 1]
        if len(blob) < 40:
            continue
        try:
            abi = json.loads(blob)
        except Exception:
            continue
        names = [e.get("name") or e.get("type") for e in abi if isinstance(e, dict)]
        if len(abi) >= 3:
            print(f"\n--- {f}  ({len(abi)} entries) ---")
            print("   ", ", ".join(str(n) for n in names[:60]))
            out.setdefault("abis", []).append({"file": f, "entries": len(abi),
                                               "abi": abi})

# ---------- (b) createMarket tx construction ----------
print("\n" + "=" * 78)
print("(b) createMarket TX CONSTRUCTION (from page chunk)")
print("=" * 78)
pg = src.get("page-a3d3f86b50b38cc5.js", "")
for kw in ["sign-create", "signMarket", "createMarket", "marketId", "params.deadline",
           "fundingPerOption"]:
    for m in re.finditer(re.escape(kw), pg):
        a = max(0, m.start() - 420)
        print(f"\n  ...{pg[a:m.end()+420]}...")
        break

# ---------- (c) the sign-create request body ----------
print("\n" + "=" * 78)
print("(c) request bodies sent to the signer")
print("=" * 78)
for m in re.finditer(r'body:\s*JSON\.stringify\(\{', pg):
    start = m.start()
    depth, i = 0, pg.find("{", start)
    while i < len(pg):
        if pg[i] == "{":
            depth += 1
        elif pg[i] == "}":
            depth -= 1
            if depth == 0:
                break
        i += 1
    seg = pg[m.start():i + 1]
    if len(seg) < 700:
        print("\n  " + seg)
out["sign_create_bodies"] = True

# ---------- (d) unique api routes ----------
routes = set()
for s in src.values():
    for m in re.finditer(r'["\'`](/api/[A-Za-z0-9_\-/]+)', s):
        routes.add(m.group(1))
print("\n" + "=" * 78)
print(f"(d) UNIQUE /api ROUTES ({len(routes)})")
print("=" * 78)
for r in sorted(routes):
    print("  ", r)

json.dump(out, open(os.path.join(TGT, "pass4_abi.json"), "w"), indent=1)
print(f"\n[saved] pass4_abi.json  ({len(out.get('abis', []))} ABI blobs)")
