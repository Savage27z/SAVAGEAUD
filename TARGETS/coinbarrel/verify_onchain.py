#!/usr/bin/env python3
"""Coinbarrel V5 (RHC 4663) Phase 0.5 on-chain verification.

Checks per application proxy:
  - ERC1967 implementation slot (0x360894...)
  - Ownable2Step owner()  [0x8da5cb5b]
  - pendingOwner()       [0xe30c3978]
Then Blockscout verification status for proxies/impls/custody.
Rate-limited per CHAIN_INFO.md (sleep 2 between RPC calls).
"""
import json, time, urllib.request

RPC = "https://rpc.mainnet.chain.robinhood.com"
API = "https://robinhoodchain.blockscout.com"

IMP_SLOT = "0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc"
OWNER_CALL = "0x8da5cb5b"
PEND_CALL = "0xe30c3978"

PROXIES = {
    "launcherProxy":        "0x4234e536aa5da8be18d41ef6f86533430e264e70",
    "positionVaultProxy":   "0x685c85df6836df5713efe89ab1348183651ce9e1",
    "hookProxy":            "0xf667c59cd75ab1d7943fc8284edab51f3a76bfff",
    "feeRouter":            "0xfff9bbf167221380e964ef4cd7636ed8ccb10562",
    "stockRegistry":        "0x28873508089083214d801d7b7f4829722c226f9e",
    "impairmentController": "0x4f16b5707f729160dd7acef78fe67ed8f25174d0",
}
DOCS_IMPLS = {
    "launcherProxy":        "0xfce63ecc3c3db5705a669eed8c148139ca99d73f",
    "positionVaultProxy":   "0x53fb5d665acf13e8f5d38c03efca419d311fe83a",
    "hookProxy":            "0xaf4ea6726c6149b647f494c84553e3449cfb9379",
    "feeRouter":            "0xa4bcdb94857c77701e0be69f63fab436ecdc7d74",
    "stockRegistry":        "0x27307a9fd8e2cd0073e550cb997e0c0f59f85be1",
    "impairmentController": "0x7616d1a966ee6b5ad7075dda0e67a8017c03472f",
}
CUSTODY = "0x418ece71c4ece08b71db8c53d59b6bc345efc659"
POSITION_MANAGER = "0x58daec3116aae6d93017baaea7749052e8a04fa7"

def rpc(method, params):
    body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}).encode()
    req = urllib.request.Request(RPC, data=body, headers={
        "Content-Type": "application/json",
        "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0 Safari/537.36",
    })
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.loads(r.read())["result"]

def addr_of(data):
    if not data or data == "0x":
        return None
    return "0x" + data[-40:].lower()

def call(to, calldata):
    return rpc("eth_call", [{"to": to, "data": calldata}, "latest"])

def get_code(a):
    return rpc("eth_getCode", [a, "latest"])

def blockscout_verified(a):
    for ep in (f"/api/v2/smart-contracts/{a}",):
        try:
            req = urllib.request.Request(API + ep, headers={"User-Agent": "curl/8"})
            with urllib.request.urlopen(req, timeout=30) as r:
                d = json.loads(r.read())
            if isinstance(d, dict) and ("is_verified" in d or "name" in d):
                return d.get("is_verified"), d.get("name"), d.get("proxy_type")
        except Exception as e:
            pass
    # fallback v1
    try:
        req = urllib.request.Request(API + f"/api?module=contract&action=getsourcecode&address={a}",
                                     headers={"User-Agent": "curl/8"})
        with urllib.request.urlopen(req, timeout=30) as r:
            d = json.loads(r.read())
        res = (d.get("result") or [{}])[0]
        return bool(res.get("SourceCode")), res.get("ContractName"), None
    except Exception as e:
        return None, None, None

print("=== chain ===")
print("chainId:", rpc("eth_chainId", []), "| block:", rpc("eth_blockNumber", []))

for name, addr in PROXIES.items():
    time.sleep(2)
    impl = addr_of(rpc("eth_getStorageAt", [addr, IMP_SLOT, "latest"]))
    code_len = len(get_code(addr)) // 2 - 1 if get_code(addr) not in ("0x", "") else 0
    time.sleep(2)
    owner = addr_of(call(addr, OWNER_CALL))
    time.sleep(2)
    pend = addr_of(call(addr, PEND_CALL))
    match = "MATCH" if impl and impl.lower() == DOCS_IMPLS[name].lower() else "MISMATCH"
    print(f"\n=== {name} ===")
    print(f"  proxy       : {addr} (code bytes: {code_len})")
    print(f"  impl slot   : {impl}  [{match} docs]")
    print(f"  owner()     : {owner}")
    print(f"  pendingOwner: {pend}")

print("\n=== custody (PermanentV4PositionCustody) ===")
time.sleep(2)
print("code bytes:", (len(get_code(CUSTODY)) - 2) // 2 if get_code(CUSTODY) not in ("0x", "") else 0)
time.sleep(2)
impl = addr_of(rpc("eth_getStorageAt", [CUSTODY, IMP_SLOT, "latest"]))
print("ERC1967 impl slot on custody:", impl if impl else "none (not a proxy)")
print("positionManager code bytes:", (len(get_code(POSITION_MANAGER)) - 2) // 2 if get_code(POSITION_MANAGER) not in ("0x", "") else 0)

print("\n=== Blockscout verification ===")
for a in list(PROXIES.values()) + list(DOCS_IMPLS.values()) + [CUSTODY]:
    time.sleep(1)
    v, n, pt = blockscout_verified(a)
    label = [k for k, vv in {**PROXIES, **DOCS_IMPLS}.items() if vv.lower() == a.lower()]
    print(f"  {a}  verified={v} name={n} proxy_type={pt}")
