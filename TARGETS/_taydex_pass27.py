#!/usr/bin/env python3
"""TayDex pass27: buy() actor-binding test on an UNRESOLVED market.

pass26 hit Error("resolved") for every caller -- market 25 is already resolved in the fork's state
and that check fires before the nonce/signature gates. Markets 2, 7, 8 are unresolved
(winningOptionIndex = -1), and a real buy() payload exists for market 2 (nonce=3).

Rewind the clock to just before that payload's deadline (which also puts us before the market's
endDate logically) and replay from four callers at the SAME nonce value.
eth_call only.
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

def de(r):
    if not isinstance(r, dict) or "error" not in r:
        return "*** SUCCESS *** -> " + str((r or {}).get("result"))[:70]
    err = r["error"]
    if not isinstance(err, dict):
        return f"TRANSPORT: {str(err)[:100]}"
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

def nonces_of(a):
    r = rpc("eth_call", [{"to": C, "data": "0x" + sig4("nonces(address)")
                          + a.lower().replace("0x", "").rjust(64, "0")}, "latest"]).get("result")
    return int(r, 16) if isinstance(r, str) else None

def set_nonce(a, v):
    key = "0x" + keccak(bytes.fromhex(a.lower().replace("0x", "").rjust(64, "0"))
                        + (14).to_bytes(32, "big")).hex()
    rpc("anvil_setStorageAt", [C, key, "0x" + f"{v:064x}"])

def resolved_of(mid):
    r = rpc("eth_call", [{"to": C, "data": "0x" + sig4("getMarket(uint256)") + f"{mid:064x}"}, "latest"])
    h = r.get("result")
    if not isinstance(h, str) or len(h) < 2 + 64 * 6:
        return None
    b = h[2:]
    win = int(b[320:384], 16)
    win = win - 2**16 if win >= 2**15 else win
    return (int(b[256:320], 16) == 1, win)

dec = json.load(open(os.path.join(TGT, "pass26_buy_decoded.json")))
# unresolved markets are the ones whose winningOptionIndex == -1
unres = [d for d in dec if (resolved_of(d["marketId"]) or (True, 0))[1] == -1]
print("buy() payloads on UNRESOLVED markets:")
for d in unres:
    print(f"  {d['hash'][:22]}… market={d['marketId']} nonce={d['nonce']} "
          f"deadline={time.strftime('%Y-%m-%d %H:%M', time.gmtime(d['deadline']))}")
print()
for mid in sorted({d['marketId'] for d in dec}):
    print(f"  market {mid}: resolved,winning = {resolved_of(mid)}")

if not unres:
    raise SystemExit("no buy payload on an unresolved market - cannot proceed")

p = unres[0]
FRESH, FRESH2 = "0x00000000000000000000000000000000cafe0001", "0x00000000000000000000000000000000cafe0002"
ts = p["deadline"] - 600
rpc("anvil_setTime", [ts]); rpc("evm_mine", [])
print("\n" + "=" * 100)
print(f"REPLAY {p['hash']}")
print(f"  market={p['marketId']} nonce={p['nonce']} usdcIn={p['usdcIn']} shares={p['shares']}")
print(f"  clock rewound to {time.strftime('%Y-%m-%d %H:%M', time.gmtime(latest_ts()))}; "
      f"market {p['marketId']} state = {resolved_of(p['marketId'])}")
print("=" * 100)

rows = []
set_nonce(p["from"], p["nonce"])
r = rpc("eth_call", [{"from": p["from"], "to": C, "data": p["input"]}, "latest"])
rows.append(("1 original, nonce RESTORED to payload", p["from"], p["nonce"], r))
print(f"\n  1. original sender {p['from']}")
print(f"     nonces = {nonces_of(p['from'])}")
print(f"     -> {de(r)}")

set_nonce(p["from"], p["nonce"] + 7)
r = rpc("eth_call", [{"from": p["from"], "to": C, "data": p["input"]}, "latest"])
rows.append(("2 original, nonce ADVANCED (control)", p["from"], p["nonce"] + 7, r))
print(f"\n  2. original sender, nonce advanced")
print(f"     nonces = {nonces_of(p['from'])}")
print(f"     -> {de(r)}")

for label, who in [("3 fresh A", FRESH), ("4 fresh B", FRESH2)]:
    set_nonce(who, p["nonce"])
    r = rpc("eth_call", [{"from": who, "to": C, "data": p["input"]}, "latest"])
    rows.append((label, who, p["nonce"], r))
    print(f"\n  {label} {who}  (nonce set to the payload's {p['nonce']})")
    print(f"     nonces = {nonces_of(who)}")
    print(f"     -> {de(r)}")

print("\n" + "=" * 100)
print("VERDICT")
print("=" * 100)
for label, who, n, r in rows:
    print(f"  {label:<38} nonce={n:<3} -> {de(r)}")
one = de(rows[0][3]); three = de(rows[2][3]); four = de(rows[3][3])
print()
if "SUCCESS" in one or ("sig" not in one.lower() and "nonce" not in one.lower()):
    if "sig" in three.lower() or "sig" in four.lower():
        print("  => buy() IS bound to its actor: the original passes, foreign addresses at the same")
        print("     nonce are rejected at the signature check. Same design as createMarket.")
    else:
        print("  => foreign addresses got PAST the signature check -> buy() does NOT bind its actor.")
        print("     REAL FINDING on the money path. Escalate.")
else:
    print("  => inconclusive; read the rows above.")
