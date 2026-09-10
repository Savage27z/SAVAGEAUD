"""
Step 2: reproduce gameSeedHash from (seed, gameConfig, algoVersion, ...) using settled games.

If any formulation reproduces the on-chain hash, we know the exact commitment scheme, and the
next question becomes: is the *seed* predictable from data visible BEFORE the player picks?

The struct comment claims: gameSeedHash = "Hash of the seed + gameConfig + algoVersion".
"""
import json, itertools
from Crypto.Hash import keccak

def k(b):
    h = keccak.new(digest_bits=256); h.update(b); return h.digest()
def kh(b): return "0x" + k(b).hex()

def abi_enc(*parts):
    """Minimal ABI encoder for a mix of str/bytes32/uint/address, as keccak256(abi.encode(...))."""
    head, tail = [], b""
    off = 0
    # first pass: compute head size (32 bytes per slot; dynamic parts take one slot)
    nslots = 0
    for p in parts:
        nslots += 1
    headsize = 32 * nslots
    for p in parts:
        if isinstance(p, str):
            b = p.encode()
            pad = (-len(b)) % 32
            data = len(b).to_bytes(32, "big") + b + b"\x00" * pad
            head.append((headsize + off).to_bytes(32, "big"))
            tail += data
            off += len(data)
        elif isinstance(p, bytes):
            if len(p) == 32:
                head.append(p)
            else:
                pad = (-len(p)) % 32
                data = len(p).to_bytes(32, "big") + p + b"\x00" * pad
                head.append((headsize + off).to_bytes(32, "big"))
                tail += data
                off += len(data)
        elif isinstance(p, int):
            head.append(p.to_bytes(32, "big"))
        else:
            raise TypeError(type(p))
    return b"".join(head) + tail

def packed(*parts):
    out = b""
    for p in parts:
        if isinstance(p, str): out += p.encode()
        elif isinstance(p, bytes): out += p
        elif isinstance(p, int): out += p.to_bytes(32, "big")
    return out

games = json.load(open("/tmp/settled_games.json"))
print(f"testing against {len(games)} settled games\n")

def candidates(g):
    seed_hex = g["gameSeed"]                      # '0x...'
    seed_b32 = bytes.fromhex(seed_hex[2:])
    cfg = g["gameConfig"]
    algo = g["algoVersion"]
    player = g["player"]
    gid = g["gid"]
    bet = g["betAmount"]
    created = g["createdAt"]
    yield "abi.encode(seedB32,cfg,algo)", abi_enc(seed_b32, cfg, algo)
    yield "abi.encode(seedStr,cfg,algo)", abi_enc(seed_hex, cfg, algo)
    yield "abi.encode(seedB32,algo,cfg)", abi_enc(seed_b32, algo, cfg)
    yield "abi.encode(cfg,algo,seedB32)", abi_enc(cfg, algo, seed_b32)
    yield "packed(seedStr,cfg,algo)", packed(seed_hex, cfg, algo)
    yield "packed(seedB32,cfg,algo)", packed(seed_b32, cfg, algo)
    yield "packed(seedB32,algo,cfg)", packed(seed_b32, algo, cfg)
    yield "packed(seedStr,algo,cfg)", packed(seed_hex, algo, cfg)
    yield "packed(cfg,algo,seedStr)", packed(cfg, algo, seed_hex)
    yield "abi.encode(seedB32,cfg,algo,gid)", abi_enc(seed_b32, cfg, algo, gid)
    yield "abi.encode(seedB32,cfg,algo,player)", abi_enc(seed_b32, cfg, algo, bytes.fromhex(player[2:]))
    yield "abi.encode(seedB32,cfg,algo,created)", abi_enc(seed_b32, cfg, algo, created)
    yield "abi.encode(seedB32,cfg,algo,bet)", abi_enc(seed_b32, cfg, algo, bet)
    yield "abi.encode(seedB32,cfg,algo,player,bet,created)", abi_enc(
        seed_b32, cfg, algo, bytes.fromhex(player[2:]), bet, created)
    yield "packed(seedB32,cfg,algo,player)", packed(seed_b32, cfg, algo, player)
    yield "keccak(seedB32) only", seed_b32
    yield "json-ordered seed+cfg+algo", packed(seed_hex, cfg, algo)

hits = {}
for g in games[:8]:
    target = g["seedHash"].lower()
    for name, payload in candidates(g):
        if kh(payload).lower() == target:
            hits.setdefault(name, []).append(g["gid"])

print("=== formulations that REPRODUCE the on-chain gameSeedHash ===")
if hits:
    for name, gids in hits.items():
        print(f"  ✅ {name}   ({len(gids)} games)")
else:
    print("  (none yet)")

print("\n=== per-game detail for the first game, so we can see what we're missing ===")
g = games[0]
print("  seed     :", g["gameSeed"])
print("  seedHash :", g["seedHash"])
print("  cfg      :", g["gameConfig"])
print("  algo     :", g["algoVersion"])
print("  player   :", g["player"])
print("  gid      :", g["gid"])
print("  created  :", g["createdAt"])
print("  bet      :", g["betAmount"])
print("  state    :", g["gameState"])
print("\n  sample computed values:")
for name, payload in candidates(g):
    print(f"    {name:44} {kh(payload)[:26]}...")

# Is the seed itself just keccak of something guessable?
print("\n=== is the seed derivable from other public fields? ===")
for g in games[:8]:
    seed = g["gameSeed"].lower()
    checks = {
        "keccak(player)": kh(bytes.fromhex(g["player"][2:])),
        "keccak(gid)": kh(g["gid"].to_bytes(32, "big")),
        "keccak(createdAt)": kh(g["createdAt"].to_bytes(32, "big")),
        "keccak(player,gid)": kh(packed(g["player"], g["gid"])),
        "keccak(gid,createdAt)": kh(packed(g["gid"], g["createdAt"])),
        "keccak(player,createdAt)": kh(packed(g["player"], g["createdAt"])),
    }
    m = [n for n, v in checks.items() if v.lower() == seed]
    if m:
        print(f"  game {g['gid']}: SEED DERIVABLE via {m}")
print("  (nothing printed above = seed does not look derivable from those fields)")
