#!/usr/bin/env python3
"""Compare indexer encryptedOutput vs on-chain ABI-decoded blob for the same note."""
import json, urllib.request

BASE = "https://api.sherwood.cash"
RPC = "https://robinhood-mainnet.g.alchemy.com/v2/alch_XUun7agJSoS7vZz5tylMO"
VAULT = "0xf54013b8BE8fdFcF0CD1fD727c803F16c2450736"
TOPIC0 = "0xb778e175ed2182dc556533b770ea6b01126132d774b2925b0d478d3a390481ec"

def get(url):
    req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0"})
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.loads(r.read())

def rpc(method, params):
    req = urllib.request.Request(RPC, data=json.dumps({"jsonrpc":"2.0","id":1,"method":method,"params":params}).encode(),
                                 headers={"Content-Type":"application/json"})
    with urllib.request.urlopen(req, timeout=60) as r:
        return json.loads(r.read())["result"]

# indexer leaf for idx 896 (our deposit note)
u = get(f"{BASE}/assets/1/utxos?fromIndex=896&limit=3")
print("indexer rows for 896..:")
for row in u.get("utxos", []):
    print(" idx", row["index"], "enc len", len(row["encryptedOutput"])//2 - 1 if row["encryptedOutput"] else 0)
    print("   enc[0:80]:", row["encryptedOutput"][:80])
    print("   enc[-60:]:", row["encryptedOutput"][-60:])

# on-chain data for the same tx
rc = rpc("eth_getTransactionReceipt", ["0x55714ff4b73e13d86733d4b83e8b20c1a1d45e459e93e37f8dfeb85e31d120dd"])
print("\non-chain logs:")
for lg in rc["logs"]:
    if lg["address"].lower() == VAULT.lower() and lg["topics"][0] == TOPIC0:
        data = bytes.fromhex(lg["data"][2:])
        off = int.from_bytes(data[64:96], "big")
        ln = int.from_bytes(data[off:off+32], "big")
        blob = data[off+32:off+32+ln]
        print(" idx", int.from_bytes(data[32:64], "big"), "datalen", len(data), "off", off, "bloblen", len(blob))
        print("   blob[0:80]:", blob.hex()[:80])
        print("   blob[-60:]:", blob.hex()[-60:])
