#!/usr/bin/env python3
"""Bundle-exact decrypt test: key = bytes(keccak256(arrayify(sig))), layout IV(12)|TAG(16)|CT.
Fetches ALL leaves for ETH (1) and SHERWOOD (3), trial-decrypts each."""
import json, urllib.request
from eth_utils import keccak
from Crypto.Cipher import AES

BASE = "https://api.sherwood.cash"
SIG = "0x3d2e877eebbbb5abce5135c978c3694d773d6b30b2607413f5d9f570b5b95b3027b5ef761ff949f3c284618367aed36bea55e53d637207babbbb2d66182f50c81c"

def get(url):
    req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0"})
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.loads(r.read())

# 1. key derivation exactly as z4/NG/Vt
sig_bytes = bytes.fromhex(SIG[2:])
e = keccak(sig_bytes)              # Vt(sig) = keccak256(arrayify(sig)) -> 32 bytes
key = e                            # NG: hex->bytes == the 32 raw bytes
print("key:", key.hex())

# 2. fetch leaves for both assets
for asset_id in ("1", "3"):
    try:
        st = get(f"{BASE}/assets/{asset_id}/status")
        print(f"\nasset {asset_id} status: lastLeafIndex={st.get('lastLeafIndex')} commitmentCount={st.get('commitmentCount')}")
    except Exception as ex:
        print(f"asset {asset_id} status ERR: {ex}")
        continue
    leaves = []
    c = 0
    while True:
        u = get(f"{BASE}/assets/{asset_id}/utxos?fromIndex={c}&limit=10000")
        utxos = u.get("utxos", [])
        if not utxos:
            break
        leaves.extend(utxos)
        nxt = utxos[-1]["index"] + 1
        if nxt <= c:
            break
        c = nxt
        if len(leaves) > 50000:
            break
    print(f"asset {asset_id}: fetched {len(leaves)} leaves")
    hits = []
    for w in leaves:
        enc = w["encryptedOutput"]
        if not enc or enc == "0x":
            continue
        raw = bytes.fromhex(enc[2:]) if enc.startswith("0x") else bytes.fromhex(enc)
        if len(raw) < 28:
            continue
        iv, tag, ct = raw[:12], raw[12:28], raw[28:]
        try:
            cph = AES.new(key, AES.MODE_GCM, nonce=iv)
            pt = cph.decrypt_and_verify(ct, tag)
            txt = pt.decode()
            if txt.count("|") == 3:
                hits.append((w["index"], w.get("commitment", "")[:18], txt, w.get("swapAmount")))
        except Exception:
            pass
    print(f"asset {asset_id}: DECRYPT HITS = {len(hits)}")
    for h in hits:
        print("  idx", h[0], "commit", h[1], "plain:", h[2], "swapAmt:", h[3])
