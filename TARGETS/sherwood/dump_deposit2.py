#!/usr/bin/env python3
"""Get full deposit tx hash, dump its NewCommitment data, sweep offsets."""
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
        j = json.loads(r.read())
    if "error" in j: raise RuntimeError(j["error"])
    return j["result"]

# find our tx hash
logs = rpc("eth_getLogs", [{"address": VAULT, "topics": [TOPIC0], "fromBlock": hex(49640420), "toBlock": hex(49640440)}])
our_txs = set()
for lg in logs:
    rc = rpc("eth_getTransactionReceipt", [lg["transactionHash"]])
    if rc and rc.get("from", "").lower() == WALLET:
        our_txs.add(lg["transactionHash"])
print("our txs in window:", our_txs)

for txh in our_txs:
    rc = rpc("eth_getTransactionReceipt", [txh])
    print("\n=== TX", txh, "from", rc.get("from"), "blk", int(rc["blockNumber"],16), "===")
    for lg in rc.get("logs", []):
        if lg["address"].lower() != VAULT.lower() or lg["topics"][0] != TOPIC0:
            continue
        data = bytes.fromhex(lg["data"][2:])
        print("topics:", [t[:20] for t in lg["topics"]])
        print("datalen:", len(data))
        print("data[0:32] :", data[0:32].hex())
        print("data[32:64]:", data[32:64].hex())
        print("data[64:92]:", data[64:92].hex())
        print("data[92:120]:", data[92:120].hex())
        print("data[-48:]:", data[-48:].hex())
        for off in range(0, min(len(data)-44, 180)):
            raw = data[off:]
            iv, tag, ct = raw[:12], raw[12:28], raw[28:]
            for kname, key in keys.items():
                try:
                    pt = AES.new(key, AES.MODE_GCM, nonce=iv).decrypt_and_verify(ct, tag).decode(errors="replace")
                    if pt.count("|") == 3:
                        print(f"*** HIT off={off} key={kname} plain={pt[:100]}")
                except Exception:
                    pass
print("\ndone")
