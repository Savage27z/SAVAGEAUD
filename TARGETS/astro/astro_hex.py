#!/usr/bin/env python3
import json, subprocess, urllib.request, re, time

ADDR = "0xcC679b67eE1AbC40C06CFE20ce4479EFFaD9A407"
RPC = "https://rpc.mainnet.chain.robinhood.com"

def rpc_call(method, params):
    body = json.dumps({"jsonrpc":"2.0","id":1,"method":method,"params":params}).encode()
    req = urllib.request.Request(RPC, data=body, headers={"Content-Type":"application/json","User-Agent":"Mozilla/5.0"})
    return json.loads(urllib.request.urlopen(req, timeout=30).read())["result"]

code = rpc_call("eth_getCode", [ADDR, "latest"])[2:]
p = subprocess.run(["/root/.foundry/bin/cast","disassemble", "0x"+code], capture_output=True, text=True)
selectors = set()
for line in p.stdout.splitlines():
    m = re.search(r"PUSH4\s+(0x[0-9a-fA-F]{8})", line)
    if m:
        selectors.add(m.group(1).lower())

def hex_lookup(sel):
    try:
        u = f"https://www.4byte.directory/api/v1/signatures/?format=json&hex_signature={sel}"
        req = urllib.request.Request(u, headers={"User-Agent":"curl/8"})
        d = json.loads(urllib.request.urlopen(req, timeout=15).read())
        return [r["text_signature"] for r in d.get("results", [])]
    except Exception:
        return []

for sel in sorted(selectors):
    names = hex_lookup(sel)
    tag = "; ".join(names[:3]) if names else "-"
    print(f"{sel}  {tag}")
    time.sleep(0.5)
