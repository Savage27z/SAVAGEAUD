#!/usr/bin/env python3
"""Read the privileged state of the BaiBai Base contracts, rotating public RPCs
to survive rate limits. Read-only eth_call. Answers: WHO can upgrade the
unverified implementations, and is any initializer left unclaimed?"""
import json, time, urllib.request, urllib.error

RPCS = ["https://base.llamarpc.com", "https://base-rpc.publicnode.com",
        "https://1rpc.io/base", "https://base.drpc.org", "https://mainnet.base.org"]
UA = {"User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) Chrome/128.0 Safari/537.36"}

def call(to, data, tries=6):
    for i in range(tries):
        url = RPCS[i % len(RPCS)]
        body = json.dumps({"jsonrpc":"2.0","id":1,"method":"eth_call",
                           "params":[{"to":to,"data":data},"latest"]}).encode()
        try:
            with urllib.request.urlopen(urllib.request.Request(
                    url, data=body, headers={**UA,"Content-Type":"application/json"}),timeout=25) as r:
                j = json.loads(r.read())
            if "result" in j: return j["result"]
            if "error" in j: return {"__revert__": (j["error"].get("data") or "")[:12]}
        except urllib.error.HTTPError as e:
            if e.code == 429: time.sleep(1.5*(i+1)); continue
        except Exception:
            time.sleep(1.0*(i+1))
    return {"__err__": "exhausted"}

def addr(res):
    if isinstance(res, dict): return f"REVERT {res.get('__revert__') or res.get('__err__')}"
    if not res or len(res) < 42: return f"empty({res[:12]})"
    a = "0x" + res[-40:]
    return "0x0 (UNINITIALIZED!)" if a == "0x" + "0"*40 else a

def uint(res):
    if isinstance(res, dict): return f"REVERT {res.get('__revert__') or res.get('__err__')}"
    return int(res, 16) if res and len(res) >= 66 else f"empty({res[:12]})"

TARGETS = {
 "BaibaiEntrypoint (swap+approval target)": "0x98c1D9E102Eb2806D902b13186BDc7892aC4fFBa",
 "BaibaiCurveBook  (pricing/depth)":       "0x604d9b9eB1e1571C78661a6C1088427EC9c8c6E5",
 "BaibaiCustodian  (MAKER INVENTORY)":     "0xAaC48FEB93c5C97E0fb3c7C57E1633922A4ACDa3",
}
CALLS = [("owner()", "0x8da5cb5b", addr), ("pendingOwner()", "0xe30c3978", addr),
         ("quoteToken()", "0x217a4b70", addr), ("entrypoint()", "0xa65d69d4", addr),
         ("curveBook()", "0xdbd86869", addr), ("custodian()", "0x375b74c3", addr),
         ("withdrawDelay()", "0x0288a39c", uint)]

for name, a in TARGETS.items():
    print(f"═══ {name}\n    {a}")
    for label, sel, dec in CALLS:
        print(f"    {label:18} {dec(call(a, sel))}")
        time.sleep(0.6)
    print()

# is the L2 admin contract's owner an EOA, multisig or timelock?
print("═══ L2BaibaiAdmin 0x28BAd3f46B73Bb95E6224C12AA24A60fD5E3861e")
for label, sel, dec in [("owner()","0x8da5cb5b",addr),("pendingOwner()","0xe30c3978",addr)]:
    print(f"    {label:18} {dec(call('0x28BAd3f46B73Bb95E6224C12AA24A60fD5E3861e', sel))}")
    time.sleep(0.6)

# what IS the owner address? code size + nonce distinguishes EOA / multisig / timelock
print("\n═══ identifying the upgrade authority")
for cand in ["0x28bad3f46b73bb95e6224c12aa24a60fd5e3861e"]:
    code = call(cand, "0x")  # not valid; use eth_getCode instead
    body = json.dumps({"jsonrpc":"2.0","id":1,"method":"eth_getCode","params":[cand,"latest"]}).encode()
    for i,u in enumerate(RPCS):
        try:
            with urllib.request.urlopen(urllib.request.Request(u,data=body,headers={**UA,"Content-Type":"application/json"}),timeout=25) as r:
                c=json.loads(r.read())["result"]
            print(f"    {cand} code_size={(len(c)-2)//2} bytes -> {'CONTRACT' if len(c)>4 else 'EOA'}")
            break
        except Exception:
            time.sleep(1.0)
