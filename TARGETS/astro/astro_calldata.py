#!/usr/bin/env python3
"""Astro Phase 1b: recover round-driving calldata from the operator's live txs;
resolve custom error names; decode address getters properly."""
import json, urllib.request, time

RPC = "https://rpc.mainnet.chain.robinhood.com"
ADDR = "0xcC679b67eE1AbC40C06CFE20ce4479EFFaD9A407"
ATTACKER = "0x1111111111111111111111111111111111111111"

def rpc(method, params):
    body = json.dumps({"jsonrpc":"2.0","id":1,"method":method,"params":params}).encode()
    req = urllib.request.Request(RPC, data=body, headers={"Content-Type":"application/json","User-Agent":"Mozilla/5.0"})
    return json.loads(urllib.request.urlopen(req, timeout=30).read())

def fbytes(h):
    return bytes.fromhex(h[2:]) if h and h.startswith("0x") else b""

def hex_lookup(sel):
    try:
        u = f"https://www.4byte.directory/api/v1/signatures/?format=json&hex_signature={sel}"
        req = urllib.request.Request(u, headers={"User-Agent":"curl/8"})
        d = json.loads(urllib.request.urlopen(req, timeout=15).read())
        return [r["text_signature"] for r in d.get("results", [])]
    except Exception:
        return []

txs = {
    "Commit Round": "0x5826805fda1c276b2b864a5a3c68f3cb54c9cb881968c499e51a32d72bbd05a8",
    "Finalize Round": "0xb4530e01a56a47d33f9280ce613a9cae9d549842dae9d1882278a86bdfab37e9",
    "Lock Salt": "0x0b9aca7711ca8fce916acc3fb474d0174554881029fdadb1ec46a3a2ea520259",
    "Close Betting": "0x12292ae8c38663ecb93c4fee51d93002749663cc6a9c00b632ca128c33f60226",
    "Place Bet": "0x627c6b5fa28830d4eee7ffbd4c47bb511a3355f89995280a9103c0e8dfdca1b4",
}
print("=== operator/player tx calldata ===")
inputs = {}
for label, txh in txs.items():
    tx = rpc("eth_getTransactionByHash", [txh]).get("result")
    if not tx:
        print(label, "not found")
        continue
    inp = tx["input"]
    sel = inp[:10]
    inputs[label] = inp
    print(f"\n{label}: to={tx['to']} from={tx['from']} value={int(tx['value'],16)}")
    print(f"  selector {sel}  args: {inp[10:]}")
    names = hex_lookup(sel)
    print("  name(s):", names[:3] if names else "-")
    time.sleep(0.4)

print("\n=== custom error name lookups ===")
for sel in ["0x03eefa66", "0xac831504", "0x82b42900"]:
    print(sel, "->", hex_lookup(sel)[:4] or "-")
    time.sleep(0.4)

print("\n=== address-style decode of getters ===")
for name, sel in [("bankroll()", "0x0c657eb0"), ("accessController()", "0xbc43cbaf"), ("0xc62416aa", "0xc62416aa")]:
    res = rpc("eth_call", [{"to": ADDR, "data": sel}, "latest"])
    r = res.get("result", "0x")
    addr = "0x" + r[-40:] if r and r != "0x" else "revert"
    print(f"  {name} -> {addr}")
