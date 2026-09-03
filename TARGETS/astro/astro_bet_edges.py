#!/usr/bin/env python3
"""Astro fork battery: bet-edge tests on round 4103 while betting is OPEN
(fork at block 53,502,580 — after Commit+PlaceBet, before CloseBetting)."""
import json, urllib.request

RPC = "http://localhost:8545"
GAME = "0xcC679b67eE1AbC40C06CFE20ce4479EFFaD9A407"
USDG = "0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168"
PLAYER = "0x557cd0e7d5a7ccc843792e00254e0bd097e52d12"   # real bettor in round 4103
RANDOM = "0x1111111111111111111111111111111111111111"

def rpc(method, params):
    body = json.dumps({"jsonrpc":"2.0","id":1,"method":method,"params":params}).encode()
    req = urllib.request.Request(RPC, data=body, headers={"Content-Type":"application/json"})
    return json.loads(urllib.request.urlopen(req, timeout=30).read())

def call(to, data, frm):
    res = rpc("eth_call", [{"to": to, "from": frm, "data": data}, "latest"])
    if "error" in res:
        e = res["error"]
        d = (e.get("data") or "")
        return "REVERT " + (d[:82] if d else e.get("message",""))
    return "OK " + (res.get("result") or "0x")[:82]

def bal(addr):
    r = rpc("eth_call", [{"to": USDG, "data": "0x70a08231" + addr[2:].lower().zfill(64)}, "latest"])
    return int(r["result"], 16) if "result" in r else None

def allow(owner, spender):
    r = rpc("eth_call", [{"to": USDG, "data": "0xdd62ed3e" + owner[2:].lower().zfill(64) + spender[2:].lower().zfill(64)}, "latest"])
    return int(r["result"], 16) if "result" in r else None

# USDG: balanceOf(PLAYER), allowance(PLAYER -> GAME)
print("USDG balance player:", bal(PLAYER), "| allowance->game:", allow(PLAYER, GAME))
print("USDG balance random:", bal(RANDOM))

pb = lambda rnd, arg2, amt: "0xe71c9697" + hex(rnd)[2:].zfill(64) + hex(arg2)[2:].zfill(64) + hex(amt)[2:].zfill(64)
print("\nBet-edge tests on round 4103 (betting OPEN):")
print("  valid $1 bet as player (500000 raw too small? min 500000):", call(GAME, pb(4103, 10000, 1000000), PLAYER))
print("  valid $5 bet (their real size, diff arg2):", call(GAME, pb(4103, 50000, 5000000), PLAYER))
print("  second bet same round (one-bet check):", call(GAME, pb(4103, 10000, 1000000), PLAYER))
print("  zero amount:", call(GAME, pb(4103, 10000, 0), PLAYER))
print("  below minBet (100 raw):", call(GAME, pb(4103, 10000, 100), PLAYER))
print("  above maxBet (1e9+1 = $1000+):", call(GAME, pb(4103, 10000, 1000000001), PLAYER))
print("  at maxBet (1e9):", call(GAME, pb(4103, 10000, 1000000000), PLAYER))
print("  wrong round 4102:", call(GAME, pb(4102, 10000, 1000000), PLAYER))
print("  future round 4104:", call(GAME, pb(4104, 10000, 1000000), PLAYER))
print("  random EOA (no balance):", call(GAME, pb(4103, 10000, 1000000), RANDOM))
