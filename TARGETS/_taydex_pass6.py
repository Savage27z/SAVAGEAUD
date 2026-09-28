#!/usr/bin/env python3
"""TayDex pass6: extract the FULL core-contract ABI from the app bundle to disk, then answer
three questions by reading it exactly (no inference):
  1. the exact component list of createMarket / buy / sell  -> is any address bound?
  2. every function's stateMutability + which setters exist -> privilege surface
  3. the signed-trade flow the app actually uses
Read-only: local bundle mining.
"""
import json, os, re

TGT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "taydex")
RAW = os.path.join(TGT, "raw")
CORE = "0x3ade22fa1ef5ac75437a3734d91ba588e54875dd".lower()

src = {f: open(os.path.join(RAW, f), encoding="utf-8", errors="replace").read()
       for f in os.listdir(RAW) if f.endswith(".js")}

# --- locate the full JSON ABI array (the one with internalType components) ---
def parse_abi_strict(blob):
    """Parse a JS/JSON ABI array. Keys may be unquoted and booleans may be !0/!1."""
    cands = [blob, re.sub(r'([{,]\s*)([A-Za-z_$][\w$]*)\s*:', r'\1"\2":', blob)]
    for cand in list(cands):
        cands.append(cand.replace("!0", "true").replace("!1", "false"))
    for cand in cands:
        try:
            v = json.loads(cand)
            if isinstance(v, list):
                return v
        except Exception:
            pass
    return None

best = None
for f, s in src.items():
    for m in re.finditer(r'\[\s*\{', s):
        start = m.start()
        if "internalType" not in s[start:start + 3000]:
            continue
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
        if len(blob) < 3000 or "internalType" not in blob:
            continue
        abi = parse_abi_strict(blob)
        if abi and len(abi) > 20 and any(e.get("type") == "function" for e in abi):
            if best is None or len(abi) > len(best[1]):
                best = (f, abi)
            continue
        # fall back: stash the raw region so it can be inspected/parsed by hand
        if best is None:
            raw_path = os.path.join(TGT, "abi_raw_region.txt")
            with open(raw_path, "w") as fh:
                fh.write(f"// from {f}, {len(blob)} bytes, unparsed\n")
                fh.write(blob)
            print(f"[note] ABI region from {f} did not parse; dumped {len(blob)}B "
                  f"-> abi_raw_region.txt")

if not best:
    raise SystemExit("no full ABI found")

f, abi = best
path = os.path.join(TGT, "abi_core.json")
json.dump(abi, open(path, "w"), indent=1)
print(f"[saved] abi_core.json  <- {f}   ({len(abi)} entries)\n")

funcs = [e for e in abi if e.get("type") == "function"]
events = [e for e in abi if e.get("type") == "event"]
errors = [e for e in abi if e.get("type") == "error"]

def sig(e):
    ins = []
    for i in e.get("inputs", []):
        t = i.get("type", "?")
        if t == "tuple":
            t = "(" + ",".join(c.get("type", "?") for c in i.get("components", [])) + ")"
        elif t == "tuple[]":
            t = "(" + ",".join(c.get("type", "?") for c in i.get("components", [])) + ")[]"
        ins.append(t)
    outs = []
    for o in e.get("outputs", []):
        t = o.get("type", "?")
        if t == "tuple":
            t = "(" + ",".join(c.get("type", "?") for c in o.get("components", [])) + ")"
        outs.append(t)
    return f"{e['name']}({','.join(ins)})" + (f" -> ({','.join(outs)})" if outs else "")

print("=" * 78)
print(f"WRITE FUNCTIONS ({sum(1 for e in funcs if e.get('stateMutability')!='view')})")
print("=" * 78)
for e in funcs:
    sm = e.get("stateMutability")
    if sm != "view":
        print(f"  [{sm:>10}] {sig(e)}")

print("\n" + "=" * 78)
print("VIEW FUNCTIONS")
print("=" * 78)
for e in funcs:
    if e.get("stateMutability") == "view":
        print(f"  [view] {sig(e)}")

print("\n" + "=" * 78)
print("SIGNED-STRUCT COMPONENT LISTS  (does any bind an address?)")
print("=" * 78)
for e in funcs:
    for i in e.get("inputs", []):
        if i.get("type") == "tuple":
            comps = i.get("components", [])
            addr = [c for c in comps if "address" in c.get("type", "")]
            print(f"\n  {e['name']}  struct p:")
            for c in comps:
                print(f"      {c.get('type'):<12} {c.get('name')}")
            print(f"      --> ADDRESS FIELDS: {[c.get('name') for c in addr] or 'NONE'}")

print("\n" + "=" * 78)
print(f"EVENTS ({len(events)})")
print("=" * 78)
for e in events:
    ins = ", ".join(f"{i.get('type')}{' indexed' if i.get('indexed') else ''} {i.get('name')}"
                    for i in e.get("inputs", []))
    print(f"  {e['name']}({ins})")

if errors:
    print("\n" + "=" * 78)
    print(f"CUSTOM ERRORS ({len(errors)})")
    print("=" * 78)
    for e in errors:
        ins = ", ".join(f"{i.get('type')} {i.get('name')}" for i in e.get("inputs", []))
        print(f"  {e['name']}({ins})")

# --- the signed-trade flow in the app ---
print("\n" + "=" * 78)
print("SIGNED-TRADE FLOW (how the app obtains a buy/sell signature)")
print("=" * 78)
trade = src.get("69191-0d044baaec4da351.js", "") + src.get("page-a3d3f86b50b38cc5.js", "")
for kw in ["sign-trade", "signTrade", "quote", "/api/trade", "buySig", "tradeSignature",
           "sign-execute", "params.nonce"]:
    idx = [m.start() for m in re.finditer(re.escape(kw), trade)]
    if idx:
        m = idx[0]
        a = max(0, m - 300)
        print(f"\n  [{kw}] x{len(idx)}\n  ...{trade[a:m+300]}...")
