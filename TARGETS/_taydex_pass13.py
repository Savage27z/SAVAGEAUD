#!/usr/bin/env python3
"""TayDex pass13: direct proof that the live app's trade path cannot execute.

Same encoder, same call style, two functions:
  control : claim(uint256,uint16)          -> KNOWN to exist -> expect a BODY reason
  subject : buy(...) / sell(...)            -> app calls these -> expect EMPTY revert
An empty revert (no data) = the selector matched nothing and there is no permissive fallback.
A body reason = the contract decoded the call. The contrast isolates function EXISTENCE from
any flaw in my encoder.

Read-only: eth_call only. Nothing signed, nothing broadcast.
"""
import json, os, time, urllib.error, urllib.request

TGT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "taydex")
CORE = "0x3ade22fa1ef5ac75437a3734d91ba588e54875dd"
RPCS = ["https://base-rpc.publicnode.com", "https://1rpc.io/base",
        "https://mainnet.base.org", "https://base.drpc.org"]
UA = ("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36")
from Crypto.Hash import keccak as _k
def keccak(b): h = _k.new(digest_bits=256); h.update(b); return h.digest()
def sig4(s): return keccak(s.encode()).hex()[:8]

def rpc(m, p, tries=4):
    last = None
    for _ in range(tries):
        for url in RPCS:
            try:
                body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": m,
                                   "params": p}).encode()
                req = urllib.request.Request(url, data=body,
                    headers={"Content-Type": "application/json", "User-Agent": UA})
                raw = urllib.request.urlopen(req, timeout=25).read()
            except urllib.error.HTTPError as e:
                raw = e.read()
            except Exception as e:
                last = str(e); continue
            try: r = json.loads(raw)
            except Exception: last = raw[:80]; continue
            if "result" in r: return r["result"]
            if "error" in r:  return {"__e__": r["error"]}
        time.sleep(1)
    return {"__e__": last}

def w(v): return f"{int(v):064x}"
def ad(x): return x.lower().replace("0x", "").rjust(64, "0")

RAND = "0x9a7f9a7f9a7f9a7f9a7f9a7f9a7f9a7f9a7f9a7f"

def enc_trade(sig, market_id=1, option=0, outcome=0, amt_in=1_000_000,
              shares=1, fee=0, nonce=0, deadline=2_000_000_000):
    """Encode  f((10 static fields), bytes)  with an empty signature.
    head = [offset_p, offset_sig]; p = 10 static words; sig = length(0)."""
    p = [w(market_id), w(option), w(outcome), w(amt_in), w(shares), w(fee),
         ad(RAND), w(0), w(nonce), w(deadline)]
    off_p = 64                      # after the 2-word head
    off_sig = off_p + 32 * len(p)   # p occupies 10 words
    head = w(off_p) + w(off_sig)
    return "0x" + sig4(sig) + head + "".join(p) + w(0)

CASES = [
    # control: exists -> should decode and revert with a BODY reason, or return
    ("claim(uint256,uint16)  [CONTROL - exists]",
     "0x" + sig4("claim(uint256,uint16)") + w(1) + w(0)),
    ("createMarket((uint64,uint128[],uint16,uint256,uint256),bytes)  [CONTROL - exists]",
     None),  # dynamic array - skip
    ("dispute(uint256)  [CONTROL - exists]",
     "0x" + sig4("dispute(uint256)") + w(1)),
    # subjects: the app's trade path
    ("buy(...)   [the app calls this]",
     enc_trade("buy((uint256,uint16,uint8,uint256,uint256,uint256,address,uint256,uint256,uint256),bytes)")),
    ("sell(...)  [the app calls this]",
     enc_trade("sell((uint256,uint16,uint8,uint256,uint256,uint256,address,uint256,uint256,uint256),bytes)",
               amt_in=1, shares=1)),
    # other app-only functions
    ("pause()    [app only]",
     "0x" + sig4("pause()")),
    ("pushReferral(uint256,address)  [app only]",
     "0x" + sig4("pushReferral(uint256,address)") + w(1) + ad(RAND)),
    ("rescueToken(address,address,uint256)  [app only]",
     "0x" + sig4("rescueToken(address,address,uint256)")
     + ad("0x833589fcd6edb6e08f4c7c32d4f71b54bda02913") + ad(RAND) + w(1)),
    # deployed-only function the app does not know
    ("cancelMarket(uint256)  [DEPLOYED only]", None),
]

print("=" * 100)
print("LIVE CALL TEST: does the contract implement the app's trade path?")
print("=" * 100)
print(f"{'call':<62} {'result'}")
print("-" * 100)
for label, data in CASES:
    if data is None:
        print(f"{label:<62} (skipped - dynamic encoding)")
        continue
    r = rpc("eth_call", [{"from": RAND, "to": CORE, "data": data}, "latest"])
    if isinstance(r, dict):
        err = r["__e__"]
        d = err.get("data") if isinstance(err, dict) else None
        if d and d.startswith("0x08c379a0"):
            ln = int(d[10:74], 16)
            msg = bytes.fromhex(d[74:74 + ln * 2]).decode("utf-8", "replace")
            print(f"{label:<62} BODY REASON: \"{msg}\"   <- selector DECODED")
        elif d:
            print(f"{label:<62} revert data {d[:20]}…")
        else:
            print(f"{label:<62} EMPTY REVERT  <- selector matched NOTHING, no fallback")
    else:
        print(f"{label:<62} RETURNED {str(r)[:40]}")

# ---------- cancelMarket: does the deployed version implement it? ----------
print("\n" + "=" * 100)
print("cancelMarket(uint256) on the live contract (resolves to the DEPLOYED version's name)")
print("=" * 100)
s = sig4("cancelMarket(uint256)")
print(f"  selector 0x{s}  raw-present in code: {s in rpc('eth_getCode', [CORE, 'latest'])[2:]}")
r = rpc("eth_call", [{"from": RAND, "to": CORE, "data": "0x" + s + w(1)}, "latest"])
print(f"  eth_call -> {r}")
if isinstance(r, dict):
    d = r["__e__"].get("data")
    if d and d.startswith("0x08c379a0"):
        ln = int(d[10:74], 16)
        print(f"  BODY REASON: \"{bytes.fromhex(d[74:74+ln*2]).decode()}\"  <- selector DECODED")
    elif not d:
        print("  EMPTY REVERT (may be a 4byte mis-resolution, not a real function)")
