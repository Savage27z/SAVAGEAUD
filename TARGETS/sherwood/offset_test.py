#!/usr/bin/env python3
"""The offset test: short logs have commitment(32)+index(32)+blob in data.
Try decrypting data[64:] as the ciphertext for short logs."""
import json, urllib.request
from eth_utils import keccak
from Crypto.Cipher import AES

RPC = "https://robinhood-mainnet.g.alchemy.com/v2/alch_XUun7agJSoS7vZz5tylMO"
VAULT = "0xf54013b8BE8fdFcF0CD1fD727c803F16c2450736"
TOPIC0 = "0xb778e175ed2182dc556533b770ea6b01126132d774b2925b0d478d3a390481ec"
SIG = "0x3d2e877eebbbb5abce5135c978c3694d773d6b30b2607413f5d9f570b5b95b3027b5ef761ff949f3c284618367aed36bea55e53d637207babbbb2d66182f50c81c"
WALLET = "0x21fc67258dd145c0c39bd87b3eca9c2508a48f65"

keys = {
    "encKey": keccak(bytes.fromhex(SIG[2:])),
    "utxoKey": keccak(keccak(bytes.fromhex(SIG[2:]))),
}

def rpc(method, params):
    req = urllib.request.Request(RPC, data=json.dumps({"jsonrpc":"2.0","id":1,"method":method,"params":params}).encode(),
                                 headers={"Content-Type":"application/json"})
    with urllib.request.urlopen(req, timeout=60) as r:
        return json.loads(r.read())["result"]

# window around our op
logs = rpc("eth_getLogs", [{"address": VAULT, "topics": [TOPIC0], "fromBlock": hex(49640000), "toBlock": hex(49700000)}])
print("logs:", len(logs))

def try_blob(raw, key, label):
    if len(raw) < 44: return None
    for lname, (iv, tag, ct) in {
        "IV|TAG|CT": (raw[:12], raw[12:28], raw[28:]),
        "IV|CT|TAG": (raw[:12], raw[-16:], raw[12:-16]),
    }.items():
        try:
            pt = AES.new(key, AES.MODE_GCM, nonce=iv).decrypt_and_verify(ct, tag).decode(errors="replace")
            if pt.count("|") == 3:
                return (lname, pt)
        except Exception:
            pass
    return None

hits = []
for lg in logs:
    full = len(lg["topics"]) >= 4
    aid = int(lg["topics"][1], 16) if len(lg["topics"]) > 1 else None
    data = bytes.fromhex(lg["data"][2:])
    blob_full = data            # what I tested before (full-shape: data IS the blob)
    blob_off  = data[64:] if not full and len(data) > 64 else None  # short-shape: skip commitment+index
    # sender
    try:
        rc = rpc("eth_getTransactionReceipt", [lg["transactionHash"]])
        frm = rc.get("from")
    except Exception:
        frm = None
    ours = frm and frm.lower() == WALLET
    for kname, key in keys.items():
        for bname, blob in (("full", blob_full), ("off64", blob_off)):
            if blob is None: continue
            r = try_blob(blob, key, bname)
            if r:
                hits.append((lg["blockNumber"], lg["transactionHash"], aid, full, kname, bname, r[0], r[1], ours))
                print(f"HIT blk {int(lg['blockNumber'],16)} tx {lg['transactionHash'][:18]} asset {aid} full={full} key={kname} off={bname} ours={ours} layout={r[0]} plain={r[1][:70]}")
    if ours and not any(h[1] == lg["transactionHash"] for h in hits):
        print(f"OURS no-hit: blk {int(lg['blockNumber'],16)} tx {lg['transactionHash'][:18]} asset {aid} full={full} datalen={len(data)}")

print("total hits:", len(hits))
