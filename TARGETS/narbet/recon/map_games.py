#!/usr/bin/env python3
"""nar.bet #4 — map the 10 game proxies to their games via the calibrated existence oracle.

Calibrated rule (learned the hard way): a selector is IMPLEMENTED if the call returns data
OR reverts with a >=4-byte custom-error selector; it is ABSENT if it reverts with EMPTY data
(what a proxy fallback returns when the implementation lacks the selector).
Output: TARGETS/narbet/recon/game-map.json
"""
import json, os, subprocess
from eth_hash.auto import keccak

RPC = "https://rpc.monad.xyz"
SLOT = "0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc"
CANDIDATES = [
    "0xd6F08aF222C8aa69F99B6099F93C6d96897d378f", "0xbbE3FA39912355C49Aa3ccdD02C51d989Fb33E79",
    "0xb9e0b5447B92eb5CF246693F7b533d5c84AA8dC5", "0xb86A1955E96147665d7bdd70E50bD6Af38E086d1",
    "0xb82360d08784f0Ff24A740ADaD6b1AC2391C8D57", "0x843D62ad75F5d0b383f8520e23d19174b7961b8E",
    "0x8261A173DC96e206b8D8621ca1231a3E7bcB851E", "0x5859E2926750F3981f95bbA16b86d8e69cf4334B",
    "0x4A050DD00c08856cc3d7C5BD152E4e601ffDaa35", "0x3014d056Db789984552084Db359D7C56A620549b",
]
GAMES = ["CoinFlip", "Dice", "Range", "Crash", "Limbo", "Mines", "Plinko", "Keno", "Slots",
         "Roulette", "Baccarat", "SicBo", "HiLo", "War", "DragonTiger", "FishPrawnCrab",
         "RockPaperScissors", "VideoPoker", "WheelOfFortune"]


def raw(method, params):
    out = subprocess.run(["curl", "-s", "-m", "25", "-X", "POST", RPC,
                          "-H", "content-type: application/json",
                          "-d", json.dumps({"jsonrpc": "2.0", "id": 1, "method": method,
                                            "params": params})], capture_output=True, text=True).stdout
    try:
        return json.loads(out, strict=False)
    except Exception:
        return {}


def probe(to, sig):
    o = raw("eth_call", [{"to": to, "data": "0x" + keccak(sig.encode())[:4].hex() + "0" * 64}, "latest"])
    if o.get("result") and o["result"] != "0x":
        return True
    err = o.get("error") or {}
    d = err.get("data") if isinstance(err, dict) else None
    if d is None and isinstance(err, dict) and isinstance(err.get("cause"), dict):
        d = err["cause"].get("data")
    return isinstance(d, str) and len(d) >= 10


mapping = {}
for a in CANDIDATES:
    r = raw("eth_getStorageAt", [a, SLOT, "latest"]).get("result")
    impl = "0x" + r[-40:] if r and len(r) >= 42 else None
    found = [g for g in GAMES if probe(a, f"{g}_GetState(address)")]
    extra = [s for s in ("getRandomFee()", "edgeFactor()", "REFUND_COMMIT_WAIT_BLOCKS()", "entropy()",
                         "Mines_SetMultipliers(uint256)", "VideoPoker_Start(uint256,address)")
             if probe(a, s)]
    mapping[a] = dict(impl=impl, games=found, extra=extra)
    print(f"{a}  impl={impl}")
    print(f"    games: {found if found else '(none matched)'}   extra: {extra}")

os.makedirs(os.path.expanduser("~/.hermes/workspace/SAVAGEAUD/TARGETS/narbet/recon"), exist_ok=True)
json.dump(mapping, open(os.path.expanduser(
    "~/.hermes/workspace/SAVAGEAUD/TARGETS/narbet/recon/game-map.json"), "w"), indent=1)
print("\nunique implementations:", len({v['impl'] for v in mapping.values()}))
