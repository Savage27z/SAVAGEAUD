#!/usr/bin/env python3
"""nar.bet #3 — (a) locate which contract hosts the games via the free existence oracle,
(b) reconcile REAL on-chain payouts against the advertised house edge.

Free-enum oracle: a call to a selector the contract does not implement reverts differently
from a call that reaches real logic. No wallet, no state change.
"""
import json, subprocess
from eth_hash.auto import keccak

RPC = "https://rpc.monad.xyz"
CANDS = {
    "0x71dc4a726C92E6bf506F2Afc2Cee8B63A89B29EC": "proxyA(2739B)",
    "0x0B1E533e33f9E82849E71fb5c0a33F38462D5eD4": "proxyB(209B)",
    "0xE6d461c863987F2a1096eA3476137F30f75B3d46": "root(149B)",
    "0xa4338eadf4D2e0851eFb225b0Eab90bE47A095F1": "registry(149B)",
    "0x314582158A0a72802aD8F6EeE6243C73dCf1F562": "resolver(149B)",
}
PROBES = ["CoinFlip_GetState(address)", "Dice_GetState(address)", "Mines_GetState(address)",
          "Plinko_GetState(address)", "Roulette_GetState(address)", "getIsGame(address)",
          "getIsValidWager(address,address)", "getAllSegmentMultipliers()",
          "userShares(address,address)", "tokenTotalShares(address)"]


def rpc(m, p):
    out = subprocess.run(["curl", "-s", "-m", "25", "-X", "POST", RPC,
                          "-H", "content-type: application/json",
                          "-d", json.dumps({"jsonrpc": "2.0", "id": 1, "method": m, "params": p})],
                         capture_output=True, text=True).stdout
    try:
        return json.loads(out, strict=False)
    except Exception:
        return {"_raw": out[:150]}


def call(to, sig, arg_hex=""):
    data = "0x" + keccak(sig.encode())[:4].hex() + arg_hex
    r = rpc("eth_call", [{"to": to, "data": data}, "latest"])
    return r.get("result"), r.get("error")


def exists(to, sig, arg_hex="0000000000000000000000000000000000000000000000000000000000000000"):
    """Implemented => a return value, OR a revert carrying a CUSTOM ERROR selector.
    Not implemented => revert with EMPTY data ('0x') — what a proxy fallback returns when
    the implementation has no such selector. Counting the mere presence of a 'data' key is
    wrong: every revert has one, often as the empty string."""
    res, err = call(to, sig, arg_hex)
    if res and res != "0x":
        return "YES(ret)"
    if err:
        # pull the revert data out of the RPC error payload
        d = None
        try:
            d = err.get("data") or (err.get("cause") or {}).get("data")
        except Exception:
            d = None
        if isinstance(d, str) and len(d) >= 10:      # >=4 bytes => a custom error selector
            return f"YES(err:{d[:10]})"
        return "no(empty-revert)"
    return "revert-no-data"


print("=== free existence oracle: which contract hosts the games? ===")
for a, lab in CANDS.items():
    hits = []
    for p in PROBES:
        r = exists(a, p)
        if r.startswith("YES"):
            hits.append(f"{p.split('(')[0]}={r}")
    print(f"  {lab:16s} {a}")
    print(f"      {'implemented: ' + ', '.join(hits) if hits else 'none of the game selectors'}")
