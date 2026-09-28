#!/usr/bin/env python3
"""TayDex pass23: the actor-binding test, with the clock rewound.

anvil_setTime + evm_mine moves the fork's block timestamp, so `endDate past` stops firing and the
call proceeds to the deeper checks. Replay each real signed payload from:
  (a) the original sender      -- baseline: payload is genuinely valid for them
  (b) a FRESH address          -- nonces=0; payload nonce=0 -> passes a msg.sender-keyed gate
  (c) FRESH with nonce forced  -- same, for payloads whose nonce != 0
Reading the FIRST distinct error tells us which check gates the call and whether the actor matters.

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

def rewind_to(ts_target):
    rpc("anvil_setTime", [ts_target])
    rpc("evm_mine", [])
    return latest_ts()

def nonces_of(addr):
    r = rpc("eth_call", [{"to": C, "data": "0x" + sig4("nonces(address)")
                          + addr.lower().replace("0x", "").rjust(64, "0")}, "latest"]).get("result")
    return int(r, 16) if isinstance(r, str) else None

picks = json.load(open(os.path.join(TGT, "pass20_createmarket_decoded.json")))
FRESH = "0x00000000000000000000000000000000cafe0001"
SLOT = 14
targets = sorted(picks, key=lambda x: x["nonce"])[:3]

print("=" * 104)
print("ACTOR-BINDING TEST  (clock rewound per payload so 'endDate past' does not fire)")
print("=" * 104)
for p in targets:
    ts = rewind_to(p["endDate"] - 7200)
    print(f"\n  payload {p['hash'][:26]}…   nonce={p['nonce']}  bps={p['feeBps']}")
    print(f"    endDate={time.strftime('%Y-%m-%d %H:%M', time.gmtime(p['endDate']))}  "
          f"clock rewound to {time.strftime('%Y-%m-%d %H:%M', time.gmtime(ts))}")
    # (a) original sender
    r = rpc("eth_call", [{"from": p["from"], "to": C, "data": p["input"]}, "latest"])
    print(f"    [a original  ] nonces={nonces_of(p['from']):<4} -> {decode_error(r)}")
    # (b) fresh address (nonces=0)
    r = rpc("eth_call", [{"from": FRESH, "to": C, "data": p["input"]}, "latest"])
    print(f"    [b FRESH     ] nonces={nonces_of(FRESH):<4} -> {decode_error(r)}")
    # (c) fresh with the payload's nonce forced
    if p["nonce"] != 0:
        key = "0x" + keccak(bytes.fromhex(FRESH.lower().replace("0x", "").rjust(64, "0"))
                            + SLOT.to_bytes(32, "big")).hex()
        rpc("anvil_setStorageAt", [C, key, "0x" + f"{p['nonce']:064x}"])
        r = rpc("eth_call", [{"from": FRESH, "to": C, "data": p["input"]}, "latest"])
        print(f"    [c FRESH+n={p['nonce']:<3}] nonces={nonces_of(FRESH):<4} -> {decode_error(r)}")

print("\n" + "=" * 104)
print("INTERPRETATION")
print("=" * 104)
print("  same error for (a) and (b)                        -> the check does NOT depend on the actor")
print("  ECDSA/BadSignature for (b) but success for (a)     -> signature IS bound to its actor")
print("  a nonce Error for (b)                              -> nonce gate keys on msg.sender")
print("  USDC/allowance error for (b)                       -> signature ACCEPTED from a foreign")
print("                                                        address => actor NOT bound")
print("  success for (a)                                    -> the payload is genuinely valid")
