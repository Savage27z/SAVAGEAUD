#!/usr/bin/env python3
"""Sweep: every plausible key derivation x layout against all ETH leaves."""
import json, urllib.request, itertools
from eth_utils import keccak
from Crypto.Cipher import AES

BASE = "https://api.sherwood.cash"
SIG = "0x3d2e877eebbbb5abce5135c978c3694d773d6b30b2607413f5d9f570b5b95b3027b5ef761ff949f3c284618367aed36bea55e53d637207babbbb2d66182f50c81c"

def get(url):
    req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0"})
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.loads(r.read())

sig_bytes = bytes.fromhex(SIG[2:])

# key candidates
k1 = keccak(sig_bytes)                                  # encryptionKey (NG(Vt(sig)))
k2 = keccak(k1)                                          # utxoPrivateKey (Vt(encKey))
k3 = keccak(SIG.encode())                                # keccak of sig ASCII text
k4 = keccak(keccak(SIG.encode()))                        # double keccak of text
k5 = k1[:16] + b"\x00"*16                                # half-key padded (unlikely)
keys = {"encKey": k1, "utxoKey": k2, "text": k3, "text2": k4}

# layouts: (iv, tag, ct) slices for a raw blob
def layouts(raw):
    n = len(raw)
    out = {}
    if n >= 44:
        out["IV|TAG|CT"]  = (raw[:12], raw[12:28], raw[28:])
        out["IV|CT|TAG"]  = (raw[:12], raw[n-16:], raw[12:n-16])
        out["TAG|IV|CT"]  = (raw[:16], raw[16:32], raw[32:])
        out["CT|IV|TAG"]  = (raw[n-28:n-12], raw[n-12:], raw[:n-28])
    if n >= 44:
        out["IV16|CT|TAG"] = (raw[:16], raw[n-16:], raw[16:n-16])
    return out

# fetch leaves
leaves = []
c = 0
while True:
    u = get(f"{BASE}/assets/1/utxos?fromIndex={c}&limit=10000")
    utxos = u.get("utxos", [])
    if not utxos: break
    leaves.extend(utxos)
    nxt = utxos[-1]["index"] + 1
    if nxt <= c: break
    c = nxt
print(f"fetched {len(leaves)} ETH leaves")

hits = []
for kname, key in keys.items():
    for lname, (iv, tag, ct) in layouts(b"\x00"*100).items():
        found = 0
        for w in leaves:
            enc = w["encryptedOutput"]
            if not enc or enc == "0x": continue
            raw = bytes.fromhex(enc[2:] if enc.startswith("0x") else enc)
            if len(raw) < 44: continue
            l = layouts(raw)
            if lname not in l: continue
            iv, tag, ct = l[lname]
            try:
                cph = AES.new(key, AES.MODE_GCM, nonce=iv)
                pt = cph.decrypt_and_verify(ct, tag)
                txt = pt.decode(errors="replace")
                if txt.count("|") == 3:
                    found += 1
                    hits.append((kname, lname, w["index"], txt))
            except Exception:
                pass
        if found:
            print(f"HIT key={kname} layout={lname} -> {found}")

print("total hits:", len(hits))
for h in hits[:20]:
    print(h)
