import json, subprocess, collections
from concurrent.futures import ThreadPoolExecutor

RPC = "https://api.mainnet.abs.xyz"
SEL = "0b669290"  # increaseBet(uint256,uint256,uint256,bytes)

logs = json.load(open("/tmp/deathfun/betincrease.json"))
logs.sort(key=lambda l: int(l["blockNumber"], 16))
hashes = [l["transactionHash"] for l in logs]
print("txs to fetch:", len(hashes))


def fetch(h):
    payload = json.dumps({"jsonrpc": "2.0", "id": 1, "method": "eth_getTransactionByHash", "params": [h]})
    out = subprocess.run(["curl", "-s", "-m", "30", "-X", "POST", RPC,
                          "-H", "content-type: application/json", "-d", payload],
                         capture_output=True, text=True).stdout
    try:
        return json.loads(out, strict=False).get("result")
    except Exception:
        return None


with ThreadPoolExecutor(max_workers=16) as ex:
    txs = list(ex.map(fetch, hashes))

print("fetched:", sum(1 for t in txs if t))
json.dump([t for t in txs if t], open("/tmp/deathfun/bet_txs.json", "w"))

seen = collections.defaultdict(list)
rows = []
for t in txs:
    if not t:
        continue
    inp = t.get("input", "0x")
    if not inp[2:].lower().startswith(SEL):
        rows.append(("NON_MATCH", t.get("hash"), inp[:20]))
        continue
    body = inp[2 + 8:]
    words = [body[i:i + 64] for i in range(0, len(body), 64)]
    gid = int(words[0], 16)
    amount = int(words[1], 16)
    deadline = int(words[2], 16)
    off = int(words[3], 16) // 32
    slen = int(words[3 + off], 16)
    sig = words[3 + off + 1:][0][:slen * 2]
    seen[sig].append(t["hash"])
    rows.append((gid, amount, deadline, t.get("value"), sig, t["hash"]))

print("\nrows parsed:", len(rows))
dupes = {s: hs for s, hs in seen.items() if len(hs) > 1}
print("DISTINCT signatures:", len(seen))
print("DUPLICATED signatures (same sig used more than once):", len(dupes))
for s, hs in list(dupes.items())[:5]:
    print("  sig", s[:32], "... used", len(hs), "times:", hs[:4])

import datetime
dl = [r[2] for r in rows if isinstance(r[0], int)]
if dl:
    print("\nmin deadline:", datetime.datetime.utcfromtimestamp(min(dl)))
    print("max deadline:", datetime.datetime.utcfromtimestamp(max(dl)))
json.dump([{"gid": r[0], "amount": r[1], "deadline": r[2], "value": r[3], "sig": r[4], "tx": r[5]}
           for r in rows if isinstance(r[0], int)], open("/tmp/deathfun/bet_decoded.json", "w"))
print("\nsaved bet_decoded.json")
