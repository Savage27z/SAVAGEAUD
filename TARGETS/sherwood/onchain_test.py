#!/usr/bin/env python3
"""Ground-truth test: pull NewCommitment logs from the vault RPC, trial-decrypt every ETH blob."""
import json, urllib.request
from eth_utils import keccak
from Crypto.Cipher import AES

RPC = "https://robinhood-mainnet.g.alchemy.com/v2/alch_XUun7agJSoS7vZz5tylMO"
VAULT = "0xf54013b8BE8fdFcF0CD1fD727c803F16c2450736"
TOPIC0 = "0xb778e175ed2182dc556533b770ea6b01126132d774b2925b0d478d3a390481ec"
SIG = "0x3d2e877eebbbb5abce5135c978c3694d773d6b30b2607413f5d9f570b5b95b3027b5ef761ff949f3c284618367aed36bea55e53d637207babbbb2d66182f50c81c"

key = keccak(bytes.fromhex(SIG[2:]))
print("key:", key.hex())

def rpc(method, params):
    req = urllib.request.Request(RPC, data=json.dumps({"jsonrpc":"2.0","id":1,"method":method,"params":params}).encode(),
                                 headers={"Content-Type":"application/json"})
    with urllib.request.urlopen(req, timeout=60) as r:
        return json.loads(r.read())["result"]

# latest block
latest = int(rpc("eth_blockNumber", []), 16)
print("latest block:", latest)

# query from deposit block region (49,640,400) to latest, paged by 10k-block chunks
logs = []
fr = 49640400
while fr <= latest:
    to = min(fr + 10000, latest)
    try:
        l = rpc("eth_getLogs", [{"address": VAULT, "topics": [TOPIC0], "fromBlock": hex(fr), "toBlock": hex(to)}])
    except Exception as e:
        print("ERR chunk", fr, e)
        break
    logs.extend(l)
    if to >= latest:
        break
    fr = to + 1

print("total NewCommitment logs:", len(logs))

# filter assetId=1 (topic1) and try decrypt
dec = lambda blob: None
hits = []
asset_counts = {}
for lg in logs:
    aid = int(lg["topics"][1], 16) if len(lg["topics"]) > 1 else None
    asset_counts[aid] = asset_counts.get(aid, 0) + 1
    if aid != 1:
        continue
    raw = bytes.fromhex(lg["data"][2:])
    if len(raw) < 44:
        continue
    iv, tag, ct = raw[:12], raw[12:28], raw[28:]
    try:
        cph = AES.new(key, AES.MODE_GCM, nonce=iv)
        pt = cph.decrypt_and_verify(ct, tag).decode()
        hits.append((lg["blockNumber"], lg["transactionHash"], lg["topics"][2][:18], lg["topics"][3], pt))
    except Exception:
        pass

print("assetId counts:", asset_counts)
print("DECRYPT HITS on-chain (asset 1):", len(hits))
for h in hits[:10]:
    print(" blk", h[0], "tx", h[1][:18], "commit", h[2], "idx", h[3], "plain:", h[4])
