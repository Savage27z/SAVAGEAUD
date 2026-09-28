#!/usr/bin/env python3
"""TayDex pass5: pull the HUMAN-READABLE ABIs (viem parseAbi strings) and the EIP-712
struct definition for the server signature. Decides the binding-table question:
is the create-market signature bound to the creator address, or is it a bearer token?
Read-only: local bundle mining.
"""
import json, os, re

TGT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "taydex")
RAW = os.path.join(TGT, "raw")
src = {f: open(os.path.join(RAW, f), encoding="utf-8", errors="replace").read()
       for f in os.listdir(RAW) if f.endswith(".js")}

allj = "\n".join(src.values())

# ---------- 1. human-readable ABI fragments ----------
print("=" * 78)
print("1. HUMAN-READABLE ABI: every function/event/error string mentioning our surface")
print("=" * 78)
rx = re.compile(
    r'["\'`]((?:function|event|error)\s+'
    r'(createMarket|claim|dispute|cancelMarket|resolveMarket|setSigner|setFeeRecipient|'
    r'markets|getMarket|nonces|eip712Domain|resolve|redeem|split|merge|withdraw|deposit|'
    r'fund|settle|propose|buy|sell|trade)[^"\'`]{0,220})["\'`]')
seen = {}
for f, s in src.items():
    for m in rx.finditer(s):
        seen.setdefault(m.group(1), set()).add(f)
for sig, files in sorted(seen.items()):
    print(f"  {sig}")

# ---------- 2. any parseAbi array containing createMarket ----------
print("\n" + "=" * 78)
print("2. parseAbi array bodies")
print("=" * 78)
for f, s in src.items():
    for m in re.finditer(r'parseAbi\s*\(\s*\[', s):
        start = s.find("[", m.start())
        depth, i = 0, start
        while i < len(s):
            if s[i] == "[":
                depth += 1
            elif s[i] == "]":
                depth -= 1
                if depth == 0:
                    break
            i += 1
        body = s[start:i + 1]
        low = body.lower()
        if any(k in low for k in ["createmarket", "claim", "dispute", "signer", "market"]):
            print(f"\n--- {f} ---\n{body[:3000]}")

# ---------- 3. the EIP-712 struct for the server signature ----------
print("\n" + "=" * 78)
print("3. EIP-712 STRUCT candidates (types: {X: [{name:...}...]})")
print("=" * 78)
for f, s in src.items():
    for m in re.finditer(r'types\s*:\s*\{', s):
        start = m.start()
        depth, i = 0, s.find("{", start)
        while i < len(s):
            if s[i] == "{":
                depth += 1
            elif s[i] == "}":
                depth -= 1
                if depth == 0:
                    break
            i += 1
        seg = s[m.start():i + 1]
        if len(seg) < 900 and any(k in seg.lower() for k in
                                  ["market", "create", "claim", "call", "wrapped", "nonce"]):
            print(f"\n--- {f} ---\n{seg}")

# ---------- 4. 'creator' / 'msg.sender' semantics ----------
print("\n" + "=" * 78)
print("4. 'creator' references")
print("=" * 78)
for f, s in src.items():
    for m in re.finditer(r'creator', s, re.I):
        a = max(0, m.start() - 130)
        print(f"  [{f}] ...{s[a:m.end()+130]}...")

# ---------- 5. domain / chainId used for signing ----------
print("\n" + "=" * 78)
print("5. signing domain hints")
print("=" * 78)
for kw in ['name:"TayDex"', "name:'TayDex'", 'TayDex"', 'verifyingContract', 'primaryType']:
    hits = [f for f, s in src.items() if kw in s]
    print(f"  {kw!r}: {hits}")

# ---------- 6. the claim flow ----------
print("\n" + "=" * 78)
print("6. claim / redeem flow in the app")
print("=" * 78)
for f, s in src.items():
    for m in re.finditer(r'(claim|redeem)\w*', s):
        pass
    for m in re.finditer(r'/api/[a-z/\-]*(claim|redeem)[a-z/\-]*', s):
        print(f"  [{f}] route: {m.group(0)}")
for kw in ["winningOutcome", "claim(", "isClaimed", "hasClaimed", "outcomeIndex"]:
    hits = [(f, s.count(kw)) for f, s in src.items() if kw in s]
    print(f"  {kw!r}: {hits}")
