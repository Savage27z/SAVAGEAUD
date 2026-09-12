#!/usr/bin/env python3
"""F09-a: resolve the F05 vs F07 contradiction about the create-response `hash`,
and test whether it correlates with the seed, the board, or a NEIGHBOURING game's
commitment (off-by-one class).  Read-only: eth_call on Abstract mainnet.

Known data point (recorded in F07 §6):
  create hash (game 1a06e1a5-…, became gid 4839273) = 0xbfed306807d95f94f876afe09ffd3a5fb13c3e01135c304aed5945f801326512
  F05 §1 claimed the create `hash` EQUALS the on-chain gameSeedHash ("for every game created").
  F07 §6 recorded it as 0x4a76da3e… and said it is NOT.  These cannot both be true.
"""
import json, subprocess, hashlib
from eth_hash.auto import keccak

RPC = "https://api.mainnet.abs.xyz"
PROXY = "0x27EDd16eE56958fddCBA08947f12C43DDeC2B20C"
CREATE_HASH = "0xbfed306807d95f94f876afe09ffd3a5fb13c3e01135c304aed5945f801326512"
F07_ONCHAIN = "0x4a76da3ecf71de12b1d86f9bda3b4fd8f38a1854caa2542a37d0bcbc563f9929"
TARGET_GID = 4839273


def rpc(method, params, timeout=60):
    p = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params})
    out = subprocess.run(["curl", "-s", "-m", str(timeout), "-X", "POST", RPC,
                          "-H", "content-type: application/json", "-d", p],
                         capture_output=True, text=True).stdout
    return json.loads(out, strict=False)


def games(n):
    data = "0x" + keccak(b"games(uint256)")[:4].hex() + f"{n:064x}"
    r = rpc("eth_call", [{"to": PROXY, "data": data}, "latest"])
    return r.get("result")


def dec_str(h, off_word):
    off = int(h[off_word * 64:(off_word + 1) * 64], 16)
    ln = int(h[(off // 32) * 64:(off // 32 + 1) * 64], 16)
    return bytes.fromhex(h[(off // 32 + 1) * 64:(off // 32 + 1) * 64 + ln * 2]).decode(errors="replace")


def parse(res):
    if not res or len(res) < 2 + 64 * 10:
        return None
    h = res[2:]
    w = lambda i: int(h[i * 64:(i + 1) * 64], 16)
    return dict(
        createdAt=w(0), player="0x" + h[24 + 64:64 + 64], betAmount=w(2), status=w(3),
        payout=w(4), seedHash="0x" + h[5 * 64:6 * 64],
        seed=dec_str(h, 6), algo=dec_str(h, 7), config=dec_str(h, 8), state=dec_str(h, 9))


print("=== reading games() around the target (read-only eth_call) ===")
rows = []
for gid in list(range(TARGET_GID - 4, TARGET_GID + 5)):
    g = parse(games(gid))
    if g:
        g["gid"] = gid
        rows.append(g)
        print(f"  {gid}: status={g['status']} seedHash={g['seedHash'][:20]}… seed={g['seed'][:20] or '(empty)'} "
              f"config={g['config'][:40]!r} algo={g['algo']!r}")

tgt = next((g for g in rows if g["gid"] == TARGET_GID), None)
print()
if tgt:
    print(f"TARGET gid {TARGET_GID}:")
    print(f"  on-chain seedHash : {tgt['seedHash']}")
    print(f"  F07 recorded chain: {F07_ONCHAIN}")
    print(f"  F07 chain claim reproduces: {tgt['seedHash'].lower() == F07_ONCHAIN.lower()}")
    print(f"  create-response hash      : {CREATE_HASH}")
    print(f"  create == its own chain hash : {CREATE_HASH.lower() == tgt['seedHash'].lower()}")

print("\n=== H1 (off-by-one): does the create hash equal a NEIGHBOURING game's seedHash? ===")
hits = [g["gid"] for g in rows if g["seedHash"].lower() == CREATE_HASH.lower()]
print(f"  matches among gids {rows[0]['gid']}..{rows[-1]['gid']}: {hits or 'NONE'}")

print("\n=== H2: is the create hash sha256/keccak of the revealed seed (or seed+config)? ===")
if tgt and tgt["seed"]:
    seed = tgt["seed"]
    s = seed[2:] if seed.startswith("0x") else seed
    # the string form the API/verifier may use, plus raw bytes
    cands = {}
    cands["sha256(seedstr)"] = hashlib.sha256(seed.encode()).hexdigest()
    cands["sha256(seedhex)"] = hashlib.sha256(s.encode()).hexdigest()
    try:
        cands["sha256(seedbytes)"] = hashlib.sha256(bytes.fromhex(s)).hexdigest()
    except Exception:
        pass
    cands["keccak(seedstr)"] = keccak(seed.encode()).hex()
    try:
        cands["keccak(seedbytes)"] = keccak(bytes.fromhex(s)).hex()
    except Exception:
        pass
    for k, v in cands.items():
        print(f"  {k:22} = 0x{v[:32]}…  match={('0x'+v).lower() == CREATE_HASH.lower()}")

print("\n=== H3: does the on-chain seedHash reproduce from (seed, config, algo)? (sanity, contract comment) ===")
if tgt:
    for label, blob in [
        ("seed+config+algo", tgt["seed"] + tgt["config"] + tgt["algo"]),
        ("seed+algo+config", tgt["seed"] + tgt["algo"] + tgt["config"]),
    ]:
        d = hashlib.sha256(blob.encode()).hexdigest()
        k = keccak(blob.encode()).hex()
        print(f"  {label:20} sha256 match={('0x'+d).lower()==tgt['seedHash'].lower()}  keccak match={('0x'+k).lower()==tgt['seedHash'].lower()}")

json.dump(rows, open("/tmp/f09a_games.json", "w"), indent=1)
print("\nsaved /tmp/f09a_games.json")
