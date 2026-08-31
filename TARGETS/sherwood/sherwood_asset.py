#!/usr/bin/env python3
"""Check indexer + on-chain for SHERWOOD (decimal token address asset id)."""
import json, urllib.request
from eth_utils import keccak
from Crypto.Cipher import AES

BASE = "https://api.sherwood.cash"
RPC = "https://robinhood-mainnet.g.alchemy.com/v2/alch_XUun7agJSoS7vZz5tylMO"
VAULT = "0xf54013b8BE8fdFcF0CD1fD727c803F16c2450736"
TOPIC0 = "0xb778e175ed2182dc556533b770ea6b01126132d774b2925b0d478d3a390481ec"
SHERWOOD = int("0xD4DC6B48Ad73EC51E71D9B8F65568f88609b92c1", 16)
SIG = "0x3d2e877eebbbb5abce5135c978c3694d773d6b30b2607413f5d9f570b5b95b3027b5ef761ff949f3c284618367aed36bea55e53d637207babbbb2d66182f50c81c"
key = keccak(bytes.fromhex(SIG[2:]))

def get(url):
    req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0"})
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.loads(r.read())

# indexer: correct sherwood asset id
sid = str(SHERWOOD)
print("=== indexer SHERWOOD asset", sid[:12], "===")
try:
    st = get(f"{BASE}/assets/{sid}/status")
    print("status:", st)
except Exception as e:
    print("status ERR:", e)

# fetch indexer leaves for sherwood
try:
    leaves = []
    c = 0
    while True:
        u = get(f"{BASE}/assets/{sid}/utxos?fromIndex={c}&limit=10000")
        utxos = u.get("utxos", [])
        if not utxos: break
        leaves.extend(utxos)
        nxt = utxos[-1]["index"] + 1
        if nxt <= c: break
        c = nxt
    print("indexer sherwood leaves:", len(leaves))
    hits = 0
    for w in leaves:
        enc = w["encryptedOutput"]
        if not enc or enc == "0x": continue
        raw = bytes.fromhex(enc[2:] if enc.startswith("0x") else enc)
        if len(raw) < 44: continue
        iv, tag, ct = raw[:12], raw[12:28], raw[28:]
        try:
            pt = AES.new(key, AES.MODE_GCM, nonce=iv).decrypt_and_verify(ct, tag).decode()
            if pt.count("|") == 3:
                hits += 1
                print("  HIT idx", w["index"], "swapAmt", w.get("swapAmount"), "plain:", pt[:80])
        except Exception:
            pass
    print("decrypt hits (indexer sherwood):", hits)
except Exception as e:
    print("leaves ERR:", e)
