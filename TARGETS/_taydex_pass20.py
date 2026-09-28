#!/usr/bin/env python3
"""TayDex pass20: close two questions with real chain data.

 A. Decode the LeftoverSwept event from an actual sweep tx -> who receives `dest`?
    If dest == the caller, an unprivileged sweep pays the caller, and Finding 2's mechanism is
    established (impact still gated by 'does any market hold dust').

 B. Actor-binding replay test. Take a REAL createMarket calldata (carrying a signature the live
    signer actually produced) and replay it on my fork from a DIFFERENT address. Compare reverts:
      signature error  -> bound to its actor (or scheme mismatch)
      nonce error      -> the check keys on msg.sender
      LATER error      -> the signature was ACCEPTED from a foreign address => actor NOT bound.

Read-only: eth_getTransactionReceipt / eth_call on my own fork.
"""
import json, os, urllib.error, urllib.request

R = "http://127.0.0.1:8546"
C = "0x3ade22fa1ef5ac75437a3734d91ba588e54875dd"
TGT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "taydex")
from Crypto.Hash import keccak as _k
def keccak(b): h = _k.new(digest_bits=256); h.update(b); return h.digest()
def sig4(s): return keccak(s.encode()).hex()[:8]
def topic0(s): return "0x" + keccak(s.encode()).hex()

def rpc(m, p):
    req = urllib.request.Request(R, data=json.dumps({"jsonrpc": "2.0", "id": 1,
                                                     "method": m, "params": p}).encode(),
                                 headers={"Content-Type": "application/json"})
    try:
        return json.loads(urllib.request.urlopen(req, timeout=60).read())
    except urllib.error.HTTPError as e:
        try:    return json.loads(e.read())
        except Exception: return {"error": {"message": f"HTTP {e.code}"}}

def describe(r):
    if "error" in r:
        err = r["error"]; d = err.get("data"); msg = err.get("message", "")
        if isinstance(d, str) and d.startswith("0x08c379a0"):
            ln = int(d[10:74], 16)
            return f'Error("{bytes.fromhex(d[74:74+ln*2]).decode("utf-8","replace")}")'
        if isinstance(d, str) and len(d) >= 10:
            return f"{msg} [custom 0x{d[2:10]}]"
        if d is None:
            return f"{msg} (EMPTY data)"
        return str(msg)
    return "SUCCESS -> " + str(r.get("result"))[:60]

# ================= A. LeftoverSwept decode =================
print("=" * 96)
print("A. WHERE DID THE SWEPT DUST GO?  decode LeftoverSwept from a real sweep tx")
print("=" * 96)
SWEEP_TX = "0xe6e6e9522cc6d557f153bc9fad20b33968276262ed6f0a2bcb3398b110270dbb"  # market 24
rc = rpc("eth_getTransactionReceipt", [SWEEP_TX]).get("result") or {}
print(f"  tx {SWEEP_TX}")
print(f"  status={rc.get('status')}  from={rc.get('from')}  logs={len(rc.get('logs') or [])}")
T = topic0("LeftoverSwept(uint256,uint16,address,uint256)")
for lg in rc.get("logs") or []:
    if (lg.get("topics") or [""])[0].lower() == T.lower():
        mid = int(lg["topics"][1], 16)
        oi = int(lg["topics"][2], 16)
        dest = "0x" + lg["topics"][3][-40:]
        amt = int(lg["data"], 16) if lg.get("data") not in (None, "0x") else None
        print(f"\n  LeftoverSwept:")
        print(f"    marketId = {mid}   optionIndex = {oi}")
        print(f"    dest     = {dest}")
        print(f"    amount   = {amt}  ({amt/1e6 if amt else 0} USDC)")
        print(f"    caller   = {rc.get('from')}")
        print(f"    dest == caller ? {dest.lower() == (rc.get('from') or '').lower()}")
        print(f"    dest == feeRecipient ? "
              f"{dest.lower() == '0xc0b085c1a5514d8541adcb105aa7e6e8e5bc74ed'}")
        print(f"    dest == owner ? "
              f"{dest.lower() == '0xef869234bb919bbde0f44d98912e87d1ce0463f8'}")
    else:
        print(f"  [other log] topic0={lg['topics'][0]}")

# ================= B. actor-binding replay =================
print("\n" + "=" * 96)
print("B. ACTOR-BINDING REPLAY: real signed createMarket calldata, different callers")
print("=" * 96)
cands = json.load(open(os.path.join(TGT, "pass19_createmarket_txs.json")))
print(f"  {len(cands)} createMarket payload(s) available")

# decode the tuple fields of each to find one with a low nonce
def words(hexstr):
    b = hexstr[2:]
    return [b[i*64:(i+1)*64] for i in range(len(b)//64)]

picks = []
for c in cands:
    wd = words(c["input"])
    # layout: [off_tuple][off_sig] then tuple data: endDate, off_arr, feeBps, nonce, deadline, ...
    try:
        off_tuple = int(wd[0], 16) // 32
        endDate = int(wd[off_tuple], 16)
        feebps = int(wd[off_tuple + 2], 16)
        nonce = int(wd[off_tuple + 3], 16)
        deadline = int(wd[off_tuple + 4], 16)
        off_sig = int(wd[1], 16) // 32
        siglen = int(wd[off_sig], 16)
        sig = wd[off_sig + 1]
        picks.append({"hash": c["hash"], "from": c["from"], "nonce": nonce,
                      "endDate": endDate, "feeBps": feebps, "deadline": deadline,
                      "siglen": siglen, "sig": sig, "input": c["input"]})
    except Exception as e:
        print(f"    decode failed for {c['hash']}: {e}")

print(f"\n  decoded {len(picks)} payload(s):")
for p in picks:
    print(f"    {p['hash'][:20]}… from={p['from'][:12]}… nonce={p['nonce']} "
          f"feeBps={p['feeBps']} siglen={p['siglen']}")
json.dump(picks, open(os.path.join(TGT, "pass20_createmarket_decoded.json"), "w"), indent=1)

if not picks:
    raise SystemExit("nothing to replay")

# prefer the payload with the smallest nonce (most likely to match a fresh wallet's 0)
p = sorted(picks, key=lambda x: x["nonce"])[0]
print(f"\n  REPLAYING {p['hash']}  (nonce={p['nonce']}, original sender {p['from']})")

FRESH = "0x00000000000000000000000000000000cafe0001"
CASES = [("original sender", p["from"]), ("fresh address", FRESH)]
for label, who in CASES:
    n = rpc("eth_call", [{"to": C, "data": "0x" + sig4("nonces(address)") +
                          who.lower().replace("0x", "").rjust(64, "0")}, "latest"])
    print(f"\n  [{label}] {who}")
    print(f"      nonces({label}) = {int(n.get('result', '0x0'), 16) if isinstance(n.get('result'), str) else n}")
    r = rpc("eth_call", [{"from": who, "to": C, "data": p["input"]}, "latest"])
    print(f"      replay -> {describe(r)}")

# also: does the CONTRACT share the same original sender state? show owner() context
print("\n  --- interpretation key ---")
print("    'ECDSAInvalidSignature'/BadSignature -> signature bound to actor, or scheme mismatch")
print("    a nonce Error(...)                   -> the nonce check keys on msg.sender")
print("    insufficient-USDC / transfer error   -> signature ACCEPTED from a foreign address")
