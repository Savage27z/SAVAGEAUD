import hashlib, json, itertools

seed = "0xf97b5d7923ef2bb112edea2595cdb36e254a99a9264aa726f4ae7be74f6de569"
expected = "0xdd19d60536804ea36ea95ba57ce18c95cce799226d284d8f0c80cf66ed868700"
rows_cfg = [3,2,6,2,3,2,3,3,4,4,7,3,5,7,6,2,5,4,4,6,4,7,2,6,4]
version = "v1"


def sha256hex(s: str) -> str:
    return hashlib.sha256(s.encode()).hexdigest()


def dti(seed, idx, tiles):
    return int(sha256hex(f"{seed}-row{idx}")[:8], 16) % tiles


print("death tiles for this game:")
print([dti(seed, i, t) for i, t in enumerate(rows_cfg)])

# multiplier models
def build(house_edge, rounded):
    out = []
    l = 1.0
    for i, d in enumerate(rows_cfg):
        l *= 1 / (1 - 1 / d)
        o = l * (1 - house_edge)
        n = round(o * 100) / 100 if rounded else o
        out.append({"tiles": d, "deathTileIndex": dti(seed, i, d), "multiplier": n})
    return out


cands = {}
for he in (0.01, 0.02, 0.03, 0.04, 0.05, 0.06, 0.07, 0.08, 0.09, 0.1, 0.12, 0.15):
    for rnd in (True, False):
        cands[f"he={he},round={rnd}"] = build(he, rnd)
cands["plain_config"] = rows_cfg
cands["gameConfig"] = {"rowConfig": rows_cfg}
cands["rows_tiles_only"] = [{"tiles": d} for d in rows_cfg]
cands["raw_json"] = json.loads('{"rowConfig":[3,2,6,2,3,2,3,3,4,4,7,3,5,7,6,2,5,4,4,6,4,7,2,6,4]}')

for name, r in cands.items():
    for ver in (version, "1", "v1"):
        for payload in ({"version": ver, "rows": r, "seed": seed},):
            h = "0x" + sha256hex(json.dumps(payload, separators=(",", ":")))
            if h.lower() == expected.lower():
                print("MATCH(no-space)", name, ver)
            h2 = "0x" + sha256hex(json.dumps(payload))
            if h2.lower() == expected.lower():
                print("MATCH(default-json)", name, ver)
print("done")
