#!/usr/bin/env python3
"""TayDex pass18: settle the actor-binding question using a REAL signature lifted from chain.

Markets 7/8/9 have creator == signer(), so a real createMarket tx exists whose calldata carries
a signature the live signer actually produced. I do not need to reconstruct the EIP-712 scheme.

Test: replay that exact calldata on my fork, from
  (a) the original sender          -> baseline, should revert only because the nonce is spent
  (b) a FRESH address              -> nonces[B] = 0
and compare the revert. Reading the outcome:
  sig rejected (ECDSA / BadSignature)  -> the signature IS bound to its actor, or scheme mismatch
  NONCE error                          -> the check keys on msg.sender's nonce
  any LATER error (USDC / fee transfer)-> the signature was ACCEPTED from a foreign address
                                          => actor NOT bound. That is the proof.

Read-only on the fork (eth_call only; no broadcast, no real chain).
"""
import json, os, urllib.error, urllib.request

R = "http://127.0.0.1:8546"
C = "0x3ade22fa1ef5ac75437a3734d91ba588e54875dd"
TGT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "taydex")
UA = ("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36")
from Crypto.Hash import keccak as _k
def keccak(b): h = _k.new(digest_bits=256); h.update(b); return h.digest()
def sig4(s): return keccak(s.encode()).hex()[:8]
def topic0(s): return "0x" + keccak(s.encode()).hex()

def http(url, data=None, timeout=40):
    req = urllib.request.Request(url, data=data,
                                 headers={"Content-Type": "application/json",
                                          "User-Agent": UA, "Accept": "application/json"})
    try:
        return json.loads(urllib.request.urlopen(req, timeout=timeout).read())
    except urllib.error.HTTPError as e:
        try:    return json.loads(e.read())
        except Exception: return {"__http__": e.code}
    except Exception as e:
        return {"__err__": str(e)}

def frpc(m, p):
    return http(R, json.dumps({"jsonrpc": "2.0", "id": 1, "method": m, "params": p}).encode())

def show(label, r):
    if "error" in r:
        err = r["error"]; d = err.get("data")
        msg = err.get("message", "")
        out = msg
        if isinstance(d, str) and d.startswith("0x08c379a0"):
            ln = int(d[10:74], 16)
            out = f'Error("{bytes.fromhex(d[74:74+ln*2]).decode("utf-8","replace")}")'
        elif isinstance(d, str) and len(d) >= 10:
            out = f"{msg} data=0x{d[2:10]}"
        elif d is None:
            out = f"{msg} (EMPTY data)"
        print(f"  {label:<38} {out}")
        return out
    print(f"  {label:<38} OK -> {str(r.get('result'))[:70]}")
    return "OK"

# ---------- 1. find real createMarket calldata ----------
SIG = "createMarket((uint64,uint128[],uint16,uint256,uint256),bytes)"
SEL = sig4(SIG)
print(f"createMarket selector = 0x{SEL}\n")
print("=" * 100)
print("1. FIND A REAL createMarket TX (Blockscout v1 txlist -- v2 endpoint is 500ing)")
print("=" * 100)
cands = []
page = 1
while page <= 6:
    bs = http(f"https://base.blockscout.com/api?module=account&action=txlist"
              f"&address={C}&sort=asc&page={page}&offset=100")
    if not isinstance(bs, dict) or bs.get("status") == "0":
        print(f"  page {page}: no more ({str(bs)[:120]})")
        break
    items = bs.get("result") or []
    if not items:
        break
    print(f"  page {page}: {len(items)} tx(s)")
    for it in items:
        raw = it.get("input") or ""
        if raw.lower().startswith("0x" + SEL):
            cands.append({"hash": it.get("hash"), "from": it.get("from"),
                          "block": it.get("blockNumber"), "input": raw,
                          "to": it.get("to")})
    if len(items) < 100:
        break
    page += 1

print(f"\n  createMarket tx(s) found: {len(cands)}")
for c in cands:
    print(f"    {c['hash']}  from={c['from']}  block={c['block']}  inlen={len(c['input'])}")
if not cands:
    raise SystemExit("no createMarket calldata found - cannot run the test")

pick = cands[0]
print(f"\n  USING {pick['hash']} from {pick['from']}")
json.dump(cands, open(os.path.join(TGT, "pass18_realtx.json"), "w"), indent=1)

# ---------- 2. decode the nonce out of the calldata ----------
raw = pick["input"][2:]
body = raw[8:]
words = [body[i*64:(i+1)*64] for i in range(len(body)//64)]
print(f"\n  calldata words: {len(words)}")
for i, wd in enumerate(words[:14]):
    print(f"    word{i:<2} {wd}  dec={int(wd,16) if len(wd)==64 else '?'}")

# ---------- 3. replay from different callers ----------
print("\n" + "=" * 100)
print("2. REPLAY THE REAL SIGNED CALLDATA FROM DIFFERENT CALLERS (fork, eth_call)")
print("=" * 100)
fresh = "0x0000000000000000000000000000000000000abc"
callers = [("original sender", pick["from"]), ("fresh address", fresh)]
results = {}
for label, who in callers:
    r = frpc("eth_call", [{"from": who, "to": C, "data": pick["input"]}, "latest"])
    results[label] = show(label, r)

# ---------- 4. isolate: zero the nonce for the fresh caller, retry ----------
print("\n" + "=" * 100)
print("3. ISOLATE THE NONCE: for each slot, zero the fresh caller's nonce, replay")
print("=" * 100)
addr32 = fresh.lower().replace("0x", "").rjust(64, "0")
for slot in range(10, 18):
    key = "0x" + keccak(bytes.fromhex(addr32) + slot.to_bytes(32, "big")).hex()
    before = frpc("eth_getStorageAt", [C, key, "latest"]).get("result")
    frpc("anvil_setStorageAt", [C, key, "0x" + "00" * 32])
    r = frpc("eth_call", [{"from": fresh, "to": C, "data": pick["input"]}, "latest"])
    err = r.get("error", {})
    d = err.get("data") if isinstance(err, dict) else None
    msg = err.get("message", "")
    if isinstance(d, str) and d.startswith("0x08c379a0"):
        ln = int(d[10:74], 16)
        msg = bytes.fromhex(d[74:74+ln*2]).decode("utf-8", "replace")
        msg = f'Error("{msg}")'
    print(f"  nonce-zeroed slot {slot:<3} (was {str(before)[:20]}…) -> {msg or str(r.get('result'))[:60]}")
