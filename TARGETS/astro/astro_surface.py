#!/usr/bin/env python3
"""Astro CrashGame black-box: recover implemented function selectors from bytecode
and intersect with 4byte.directory text searches for the round actions."""
import json, subprocess, urllib.request, urllib.parse, re, time
import subprocess as _sp

ADDR = "0xcC679b67eE1AbC40C06CFE20ce4479EFFaD9A407"
RPC = "https://rpc.mainnet.chain.robinhood.com"

def k4(sig):
    out = _sp.run(["/root/.foundry/bin/cast", "keccak", sig], capture_output=True, text=True).stdout.strip()
    return "0x" + out[2:10]

def rpc_call(method, params):
    body = json.dumps({"jsonrpc":"2.0","id":1,"method":method,"params":params}).encode()
    req = urllib.request.Request(RPC, data=body, headers={"Content-Type":"application/json","User-Agent":"Mozilla/5.0"})
    return json.loads(urllib.request.urlopen(req, timeout=30).read())["result"]

def fourbyte_text(q):
    try:
        u = "https://www.4byte.directory/api/v1/signatures/?format=json&text=" + urllib.parse.quote(q)
        req = urllib.request.Request(u, headers={"User-Agent":"curl/8"})
        d = json.loads(urllib.request.urlopen(req, timeout=20).read())
        return [r["text_signature"] for r in d.get("results", [])]
    except Exception as e:
        return []

code = rpc_call("eth_getCode", [ADDR, "latest"])[2:]
# find PUSH4 selectors from disassembly via cast
p = subprocess.run(["/root/.foundry/bin/cast","disassemble", "0x"+code], capture_output=True, text=True)
selectors = set()
for line in p.stdout.splitlines():
    m = re.search(r"PUSH4\s+(0x[0-9a-fA-F]{8})", line)
    if m:
        selectors.add(m.group(1).lower())
print("unique PUSH4 constants in bytecode:", len(selectors))

# 4byte text search for round actions + common admin
keywords = ["commit", "lockSalt", "salt", "closeBetting", "betting", "finalize", "round",
            "placeBet", "bet", "cashout", "withdraw", "deposit", "houseEdge", "edge",
            "hwm", "bankroll", "set", "pause", "claim", "update", "usdg"]
sigs = set()
for kw in keywords:
    for s in fourbyte_text(kw):
        sigs.add(s)
    time.sleep(0.4)
print("candidate signatures from 4byte:", len(sigs))

# match implemented
print("\n=== implemented matches (selector present in bytecode) ===")
for sig in sorted(sigs):
    sel = k4(sig)
    if sel.lower() in selectors:
        print(f"  {sel}  {sig}")
