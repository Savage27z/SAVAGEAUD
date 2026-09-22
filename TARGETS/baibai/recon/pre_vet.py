#!/usr/bin/env python3
"""BaiBai Phase-0 on-chain pre-vet: resolve every published proxy -> impl, measure code,
read the module ABI, and check explorer verification status."""
import json, urllib.request, urllib.error, sys

BASE_RPC = "https://mainnet.base.org"
EIP1967_IMPL = "0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc"
EIP1967_ADMIN= "0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103"
UA = {"User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) Chrome/128.0 Safari/537.36"}

CONTRACTS = {
    # Base L2
    "L2Bridge":            "0x3348cA6E00224043Ec20089fdadfafec2f5Dc314",
    "L2Router":            "0xbf8E65Fe0711F6B2424372A65070b7A4F2B26567",
    "L2BaibaiAdmin":       "0x28BAd3f46B73Bb95E6224C12AA24A60fD5E3861e",
    # Taker surface (Base mainnet, chain 8453)
    "BaibaiEntrypoint":    "0x98c1D9E102Eb2806D902b13186BDc7892aC4fFBa",
    "BaibaiCurveBook":     "0x604d9b9eB1e1571C78661a6C1088427EC9c8c6E5",
    "BaibaiCustodian":     "0xAaC48FEB93c5C97E0fb3c7C57E1633922A4ACDa3",
}

def rpc(method, params):
    body = json.dumps({"jsonrpc":"2.0","id":1,"method":method,"params":params}).encode()
    req = urllib.request.Request(BASE_RPC, data=body, headers={**UA, "Content-Type":"application/json"})
    try:
        with urllib.request.urlopen(req, timeout=25) as r:
            j = json.loads(r.read())
        if "error" in j: return {"__error__": j["error"]}
        return j.get("result")
    except Exception as e:
        return {"__error__": str(e)}

print(f"chainId = {int(rpc('eth_chainId', []), 16)}  (8453 = Base mainnet)\n")
for name, addr in CONTRACTS.items():
    code = rpc("eth_getCode", [addr, "latest"]) or "0x"
    size = (len(code) - 2) // 2
    impl_slot = rpc("eth_getStorageAt", [addr, EIP1967_IMPL, "latest"])
    admin_slot= rpc("eth_getStorageAt", [addr, EIP1967_ADMIN, "latest"])
    impl = "0x" + impl_slot[-40:] if isinstance(impl_slot,str) and len(impl_slot)>=42 else None
    admin= "0x" + admin_slot[-40:] if isinstance(admin_slot,str) and len(admin_slot)>=42 else None
    zero = "0x" + "0"*40
    rec = {"name":name,"address":addr,"code_size":size,
           "proxy_impl": None if impl in (None, zero) else impl,
           "proxy_admin": None if admin in (None, zero) else admin}
    if rec["proxy_impl"]:
        icode = rpc("eth_getCode", [rec["proxy_impl"], "latest"]) or "0x"
        rec["impl_code_size"] = (len(icode)-2)//2
    print(json.dumps(rec, indent=1))
    # explorer verification (public API, no key)
    try:
        u = f"https://api.basescan.org/api?module=contract&action=getsourcecode&address={addr}"
        with urllib.request.urlopen(urllib.request.Request(u, headers=UA), timeout=25) as r:
            j = json.loads(r.read())
        res = (j.get("result") or [{}])
        if isinstance(res, list) and res:
            src = res[0].get("SourceCode") or ""
            print(f"   basescan: verified={'YES' if src else 'NO'}  name={res[0].get('ContractName')!r}  compiler={res[0].get('CompilerVersion')!r}  proxy={res[0].get('Proxy')!r}")
        else:
            print(f"   basescan: {j.get('message')} {j.get('result')}")
    except Exception as e:
        print(f"   basescan check failed: {e}")
    print()
