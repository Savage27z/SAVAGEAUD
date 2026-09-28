#!/usr/bin/env python3
"""TayDex pass26: does the deployed buy() bind its actor, the way createMarket does?

The deployed trade path is buy((uint256,uint16,uint8,uint256,uint256,uint256,uint256,uint256),bytes)
-- 8 fields + signature. Decoded from real calls:
  (marketId, optionIndex, outcome, usdcAmount, shares, fee, nonce, deadline) + sig
One real call (0x86e35a95…) came from a genuine third party, 0x22845bd1…, with nonce = 0 -- ideal
for replay by a fresh address whose nonce is also 0.

Same 2x2 as the createMarket test: same payload, same nonce, callers differ.
eth_call only -- no state change, no broadcast.
"""
import json, os, time, urllib.error, urllib.request

R = "http://127.0.0.1:8546"
C = "0x3ade22fa1ef5ac75437a3734d91ba588e54875dd"
TGT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "taydex")
from Crypto.Hash import keccak as _k
def keccak(b): h = _k.new(digest_bits=256); h.update(b); return h.digest()
def sig4(s): return keccak(s.encode()).hex()[:8]

def rpc(m, p, tries=3):
    for _ in range(tries):
        try:
            req = urllib.request.Request(R, data=json.dumps({"jsonrpc": "2.0", "id": 1,
                                                            "method": m, "params": p}).encode(),
                                         headers={"Content-Type": "application/json"})
            return json.loads(urllib.request.urlopen(req, timeout=60).read())
        except urllib.error.HTTPError as e:
            try:    return json.loads(e.read())
            except Exception: pass
        except Exception:
            pass
        time.sleep(1.2)
    return {}

def decode_error(r):
    if not isinstance(r, dict) or "error" not in r:
        return "*** SUCCESS *** -> " + str((r or {}).get("result"))[:70]
    err = r["error"]
    if not isinstance(err, dict):
        return f"TRANSPORT: {str(err)[:110]}"
    d = err.get("data"); msg = err.get("message", "")
    if isinstance(d, str) and d.startswith("0x08c379a0") and len(d) >= 138:
        ln = int(d[74:138], 16)
        try:
            return f'Error("{bytes.fromhex(d[138:138+ln*2]).decode("utf-8","replace")}")'
        except Exception:
            return f"Error(<len={ln}>)"
    if isinstance(d, str) and len(d) >= 10:
        return f"{msg} [custom 0x{d[2:10]}]"
    if d is None:
        return f"{msg} (EMPTY data)"
    return str(msg)

def words(inp):
    b = inp[10:]
    return [b[i*64:(i+1)*64] for i in range(len(b)//64)]

def latest_ts():
    return int(rpc("eth_getBlockByNumber", ["latest", False])
               .get("result", {}).get("timestamp", "0x0"), 16)

def nonces_of(a):
    r = rpc("eth_call", [{"to": C, "data": "0x" + sig4("nonces(address)")
                          + a.lower().replace("0x", "").rjust(64, "0")}, "latest"]).get("result")
    return int(r, 16) if isinstance(r, str) else None

def set_nonce(a, v):
    key = "0x" + keccak(bytes.fromhex(a.lower().replace("0x", "").rjust(64, "0"))
                        + (14).to_bytes(32, "big")).hex()
    rpc("anvil_setStorageAt", [C, key, "0x" + f"{v:064x}"])

BUY_SEL = "9aa63277"
txs = json.load(open(os.path.join(TGT, "pass19_txhistory.json")))
buys = [t for t in txs if (t.get("input") or "").lower().startswith("0x" + BUY_SEL)]
print(f"{len(buys)} real buy() call(s) found\n")

print("=" * 100)
print("DECODED buy() payloads      (marketId, optionIndex, outcome, usdcIn, shares, fee, nonce, deadline)")
print("=" * 100)
dec = []
for t in buys:
    try:
        w = words(t["input"])
        d = {"hash": t["hash"], "from": t["from"], "input": t["input"],
             "marketId": int(w[0], 16), "optionIndex": int(w[1], 16), "outcome": int(w[2], 16),
             "usdcIn": int(w[3], 16), "shares": int(w[4], 16), "fee": int(w[5], 16),
             "nonce": int(w[6], 16), "deadline": int(w[7], 16)}
        dec.append(d)
    except Exception as e:
        print(f"  decode fail {t['hash'][:18]}: {e}")
for d in dec:
    print(f"  {d['hash'][:20]}… from {d['from']}")
    print(f"      market={d['marketId']} option={d['optionIndex']} outcome={d['outcome']} "
          f"usdcIn={d['usdcIn']} shares={d['shares']} fee={d['fee']} nonce={d['nonce']} "
          f"deadline={time.strftime('%Y-%m-%d %H:%M', time.gmtime(d['deadline']))}")
json.dump(dec, open(os.path.join(TGT, "pass26_buy_decoded.json"), "w"), indent=1)

p = sorted(dec, key=lambda x: x["nonce"])[0]
FRESH = "0x00000000000000000000000000000000cafe0001"
FRESH2 = "0x00000000000000000000000000000000cafe0002"

print("\n" + "=" * 100)
print(f"REPLAY {p['hash']}  (nonce={p['nonce']}, original {p['from']})")
print("=" * 100)
ts = p["deadline"] - 600
rpc("anvil_setTime", [ts]); rpc("evm_mine", [])
print(f"  clock rewound to {time.strftime('%Y-%m-%d %H:%M', time.gmtime(latest_ts()))} "
      f"(deadline was {time.strftime('%Y-%m-%d %H:%M', time.gmtime(p['deadline']))})\n")

print(f"  1. original sender, nonce RESTORED to {p['nonce']}")
set_nonce(p["from"], p["nonce"])
print(f"     nonces = {nonces_of(p['from'])}")
r1 = rpc("eth_call", [{"from": p["from"], "to": C, "data": p["input"]}, "latest"])
print(f"     -> {decode_error(r1)}\n")

print("  2. original sender, nonce LEFT ADVANCED (control)")
set_nonce(p["from"], p["nonce"] + 7)
print(f"     nonces = {nonces_of(p['from'])}")
r2 = rpc("eth_call", [{"from": p["from"], "to": C, "data": p["input"]}, "latest"])
print(f"     -> {decode_error(r2)}\n")

for label, who in [("3. fresh A", FRESH), ("4. fresh B", FRESH2)]:
    set_nonce(who, p["nonce"])
    print(f"  {label} (nonce set to {p['nonce']} = payload nonce)")
    print(f"     nonces = {nonces_of(who)}")
    rr = rpc("eth_call", [{"from": who, "to": C, "data": p["input"]}, "latest"])
    print(f"     -> {decode_error(rr)}\n")

print("=" * 100)
print("VERDICT")
print("=" * 100)
print(f"  1 original + nonce ok : {decode_error(r1)}")
print(f"  2 original + nonce bad: {decode_error(r2)}")
print()
if "sig" in decode_error(r1).lower():
    print("  inconclusive: the original actor also fails the signature check")
elif any("sig" in decode_error(rr).lower() for rr in []):
    pass
print("  If (1) gets past the signature check and (3)/(4) fail it at the SAME nonce value, the same")
print("  actor binding applies to buy() as to createMarket(). If (3)/(4) get past it too, then the")
print("  deployed trade path does NOT bind its actor -> a real finding on the money path.")
