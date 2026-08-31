#!/usr/bin/env python3
"""Build receipts for the founder: our deposit tx + notes created in our op window."""
import json, urllib.request
from eth_utils import keccak

RPC = "https://robinhood-mainnet.g.alchemy.com/v2/alch_XUun7agJSoS7vZz5tylMO"
VAULT = "0xf54013b8BE8fdFcF0CD1fD727c803F16c2450736"
TOPIC0 = "0xb778e175ed2182dc556533b770ea6b01126132d774b2925b0d478d3a390481ec"
WALLET = "0x21fc67258dd145c0c39bd87b3eca9c2508a48f65"
SHERWOOD = int("0xD4DC6B48Ad73EC51E71D9B8F65568f88609b92c1", 16)

def rpc(method, params):
    req = urllib.request.Request(RPC, data=json.dumps({"jsonrpc":"2.0","id":1,"method":method,"params":params}).encode(),
                                 headers={"Content-Type":"application/json"})
    with urllib.request.urlopen(req, timeout=60) as r:
        return json.loads(r.read())["result"]

def asset_label(aid):
    if aid == 1: return "ETH"
    if aid == SHERWOOD: return "SHERWOOD"
    return f"asset {aid}"

# deposit block per summary; widen the window around the op (Aug 29 ~15:41-18:00 UTC)
fr, to = 49640000, 49680000
logs = rpc("eth_getLogs", [{"address": VAULT, "topics": [TOPIC0], "fromBlock": hex(fr), "toBlock": hex(to)}])
print(f"logs in window {fr}-{to}: {len(logs)}")

rows = []
for lg in logs:
    aid = int(lg["topics"][1], 16)
    commit = lg["topics"][2]
    idx = int(lg["topics"][3], 16)
    blob = lg["data"]
    txh = lg["transactionHash"]
    blk = int(lg["blockNumber"], 16)
    rows.append((blk, txh, aid, idx, commit, len(blob)//2 - 1))
rows.sort()

# fetch senders for the window's txs (unique)
txns = sorted(set(r[1] for r in rows))
senders = {}
for txh in txns:
    try:
        rc = rpc("eth_getTransactionReceipt", [txh])
        senders[txh] = (rc.get("from"), rc.get("to"))
    except Exception as e:
        senders[txh] = ("ERR", str(e)[:40])

print(f"\n{'blk':>10} {'asset':<10} {'idx':>5}  {'from':<44} {'blobB':>4}  commitment")
for blk, txh, aid, idx, commit, blen in rows:
    frm = senders.get(txh, ("?",))[0]
    mark = " <== OURS" if frm and frm.lower() == WALLET else ""
    print(f"{blk:>10} {asset_label(aid):<10} {idx:>5}  {str(frm):<44} {blen:>4}  {commit[:18]}…{mark}")
