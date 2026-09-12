#!/usr/bin/env python3
"""nar.bet — batch read-only eth_calls that kill or sharpen the top hypotheses.
Free, non-destructive, no wallet. Selectors derived from the recovered ABI."""
import json, subprocess
from eth_hash.auto import keccak

RPC = "https://rpc.monad.xyz"
GAMES = {
    "proxyA_2739B": "0x71dc4a726C92E6bf506F2Afc2Cee8B63A89B29EC",
    "proxyB_209B":  "0x0B1E533e33f9E82849E71fb5c0a33F38462D5eD4",
    "root_149B":    "0xE6d461c863987F2a1096eA3476137F30f75B3d46",
    "registry_149B":"0xa4338eadf4D2e0851eFb225b0Eab90bE47A095F1",
    "resolver_149B":"0x314582158A0a72802aD8F6EeE6243C73dCf1F562",
}


def rpc(method, params):
    p = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params})
    out = subprocess.run(["curl", "-s", "-m", "25", "-X", "POST", RPC,
                          "-H", "content-type: application/json", "-d", p],
                         capture_output=True, text=True).stdout
    try:
        return json.loads(out, strict=False)
    except Exception:
        return {"_raw": out[:200]}


def sel(sig):
    return "0x" + keccak(sig.encode())[:4].hex()


def call(to, sig, args=""):
    r = rpc("eth_call", [{"to": to, "data": sel(sig) + args}, "latest"])
    if "error" in r:
        return None, str(r["error"])[:70]
    res = r.get("result")
    if not res or res == "0x":
        return None, "reverted/empty"
    return res, None


def u(res):
    return int(res, 16) if res else None


def addr(res):
    return "0x" + res[-40:] if res and len(res) >= 40 else None


VIEWS = ["owner()", "getOwner()", "REFUND_COMMIT_WAIT_BLOCKS()", "REFUND_TIMEOUT_BLOCKS()",
         "getRandomFee()", "edgeFactor()", "maxMultiplier()", "riskCap()", "wagerNumber()",
         "bankroll()", "entropy()", "proxiableUUID()", "getFeeInfo()",
         "name()", "symbol()", "totalSupply()", "decimals()"]

for label, a in GAMES.items():
    print(f"\n=========== {label}  {a}")
    for v in VIEWS:
        res, err = call(a, v)
        if err:
            continue
        if v.endswith("()") and v.split("(")[0] in ("owner", "getOwner", "bankroll", "entropy"):
            print(f"  {v:28s} {addr(res)}")
        elif v == "getFeeInfo()":
            print(f"  {v:28s} raw={res[:130]}")
        elif v == "proxiableUUID()":
            print(f"  {v:28s} {res}")
        elif v in ("name()", "symbol()"):
            h = res[2:]
            off = int(h[:64], 16) // 32
            ln = int(h[off * 64:(off + 1) * 64], 16)
            s = bytes.fromhex(h[(off + 1) * 64:(off + 1) * 64 + ln * 2]).decode(errors="replace")
            print(f"  {v:28s} {s!r}")
        else:
            print(f"  {v:28s} {u(res)}")
