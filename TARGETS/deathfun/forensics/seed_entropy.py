import json, subprocess, hashlib, collections

RPC = "https://api.mainnet.abs.xyz"
PROXY = "0x27EDd16eE56958fddCBA08947f12C43DDeC2B20C"
from eth_hash.auto import keccak
SEL = keccak(b"getGameDetails(uint256)")[:4].hex()


def rpc(method, params, timeout=60):
    payload = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params})
    return json.loads(subprocess.run(
        ["curl", "-s", "-m", str(timeout), "-X", "POST", RPC, "-H", "content-type: application/json", "-d", payload],
        capture_output=True, text=True).stdout, strict=False)


def parse(res):
    h = res[2:]
    w = [h[i:i + 64] for i in range(0, len(h), 64)]

    def s(k):
        off = 1 + int(w[k], 16) // 32
        ln = int(w[off], 16)
        return bytes.fromhex(h[(off + 1) * 64:(off + 1) * 64 + ln * 2]).decode()
    return {
        "createdAt": int(w[1], 16), "player": "0x" + w[2][24:], "bet": int(w[3], 16),
        "status": int(w[4], 16), "payout": int(w[5], 16), "seedHash": w[6],
        "seed": s(7), "algoVersion": s(8), "gameConfig": s(9), "gameState": s(10),
    }


logs = json.load(open("/tmp/deathfun/logs.json"))["result"]
ids = [int(l["topics"][1], 16) for l in logs]
print("total games in window:", len(ids))

# sample every Nth game for a broad time spread
sample = ids[::max(1, len(ids) // 120)][:150]
rows = []
for gid in sample:
    r = rpc("eth_call", [{"to": PROXY, "data": "0x" + SEL + gid.to_bytes(32, "big").hex()}, "latest"])
    if r.get("result") and len(r["result"]) > 100:
        g = parse(r["result"])
        g["id"] = gid
        rows.append(g)
print("fetched", len(rows))

seeds = [g["seed"] for g in rows if g["seed"]]
print("non-empty seeds:", len(seeds), "unique:", len(set(seeds)))
lens = collections.Counter(len(s) for s in seeds)
print("seed lengths:", lens)

# structure check
print("\nfirst 12 seeds (id, seed, createdAt):")
for g in rows[:12]:
    print(f"  {g['id']} {g['seed'][:42]}... createdAt={g['createdAt']} status={g['status']}")

# repeated prefixes?
pref = collections.Counter(s[2:10] for s in seeds)
print("\nmost common 8-hex-char prefixes:", pref.most_common(3))

# distinct / first-char distribution
fc = collections.Counter(s[2] for s in seeds)
print("first hex char dist:", sorted(fc.items())[:6])

# does the seed correlate with id or timestamp? compare sorted-by-id vs sorted-by-createdAt
by_id = [g["seed"] for g in rows]
by_time = [g["seed"] for g in sorted(rows, key=lambda x: x["createdAt"])]
print("\nseed order == id order:", by_id == by_time)
print("id monotonic with createdAt:", [g["id"] for g in sorted(rows, key=lambda x: x['createdAt'])] == sorted(g['id'] for g in rows))

# check for sequential/incrementing patterns
import itertools
bad = 0
for a, b in itertools.pairwise(seeds):
    if a == b:
        bad += 1
print("adjacent duplicate seeds:", bad)

# freeze the seed list
json.dump([{k: g[k] for k in ("id", "seed", "seedHash", "createdAt", "player", "status", "bet", "payout")} for g in rows],
          open("/tmp/deathfun/seeds.json", "w"), indent=1)
print("\nsaved /tmp/deathfun/seeds.json")
