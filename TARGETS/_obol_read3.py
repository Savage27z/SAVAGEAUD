#!/usr/bin/env python3
"""Third read pass: account impl config, live constitutions, and the USDG token."""
import json, os, urllib.request

RPC = "https://rpc.mainnet.chain.robinhood.com"
META = "/root/.hermes/workspace/SAVAGEAUD/TARGETS/obol/meta"
UA = "Mozilla/5.0 Chrome/153"
SALE = "0xD22301bcA4eCfFb9F4B87792885D766595e7363c"
IMPL = "0xac855818bc77cd378d7ce24ab6151491e1623dc6"

def rpc(m, p):
    body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": m, "params": p}).encode()
    req = urllib.request.Request(RPC, data=body, headers={"Content-Type": "application/json", "User-Agent": UA})
    with urllib.request.urlopen(req, timeout=60) as r:
        o = json.loads(r.read().decode())
    if "error" in o: return {"ERR": o["error"]}
    return o["result"]

def try_call(to, sel, args=""):
    return rpc("eth_call", [{"to": to, "data": sel + args}, "latest"])

impl = json.load(open(os.path.join(META, "accountImpl.json")))

def sig(d, fname):
    for s in (d.get("signatures") or {}).get("function", []):
        if s["signature"].startswith(fname + "("):
            return s
    return None

print("=== accountImpl function surface ===")
for s in (impl.get("signatures") or {}).get("function", []):
    print("  ", s["signature"], "->", s["signatureHash4"][:10])

d = sig(impl, "dollar")
print("\n  dollar() sig:", d and d["signature"])
dv = try_call(IMPL, d["signatureHash4"])
print("  dollar() =", dv)
if isinstance(dv, str) and dv != "0x":
    dollar = "0x" + dv[-40:]
    for label, s2 in (("name", "0x06fdde03"), ("symbol", "0x95d89b41"), ("decimals", "0x313ce567")):
        r = try_call(dollar, s2)
        if isinstance(r, dict):
            print(f"  USDG {label}: ERR {r['ERR'].get('message')}")
        elif label == "decimals":
            print(f"  USDG decimals: {int(r, 16)}")
        else:
            ln = int(r[2+64:2+128], 16)
            print(f"  USDG {label}: {bytes.fromhex(r[2+128:2+128+ln*2]).decode('utf8','replace')}")
    print("  USDG code bytes:", (len(rpc('eth_getCode', [dollar, 'latest'])) - 2)//2)

print("\n=== live constitution on sold accounts ===")
accts = {
    0: "0x0490414a5904c327868c4245e579d303647586ff",
    1: "0x049b7975e0f9899fc052be52680be75ba7a47705",
}
for tid, a in accts.items():
    c = sig(impl, "constitution")
    r = try_call(a, c["signatureHash4"])
    if isinstance(r, dict):
        print(f"  #{tid} constitution: ERR {r['ERR'].get('message')}")
        continue
    raw = r[2:]
    w = [raw[i*64:(i+1)*64] for i in range(5)]
    print(f"  #{tid} configuredBy={('0x'+w[0][-40:])} agent={('0x'+w[1][-40:])} maxPerCall={int(w[2],16)} maxPerDay={int(w[3],16)} maxEthPerCall={int(w[4],16)}")
    st = sig(impl, "state")
    print(f"       state={int(try_call(a, st['signatureHash4']),16)}  eth balance={int(rpc('eth_getBalance',[a,'latest']),16)/1e18:.6f}")
    sp = sig(impl, "spentToday")
    if sp:
        r2 = try_call(a, sp["signatureHash4"])
        print(f"       spentToday={int(r2,16)}")
