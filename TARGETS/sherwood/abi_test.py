#!/usr/bin/env python3
"""Correct blob extraction: ABI-decode (bytes32,uint256,bytes) for short logs.
Try decrypt with encKey + utxoKey on ALL vault logs in the op window."""
import json, urllib.request
from eth_utils import keccak
from Crypto.Cipher import AES

RPC = "https://robinhood-mainnet.g.alchemy.com/v2/alch_XUun7agJSoS7vZz5tylMO"
VAULT = "0xf54013b8BE8fdFcF0CD1fD727c803F16c2450736"
TOPIC0 = "0xb778e175ed2182dc556533b770ea6b01126132d774b2925b0d478d3a390481ec"
SIG = "0x3d2e877eebbbb5abce5135c978c3694d773d6b30b2607413f5d9f570b5b95b3027b5ef761ff949f3c284618367aed36bea55e53d637207babbbb2d66182f50c81c"
WALLET = "0x21fc67258dd145c0c39bd87b3eca9c2508a48f65"
SHERWOOD = int("0xD4DC6B48Ad73EC51E71D9B8F65568f88609b92c1", 16)
keys = {
    "encKey": keccak(bytes.fromhex(SIG[2:])),
    "utxoKey": keccak(keccak(bytes.fromhex(SIG[2:]))),
}

def rpc(method, params):
    req = urllib.request.Request(RPC, data=json.dumps({"jsonrpc":"2.0","id":1,"method":method,"params":params}).encode(),
                                 headers={"Content-Type":"application/json"})
    with urllib.request.urlopen(req, timeout=60) as r:
        j = json.loads(r.read())
    if "error" in j: raise RuntimeError(j["error"])
    return j["result"]

def abi_decode_short(data):
    """(bytes32, uint256, bytes)"""
    if len(data) < 128: return None
    commitment = data[0:32]
    index = int.from_bytes(data[32:64], "big")
    off = int.from_bytes(data[64:96], "big")
    if off < 0 or off >= len(data): return None
    length = int.from_bytes(data[off:off+32], "big")
    blob = data[off+32: off+32+length]
    return commitment, index, blob

def try_decrypt(blob, key):
    if blob is None or len(blob) < 44: return None
    for lname, (iv, tag, ct) in {
        "IV|TAG|CT": (blob[:12], blob[12:28], blob[28:]),
        "IV|CT|TAG": (blob[:12], blob[-16:], blob[12:-16]),
    }.items():
        try:
            pt = AES.new(key, AES.MODE_GCM, nonce=iv).decrypt_and_verify(ct, tag).decode(errors="replace")
            if pt.count("|") == 3:
                return (lname, pt)
        except Exception:
            pass
    return None

logs = rpc("eth_getLogs", [{"address": VAULT, "topics": [TOPIC0], "fromBlock": hex(49640000), "toBlock": hex(49700000)}])
print("logs:", len(logs))

hits = []
for lg in logs:
    full = len(lg["topics"]) >= 4
    aid = int(lg["topics"][1], 16)
    txh = lg["transactionHash"]
    blk = int(lg["blockNumber"], 16)
    data = bytes.fromhex(lg["data"][2:])
    try:
        rc = rpc("eth_getTransactionReceipt", [txh]); frm = rc.get("from")
    except Exception: frm = None
    ours = frm and frm.lower() == WALLET
    blobs = {}
    if full:
        blobs["full"] = data
        idx = int(lg["topics"][3], 16)
    else:
        dec = abi_decode_short(data)
        if dec:
            commitment, idx, blob = dec
            blobs["short_abi"] = blob
        else:
            idx = None
    for bname, blob in blobs.items():
        for kname, key in keys.items():
            r = try_decrypt(blob, key)
            if r:
                hits.append((blk, txh, aid, idx, kname, bname, r[0], r[1], ours))
                print(f"HIT blk {blk} tx {txh[:18]} asset {aid} idx {idx} key={kname} {bname} layout={r[0]} ours={ours} plain={r[1][:80]}")
    if ours:
        print(f"OURS: blk {blk} tx {txh[:18]} asset {aid} full={full} idx={idx} datalen={len(data)} -> " + ("HIT" if any(h[1]==txh for h in hits) else "no hit"))

print("\ntotal hits:", len(hits))
