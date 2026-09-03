#!/usr/bin/env python3
"""Astro fork battery T1-T5: single-step validation via eth_call on local anvil fork.
No impersonation needed for eth_call (pure simulation)."""
import json, urllib.request

RPC = "http://localhost:8545"
GAME = "0xcC679b67eE1AbC40C06CFE20ce4479EFFaD9A407"
OWNER = "0x36d75c31aa1f44e26303462fbe84de7529b713ea"
PLAYER = "0x557cd0e7d5a7ccc843792e00254e0bd097e52d12"
RANDOM = "0x1111111111111111111111111111111111111111"

def rpc(method, params):
    body = json.dumps({"jsonrpc":"2.0","id":1,"method":method,"params":params}).encode()
    req = urllib.request.Request(RPC, data=body, headers={"Content-Type":"application/json"})
    return json.loads(urllib.request.urlopen(req, timeout=30).read())

def call(data, frm):
    res = rpc("eth_call", [{"to": GAME, "from": frm, "data": data}, "latest"])
    if "error" in res:
        e = res["error"]
        d = (e.get("data") or "")
        return "REVERT " + (d[:74] if d else e.get("message",""))
    return "OK " + (res.get("result") or "0x")[:74]

# real finalize calldata for round 4103 (from live tx 0xb4530e01...)
real_finalize = ("0x33129ef6"
    + "0000000000000000000000000000000000000000000000000000000000001007"  # round 4103
    + "8a1629a077473e0064bad1a0eaa49f1cdfec6e049afd7ede7d5f2ebbd949b883"  # bytes32 A
    + "2400c093aded8f104803c7eeb8eab3d5cf4035de48441c6d0a588e694cee0d6d"  # bytes32 B
    + "0000000000000000000000000000000000000000000000000000000000000080"  # offset winners
    + "0000000000000000000000000000000000000000000000000000000000000001"  # len 1
    + "000000000000000000000000557cd0e7d5a7ccc843792e00254e0bd097e52d12"  # winner
    + "0000000000000000000000000000000000000000000000000000000000004e20") # 20000

def mutate_hex(h, pos):
    h = list(h)
    h[pos] = '0' if h[pos] != '0' else '1'
    return ''.join(h)

print("T1 re-finalize round 4103 (real calldata, owner):")
print("  ", call(real_finalize, OWNER))
print("T2 finalize 4103 w/ mutated seed byte:")
print("  ", call(mutate_hex(real_finalize, 2+64+20), OWNER))  # flip byte inside bytes32 A
print("T3 emergencyForceCancel(4104) as owner (<7d):")
print("  ", call("0x4b79704c" + hex(4104)[2:].zfill(64), OWNER))
print("T4a placeBet(4104, 10000, 500000) as real player ($0.50):")
print("  ", call("0xe71c9697" + hex(4104)[2:].zfill(64) + hex(10000)[2:].zfill(64) + hex(500000)[2:].zfill(64), PLAYER))
print("T4b placeBet(4104, 0, 0) as real player (zero amt):")
print("  ", call("0xe71c9697" + hex(4104)[2:].zfill(64) + "0"*64 + "0"*64, PLAYER))
print("T4c placeBet(4104, 10000, 500000) as random (no USDG):")
print("  ", call("0xe71c9697" + hex(4104)[2:].zfill(64) + hex(10000)[2:].zfill(64) + hex(500000)[2:].zfill(64), RANDOM))
print("T5 lockSalt(4104) as owner:")
print("  ", call("0x272f911c" + hex(4104)[2:].zfill(64), OWNER))
print("T5b closeBetting(4104) as owner:")
print("  ", call("0xb4ad06a1" + hex(4104)[2:].zfill(64), OWNER))
print("T5c commitRound() as owner (would open round 4105):")
print("  ", call("0x4ed71302", OWNER))
