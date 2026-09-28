#!/usr/bin/env python3
"""GILDer Phase 0.5 input — on-chain privilege surface (TMAAR must be written BEFORE reading code).

For every verified contract: resolve the EIP-1967 impl, then read owner/admin/roles and key config
via the contract's own ABI (fetched from Sourcify, NOT read by hand).
Read-only: eth_getStorageAt / eth_call.
"""
import json, os, time, urllib.error, urllib.request

BASE = os.path.dirname(os.path.abspath(__file__))
TGT = os.path.join(BASE, "gilder")
ABID = os.path.join(TGT, "abi")
os.makedirs(ABID, exist_ok=True)
UA = ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/128.0 Safari/537.36")
RPC = "https://mainnet.base.org"
CHAIN = 8453
from Crypto.Hash import keccak as _k
def keccak(b): h = _k.new(digest_bits=256); h.update(b); return h.digest()

def get(url, raw=False, t=30, tries=3):
    for a in range(tries):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": UA, "Accept": "*/*"})
            b = urllib.request.urlopen(req, timeout=t).read().decode("utf-8", "replace")
            return b if raw else json.loads(b)
        except urllib.error.HTTPError as e:
            try:
                b = e.read().decode("utf-8", "replace")
                return b if raw else json.loads(b)
            except Exception:
                pass
        except Exception:
            pass
        time.sleep(0.8 + 0.4 * a)
    return "__ERR__" if raw else {}

def rpc(method, params, tries=3):
    for a in range(tries):
        try:
            req = urllib.request.Request(RPC, data=json.dumps(
                {"jsonrpc": "2.0", "id": 1, "method": method, "params": params}).encode(),
                headers={"Content-Type": "application/json", "User-Agent": UA})
            return json.loads(urllib.request.urlopen(req, timeout=25).read()).get("result")
        except Exception:
            time.sleep(0.7)
    return None

def sig(name, ins=()):
    return "0x" + keccak(f"{name}({','.join(ins)})".encode()).hex()[:8]

EIP1967_IMPL = "0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc"
EIP1967_ADMIN = "0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103"

contracts = json.load(open(os.path.join(TGT, "phase0_contracts.json")))
print("=" * 100)
print("GILDer — privilege surface (read-only)")
print("=" * 100)
rows = []
for c in contracts:
    a, size, match = c["addr"], c["size"], c["match"]
    name = (c.get("name") or ["?"])[0]
    impl = rpc("eth_getStorageAt", [a, EIP1967_IMPL, "latest"])
    admin = rpc("eth_getStorageAt", [a, EIP1967_ADMIN, "latest"])
    impl_addr = ("0x" + impl[-40:]) if isinstance(impl, str) and int(impl, 16) else None
    admin_addr = ("0x" + admin[-40:]) if isinstance(admin, str) and int(admin, 16) else None
    # fetch ABI
    full = get(f"https://sourcify.dev/server/v2/contract/{CHAIN}/{a}?fields=all")
    abi = (full or {}).get("abi") if isinstance(full, dict) else None
    if abi:
        json.dump(abi, open(os.path.join(ABID, f"{a}.json"), "w"), indent=1)
    print(f"\n### {name}  {a}  {size:,}B  ({match})")
    print(f"    EIP-1967 impl  : {impl_addr or '(none -> not a proxy)'}")
    if admin_addr:
        print(f"    EIP-1967 admin : {admin_addr}")
    if not abi:
        print("    ABI: not fetched")
        rows.append({"addr": a, "name": name, "impl": impl_addr, "admin": admin_addr})
        continue
    fns = {e.get("name") for e in abi if e.get("type") == "function"}
    # read the standard privilege getters if the ABI declares them
    targets = [("owner()", ()), ("admin()", ()), ("paused()", ()),
               ("proxiableUUID()", ()), ("UPGRADE_INTERFACE_VERSION()", ()),
               ("totalDeposits()", ()), ("totalAssets()", ()),
               ("asset()", ()), ("underlying()", ()), ("usdc()", ()),
               ("bondContract()", ()), ("depositNFT()", ()), ("safeVault()", ()),
               ("capitalRouter()", ()), ("treasury()", ()), ("lending()", ()),
               ("governance()", ()), ("turbo()", ()), ("tvt()", ())]
    for fname, ins in targets:
        base = fname.split("(")[0]
        if base not in fns:
            continue
        r = rpc("eth_call", [{"to": a, "data": sig(base)}, "latest"])
        if not isinstance(r, str) or r == "0x":
            continue
        r = r.rstrip("0") if False else r
        raw = r[2:]
        if len(raw) == 64:
            v = int(raw, 16)
            if v > 2**96:
                out = "0x" + raw[-40:]
            else:
                out = str(v)
        else:
            out = "0x" + raw[:64] + "…"
        print(f"    {fname:<28} = {out}")
        rows.append({"addr": a, "name": name, "fn": fname, "val": out})
    roles = sorted(f for f in fns if f and ("ROLE" in f or "role" in f.lower()))
    if roles:
        print(f"    roles declared: {roles[:10]}")

json.dump(rows, open(os.path.join(TGT, "phase0_privilege.json"), "w"), indent=1)
print("\n[saved] phase0_privilege.json + abi/*.json")
