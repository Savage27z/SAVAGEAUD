#!/usr/bin/env python3
"""TayDex pass24: clinching 2x2 for actor binding.

Same signed payload, same nonce value, FOUR callers:
  1. original sender, nonce restored to the payload's nonce  -> should PASS both gates
  2. original sender, nonce left advanced                    -> "bad nonce" (control)
  3. fresh address A, nonce 0 == payload nonce 0             -> ?
  4. fresh address B, nonce 0 == payload nonce 0             -> ?
If 1 passes/broadcasts-deeper while 3 and 4 fail with a signature error at the SAME nonce value,
the signature is bound to the caller. That would FALSIFY the actor-unbinding hypothesis.

Also rewinds to min(deadline, endDate) - 600 so the 'expired'/'endDate past' gates don't mask it.
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

def latest_ts():
    return int(rpc("eth_getBlockByNumber", ["latest", False])
               .get("result", {}).get("timestamp", "0x0"), 16)

def nonces_of(addr):
    r = rpc("eth_call", [{"to": C, "data": "0x" + sig4("nonces(address)")
                          + addr.lower().replace("0x", "").rjust(64, "0")}, "latest"]).get("result")
    return int(r, 16) if isinstance(r, str) else None

def set_nonce(addr, val):
    key = "0x" + keccak(bytes.fromhex(addr.lower().replace("0x", "").rjust(64, "0"))
                        + (14).to_bytes(32, "big")).hex()
    rpc("anvil_setStorageAt", [C, key, "0x" + f"{val:064x}"])

picks = json.load(open(os.path.join(TGT, "pass20_createmarket_decoded.json")))
# the payload that already reached the signature check cleanly
p = [x for x in picks if x["hash"].startswith("0xc2d946af")][0]
A = "0x00000000000000000000000000000000cafe0001"
B = "0x00000000000000000000000000000000cafe0002"

ts = min(p["deadline"], p["endDate"]) - 600
rpc("anvil_setTime", [ts]); rpc("evm_mine", [])
print("=" * 100)
print("CLINCHING 2x2 — same signer-signed payload, same nonce value, four callers")
print("=" * 100)
print(f"payload {p['hash']}")
print(f"  nonce={p['nonce']}  deadline={time.strftime('%Y-%m-%d %H:%M', time.gmtime(p['deadline']))} "
      f"endDate={time.strftime('%Y-%m-%d %H:%M', time.gmtime(p['endDate']))}")
print(f"  clock rewound to {time.strftime('%Y-%m-%d %H:%M', time.gmtime(latest_ts()))}")
print(f"  original sender = {p['from']}\n")

print("  1. original sender, nonce RESTORED to payload nonce")
set_nonce(p["from"], p["nonce"])
print(f"     nonces({p['from'][:10]}…) = {nonces_of(p['from'])}")
r1 = rpc("eth_call", [{"from": p["from"], "to": C, "data": p["input"]}, "latest"])
print(f"     -> {decode_error(r1)}\n")

print("  2. original sender, nonce LEFT ADVANCED (control)")
set_nonce(p["from"], p["nonce"] + 5)
print(f"     nonces({p['from'][:10]}…) = {nonces_of(p['from'])}")
r2 = rpc("eth_call", [{"from": p["from"], "to": C, "data": p["input"]}, "latest"])
print(f"     -> {decode_error(r2)}\n")

print("  3. fresh address A (nonces=0, payload nonce=0)")
set_nonce(A, 0)
print(f"     nonces(A) = {nonces_of(A)}")
r3 = rpc("eth_call", [{"from": A, "to": C, "data": p["input"]}, "latest"])
print(f"     -> {decode_error(r3)}\n")

print("  4. fresh address B (nonces=0, payload nonce=0)")
set_nonce(B, 0)
print(f"     nonces(B) = {nonces_of(B)}")
r4 = rpc("eth_call", [{"from": B, "to": C, "data": p["input"]}, "latest"])
print(f"     -> {decode_error(r4)}\n")

print("=" * 100)
print("VERDICT")
print("=" * 100)
print(f"  1 original+nonce ok : {decode_error(r1)}")
print(f"  3 fresh A           : {decode_error(r3)}")
print(f"  4 fresh B           : {decode_error(r4)}")
print()
if "SUCCESS" in decode_error(r1) and "sig" in decode_error(r3).lower():
    print("  => the payload is VALID for its original actor but REJECTED for other addresses at")
    print("     the same nonce value  ==>  the signature IS bound to the caller.")
    print("     FINDING 3 FALSIFIED.")
elif "sig" in decode_error(r1).lower():
    print("  => inconclusive: the original caller also fails the signature check.")
else:
    print("  => mixed result, read the four lines above.")
