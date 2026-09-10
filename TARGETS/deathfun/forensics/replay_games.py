import json, subprocess, hashlib

RPC = "https://api.mainnet.abs.xyz"
PROXY = "0x27EDd16eE56958fddCBA08947f12C43DDeC2B20C"


def rpc(method, params):
    payload = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params})
    return json.loads(subprocess.run(
        ["curl", "-s", "-m", "60", "-X", "POST", RPC, "-H", "content-type: application/json", "-d", payload],
        capture_output=True, text=True).stdout, strict=False)


from eth_hash.auto import keccak
SEL = keccak(b"getGameDetails(uint256)")[:4].hex()


def parse(res):
    h = res[2:]
    w = [h[i:i + 64] for i in range(0, len(h), 64)]
    # w[0] = offset to tuple (=32 -> tuple starts at word 1)

    def s(k):  # k = 1-based tuple field index
        off = 1 + int(w[k], 16) // 32
        ln = int(w[off], 16)
        body = h[(off + 1) * 64: (off + 1) * 64 + ln * 2]
        return bytes.fromhex(body).decode()
    return {
        "createdAt": int(w[1], 16),
        "player": "0x" + w[2][24:],
        "bet": int(w[3], 16),
        "status": int(w[4], 16),
        "payout": int(w[5], 16),
        "seedHash": w[6],
        "seed": s(7),
        "algoVersion": s(8),
        "gameConfig": s(9),
        "gameState": s(10),
    }


def sh(s):
    return hashlib.sha256(s.encode()).hexdigest()


def dti(seed, i, d):
    return int(sh(f"{seed}-row{i}")[:8], 16) % d


logs = json.load(open("/tmp/deathfun/logs.json"))["result"]
ids = [int(l["topics"][1], 16) for l in logs[-10:]]

ok = 0
tot = 0
for gid in ids:
    r = rpc("eth_call", [{"to": PROXY, "data": "0x" + SEL + gid.to_bytes(32, "big").hex()}, "latest"])
    res = r.get("result")
    if not res or len(res) < 100:
        print(gid, "err", str(r)[:150]); continue
    g = parse(res)
    rowcfg = json.loads(g["gameConfig"]).get("rowConfig", [])
    picked = json.loads(g["gameState"]).get("selectedTiles", [])
    tiles = [dti(g["seed"], i, t) for i, t in enumerate(rowcfg)]
    died = next((i for i, p in enumerate(picked) if i < len(tiles) and tiles[i] == p), None)
    consistent = (g["status"] == 2 and died is not None) or (g["status"] == 1 and died is None)
    tot += 1
    ok += consistent
    print(f"game {gid} status={g['status']} bet={g['bet']} payout={g['payout']} picked={picked}")
    print(f"   rows={len(rowcfg)} deathTiles={tiles[:max(len(picked),1)+1]} died_at={died} consistent={consistent}")
    print(f"   algo={g['algoVersion']} seedHash={g['seedHash']}")
print(f"\nCONSISTENT {ok}/{tot}")
