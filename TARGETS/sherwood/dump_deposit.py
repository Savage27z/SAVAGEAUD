#!/usr/bin/env python3
"""Dump our deposit log's data structure + sweep every byte offset for decryption."""
import json, urllib.request
from eth_utils import keccak
from Crypto.Cipher import AES

RPC = "https://robinhood-mainnet.g.alchemy.com/v2/alch_XUun7agJSoS7vZz5tylMO"
VAULT = "0xf54013b8BE8fdFcF0CD1fD727c803F16c2450736"
TOPIC0 = "0xb778e175ed2182dc556533b770ea6b01126132d774b2925b0d478d3a390481ec"
SIG = "0x3d2e877eebbbb5abce5135c978c3694d773d6b30b2607413f5d9f570b5b95b3027b5ef761ff949f3c284618367aed36bea55e53d637207babbbb2d66182f50c81c"
keys = {
    "encKey": keccak(bytes.fromhex(SIG[2:])),
    "utxoKey": keccak(keccak(bytes.fromhex(SIG[2:]))),
}

def rpc(method, params):
    req = urllib.request.Request(RPC, data=json.dumps({"jsonrpc":"2.0","id":1,"method":method,"params":params}).encode(),
                                 headers={"Content-Type":"application/json"})
    with urllib.request.urlopen(req, timeout=60) as r:
        return json.loads(r.read())["result"]

# our deposit tx logs
rc = rpc("eth_getTransactionReceipt", ["0x55714ff4b73e13d8"])
print("tx from:", rc.get("from"), "blk:", int(rc["blockNumber"],16))
for lg in rc.get("logs", []):
    if lg["address"].lower() == VAULT.lower() and lg["topics"][0] == TOPIC0:
        data = bytes.fromhex(lg["data"][2:])
        print("\ntopics:", [t[:18] for t in lg["topics"]])
        print("data len:", len(data))
        print("data[0:32] :", data[0:32].hex())
        print("data[32:64]:", data[32:64].hex())
        print("data[64:76]:", data[64:76].hex())
        print("data[76:92]:", data[76:92].hex())
        print("data[92:110]:", data[92:110].hex())
        print("data[-40:]:", data[-40:].hex())
        # sweep every offset for a valid decrypt
        for off in range(0, min(len(data)-44, 160)):
            raw = data[off:]
            iv, tag, ct = raw[:12], raw[12:28], raw[28:]
            for kname, key in keys.items():
                try:
                    pt = AES.new(key, AES.MODE_GCM, nonce=iv).decrypt_and_verify(ct, tag).decode(errors="replace")
                    if pt.count("|") == 3:
                        print(f"*** HIT off={off} key={kname} plain={pt[:100]}")
                except Exception:
                    pass
print("done")
