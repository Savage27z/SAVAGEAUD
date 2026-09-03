#!/usr/bin/env python3
"""Astro black-box Phase 1: read state getters + probe state-changing selectors as a random EOA.
All calls are eth_call simulations on live RPC — no state change."""
import json, urllib.request

ADDR = "0xcC679b67eE1AbC40C06CFE20ce4479EFFaD9A407"
RPC = "https://rpc.mainnet.chain.robinhood.com"
ATTACKER = "0x1111111111111111111111111111111111111111"

def rpc(method, params):
    body = json.dumps({"jsonrpc":"2.0","id":1,"method":method,"params":params}).encode()
    req = urllib.request.Request(RPC, data=body, headers={"Content-Type":"application/json","User-Agent":"Mozilla/5.0"})
    return json.loads(urllib.request.urlopen(req, timeout=30).read())

def call(data, frm=ATTACKER):
    res = rpc("eth_call", [{"to": ADDR, "from": frm, "data": data}, "latest"])
    if "error" in res:
        return ("RPC_ERR", str(res["error"]))
    return ("OK", res.get("result",""))

def dec(result_hex):
    r = result_hex or "0x"
    if r == "0x":
        return "empty"
    if r.startswith("0x08c379a0"):  # Error(string)
        try:
            body = bytes.fromhex(r[10:])
            ln = int.from_bytes(body[32:64], "big")
            msg = body[64:64+ln].decode(errors="replace")
            return f"Error: {msg}"
        except Exception:
            return "Error(string) unparsed"
    if r.startswith("0x4e487b71"):  # Panic(uint256)
        return "Panic(" + str(int(r[10:74], 16)) + ")"
    if len(r) >= 10:
        return "custom/other: " + r[:66]
    return r

getters = [
    ("currentRoundId()", "0x9cbe5efd"),
    ("paused()", "0x5c975abb"),
    ("bankroll()", "0x0c657eb0"),
    ("accessController()", "0xbc43cbaf"),
    ("houseEdgeDivisor()", "0xe5c774de"),
    ("minBet()", "0x9619367d"),
    ("maxBet()", "0x2e5b2168"),
    ("EMERGENCY_TIMEOUT()", "0x7f264076"),
    ("MAX_PLAYERS()", "0x4411b3eb"),
]
print("=== state getters ===")
for name, sel in getters:
    st, r = call(sel)
    val = int(r, 16) if st == "OK" and r and r != "0x" else ("revert" if st == "OK" and r == "0x" else r)
    print(f"  {name:22s} {sel} -> {val}")

# placeBet probed with plausible args after seeing limits; use zero-ish first
print("\n=== permission probes (as 0x1111...1111) ===")
probes = [
    ("placeBet(1e6,0,0)", "0xe71c9697" + "0"*64 + "0"*64 + "0"*64),
    ("placeBet(1e6,15000,cur)", "0xe71c9697" + "0"*64 + (hex(15000)[2:].zfill(64)) + "0"*64),
    ("lockSalt(1)", "0x272f911c" + "1".zfill(64)),
    ("emergencyForceCancel(1)", "0x4b79704c" + "1".zfill(64)),
    ("setPaused(true)", "0x16c38b3c" + "1".zfill(64)),
    ("setMaxPlayers(50)", "0x288dee3b" + hex(50)[2:].zfill(64)),
    ("setBetLimits(1e18,1e22)", "0x7687dd49" + hex(10**18)[2:].zfill(64) + hex(10**22)[2:].zfill(64)),
]
for name, data in probes:
    st, r = call(data)
    print(f"  {name:28s} -> {dec(r)}")

unresolved = ["0x072ffb3a","0x0f3ae951","0x17aa5fb7","0x245a91a3","0x33129ef6","0x39dd3ece",
              "0x43000818","0x4ed71302","0x4f451b0b","0x5776f2bd","0x6e3fd647","0x71b21552",
              "0x740ba91e","0x75a2b6ca","0x7d46abdc","0xa240722d","0xaa84756f","0xb4ad06a1",
              "0xc62416aa","0xcd7636c4","0xe5ef4631","0xe934777b","0xed2c8795","0xf644b3bb",
              "0xfb0b4e16","0xfd16a2e7","0xfd713280"]
print("\n=== unresolved selectors, empty calldata as attacker ===")
for sel in unresolved:
    st, r = call(sel)
    print(f"  {sel} -> {dec(r)}")
