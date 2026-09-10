"""Step 1b: dump settled games (seed revealed) — the raw material for the commitment analysis."""
import json, urllib.request
from Crypto.Hash import keccak

RPC = "https://api.mainnet.abs.xyz/"
CONTRACT = "0x27EDd16eE56958fddCBA08947f12C43DDeC2B20C"

def k(b):
    h = keccak.new(digest_bits=256); h.update(b); return h.digest()
def sel(s): return "0x" + k(s.encode()).hex()[:8]
def rpc(m, p):
    body = json.dumps({"jsonrpc": "2.0", "method": m, "params": p, "id": 1}).encode()
    req = urllib.request.Request(RPC, data=body, headers={"Content-Type": "application/json", "User-Agent": "Mozilla/5.0"})
    return json.load(urllib.request.urlopen(req, timeout=30))
def call(to, data):
    r = rpc("eth_call", [{"to": to, "data": data}, "latest"])
    return r.get("result", r.get("error"))

def dec_struct(raw):
    b = bytes.fromhex(raw[2:]); n = len(b)//32
    W = [b[i*32:(i+1)*32] for i in range(n)]
    U = lambda i: int.from_bytes(W[i], "big")
    def dyn(i):
        off = U(i)
        if off == 0: return ""
        pos = 32 + off
        if pos//32 >= n: return ""
        ln = int.from_bytes(b[pos:pos+32], "big")
        return b[pos+32:pos+32+ln].decode("utf-8", "replace")
    return {"createdAt": U(1), "player": "0x"+W[2][12:].hex(), "betAmount": U(3), "status": U(4),
            "payout": U(5), "seedHash": "0x"+W[6].hex(), "gameSeed": dyn(7),
            "algoVersion": dyn(8), "gameConfig": dyn(9), "gameState": dyn(10)}

gc = int(call(CONTRACT, sel("gameCounter()")), 16)
settled = []
scanned = 0
for gid in range(gc, 1, -1):
    scanned += 1
    if scanned > 900 and len(settled) >= 12:
        break
    raw = call(CONTRACT, sel("getGameDetails(uint256)") + f"{gid:064x}")
    if not (isinstance(raw, str) and raw.startswith("0x")):
        continue
    try:
        st = dec_struct(raw)
    except Exception:
        continue
    if st["status"] in (1, 2) and st["gameSeed"]:
        st["gid"] = gid
        settled.append(st)

print(f"scanned {scanned} games, found {len(settled)} settled with revealed seed\n")
for st in settled:
    print(f"game {st['gid']} status={'Won' if st['status']==1 else 'Lost'}")
    for kk in ("player", "createdAt", "betAmount", "payout", "algoVersion", "gameConfig", "gameState", "gameSeed", "seedHash"):
        print(f"   {kk:12} {st[kk]!r}")
    print()

json.dump(settled, open("/tmp/settled_games.json", "w"), indent=2)
print("wrote /tmp/settled_games.json")

# also grab a couple of ACTIVE (unsettled) games — seed hidden, hash public: that's the attack surface
active = []
scanned2 = 0
for gid in range(gc, 1, -1):
    scanned2 += 1
    if scanned2 > 1200 or len(active) >= 6:
        break
    raw = call(CONTRACT, sel("getGameDetails(uint256)") + f"{gid:064x}")
    if not (isinstance(raw, str) and raw.startswith("0x")):
        continue
    try:
        st = dec_struct(raw)
    except Exception:
        continue
    if st["status"] == 0 and st["player"] != "0x" + "0"*40:
        st["gid"] = gid
        active.append(st)
print(f"\nACTIVE (unsettled) games — seed hidden, hash public: {len(active)}")
for st in active[:6]:
    print(f"   game {st['gid']} player={st['player']} createdAt={st['createdAt']} seed={st['gameSeed']!r} hash={st['seedHash'][:20]}...")
json.dump(active, open("/tmp/active_games.json", "w"), indent=2)
