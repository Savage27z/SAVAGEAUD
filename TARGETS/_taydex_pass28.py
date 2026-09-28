#!/usr/bin/env python3
"""TayDex pass28: locate the `markets` mapping slot, un-resolve one market, then test buy().

Every real buy() payload targets a market that is now resolved (market 2 is resolved with
winningOptionIndex = -1, i.e. voided), so `require(!resolved, "resolved")` fires before the
nonce/signature gates. To reach them I have to make a market live again on my own fork.

The packed struct gives an exact fingerprint, so the slot is VERIFIED not guessed:
  markets(uint256) -> (address creator, uint64 endDate, uint16 numOptions, uint16 creatorFeeShareBps,
                       bool resolved, int16 winningOptionIndex)
  Solidity packs low-order-first: slot A = creator(20B) | endDate(8B) | numOptions(2B) | feeBps(2B)
                                  slot A+1 = resolved(1B) | winningOptionIndex(2B)
So storage[keccak(pad(marketId) || pad(base))] must EQUAL that exact 32-byte composition.

Local fork mutations + eth_call only. No broadcast, no real chain.
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
        except Exception: pass
        time.sleep(1.1)
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

def call(sig, args="", frm=None):
    tx = {"to": C, "data": "0x" + sig4(sig) + args}
    if frm:
        tx["from"] = frm
    return rpc("eth_call", [tx, "latest"]).get("result")

def market_of(mid):
    h = call("getMarket(uint256)", f"{mid:064x}")
    if not isinstance(h, str) or len(h) < 2 + 64 * 6:
        return None
    b = h[2:]
    win = int(b[320:384], 16)
    win = win - 2**16 if win >= 2**15 else win
    return {"creator": "0x" + b[24:64], "endDate": int(b[64:128], 16),
            "numOptions": int(b[128:192], 16), "feeBps": int(b[192:256], 16),
            "resolved": int(b[256:320], 16) == 1, "winning": win}

m1 = market_of(1)
print("market 1 =", m1)

# ---------- find the markets mapping base slot by exact fingerprint ----------
# Solidity packs the FIRST-DECLARED variable into the LOWEST-order bytes, so the slot reads
#   feeBps | numOptions | endDate | creator   (left -> right, big-endian hex)
print("\n" + "=" * 96)
print("LOCATE markets MAPPING SLOT (verified by exact packing equality)")
print("=" * 96)
expect = (f"{m1['feeBps']:04x}"
          + f"{m1['numOptions']:04x}"
          + f"{m1['endDate']:016x}"
          + m1["creator"].lower().replace("0x", "").zfill(40))
print(f"  expected slot-1 fingerprint (low-first packing): {expect}")
base_found = None
for base in range(0, 90):
    key = "0x" + keccak(int(1).to_bytes(32, "big") + base.to_bytes(32, "big")).hex()
    v = rpc("eth_getStorageAt", [C, key, "latest"]).get("result")
    if isinstance(v, str) and v[2:].lower() == expect.lower():
        base_found = base
        print(f"  MATCH at base slot {base}")
        nxt = hex(int(key, 16) + 1)
        print(f"    struct slot      = {key}")
        print(f"    value            = {v}")
        print(f"    next slot (flags) {nxt} = {rpc('eth_getStorageAt', [C, nxt, 'latest']).get('result')}")
        break
if base_found is None:
    print("  no exact fingerprint match in slots 0..23 -> markets mapping not located")
    for base in range(0, 12):
        key = "0x" + keccak(int(1).to_bytes(32, "big") + base.to_bytes(32, "big")).hex()
        print(f"    base {base}: {rpc('eth_getStorageAt', [C, key, 'latest']).get('result')}")
    raise SystemExit("cannot proceed")

# ---------- un-resolve market 2 (voided: resolved=1, winning=-1) ----------
M2 = 2
print("\n" + "=" * 96)
print(f"UN-RESOLVE market {M2} on the fork")
print("=" * 96)
print(f"  before: {market_of(M2)}")
key2 = "0x" + keccak(M2.to_bytes(32, "big") + base_found.to_bytes(32, "big")).hex()
flag_slot = hex(int(key2, 16) + 1)
print(f"  markets[{M2}] struct slot = {key2}")
print(f"    value: {rpc('eth_getStorageAt', [C, key2, 'latest']).get('result')}")
print(f"  flag slot {flag_slot}: {rpc('eth_getStorageAt', [C, flag_slot, 'latest']).get('result')}")
# clear the low byte (resolved) while keeping winningOptionIndex
old = rpc("eth_getStorageAt", [C, flag_slot, "latest"]).get("result") or "0x" + "00" * 32
newval = "0x" + "00" * 31 + "00"          # resolved = 0, winning = 0 (KIND_NONE-ish)
rpc("anvil_setStorageAt", [C, flag_slot, newval])
print(f"  after clearing resolved: {market_of(M2)}")

# ---------- replay buy() on the un-resolved market ----------
dec = json.load(open(os.path.join(TGT, "pass26_buy_decoded.json")))
p = [d for d in dec if d["marketId"] == M2][0]
FRESH, FRESH2 = "0x00000000000000000000000000000000cafe0001", "0x00000000000000000000000000000000cafe0002"

def latest_ts():
    return int(rpc("eth_getBlockByNumber", ["latest", False])
               .get("result", {}).get("timestamp", "0x0"), 16)

def nonces_of(a):
    r = call("nonces(address)", a.lower().replace("0x", "").rjust(64, "0"))
    return int(r, 16) if isinstance(r, str) else None

def set_nonce(a, v):
    k = "0x" + keccak(bytes.fromhex(a.lower().replace("0x", "").rjust(64, "0"))
                      + (14).to_bytes(32, "big")).hex()
    rpc("anvil_setStorageAt", [C, k, "0x" + f"{v:064x}"])

m2 = market_of(M2)
ts = min(p["deadline"], m2["endDate"]) - 600 if m2 else p["deadline"] - 600
rpc("anvil_setTime", [ts]); rpc("evm_mine", [])
print(f"\n  clock rewound to {time.strftime('%Y-%m-%d %H:%M', time.gmtime(latest_ts()))}")

print("\n" + "=" * 96)
print(f"REPLAY buy() on market {M2}   payload {p['hash']}  nonce={p['nonce']}")
print("=" * 96)
rows = []
set_nonce(p["from"], p["nonce"])
r = rpc("eth_call", [{"from": p["from"], "to": C, "data": p["input"]}, "latest"])
rows.append(("1 original, nonce RESTORED", p["from"], p["nonce"], de(r)))
print(f"  1 original {p['from']} (nonce {p['nonce']}) -> {de(r)}")

set_nonce(p["from"], p["nonce"] + 7)
r = rpc("eth_call", [{"from": p["from"], "to": C, "data": p["input"]}, "latest"])
rows.append(("2 original, nonce ADVANCED", p["from"], p["nonce"] + 7, de(r)))
print(f"  2 original, nonce advanced        -> {de(r)}")

for label, who in [("3 fresh A", FRESH), ("4 fresh B", FRESH2)]:
    set_nonce(who, p["nonce"])
    r = rpc("eth_call", [{"from": who, "to": C, "data": p["input"]}, "latest"])
    rows.append((label, who, p["nonce"], de(r)))
    print(f"  {label} (nonce {p['nonce']})            -> {de(r)}")

print("\n" + "=" * 96)
print("VERDICT")
print("=" * 96)
for label, who, n, res in rows:
    print(f"  {label:<28} nonce={n:<3} -> {res}")
one, three, four = rows[0][3], rows[2][3], rows[3][3]
print()
if "sig" in three.lower() or "sig" in four.lower():
    print("  => buy() IS bound to its actor (foreign addresses rejected at the signature check")
    print("     while the original passes). Same design as createMarket.")
elif "sig" in one.lower():
    print("  => inconclusive: the original actor also fails the signature check.")
else:
    print("  => foreign addresses got PAST the signature check. buy() does NOT bind its actor.")
    print("     REAL FINDING on the money path - escalate.")
