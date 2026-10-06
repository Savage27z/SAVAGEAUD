#!/usr/bin/env python3
"""
GILDer pass 6 - resolve the 6 proxy impls, pull each impl's ABI from Sourcify,
find the Treasury module, then read the live coverage/solvency state.

Why: the saved ABIs are for the PROXY shells (GilderUUPSProxy only). The real
business ABI (interestReserve, totalActivePrincipal, effectiveCoverageRequired)
lives on the implementation contract. Sourcify ?fields=all is the working oracle
on this box (Blockscout v2 smart-contracts is broken here).
"""
import json, os, urllib.request, urllib.parse

TGT = "/root/.hermes/workspace/SAVAGEAUD/TARGETS/gilder"
PROXIES = {
    "0x13a18c43be8d5faefb4d00a70817af74be81f06c": "?",
    "0x41e5d0ea02cccae1d8acf0d8533afd9ddf0f1bca": "?",
    "0x904e0e92ebd0a40d04c5b54be4c75447879c2a5d": "?",
    "0x9e2ce9510a89deac71898fd0a86d84214c20607b": "treasury",
    "0xaa199c5605c221574d9738ada3d04ceea493e658": "?",
    "0xf2e668f7e457d16e546ba56f531b007a17f946e8": "?",
}
BOND = "0x5d25cfc927f95cb519c0fef438afaa64cb374e10"
IMPL_SLOT = "0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc"
BPS_SLOT  = "0xa3f0ad74e5423aebfd80d3ef4346578335a9a72aeaee59ff6cb3582b35133d50"

RPCS = ["https://mainnet.base.org", "https://base-rpc.publicnode.com",
        "https://1rpc.io/base", "https://base.drpc.org"]
UA = ("Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/125.0 Safari/537.36")


def http_get(url):
    req = urllib.request.Request(url, headers={"User-Agent": UA})
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.loads(r.read())


def rpc(method, params):
    for url in RPCS:
        try:
            req = urllib.request.Request(url, method="POST",
                headers={"Content-Type": "application/json", "User-Agent": UA},
                data=json.dumps({"jsonrpc": "2.0", "id": 1,
                                 "method": method, "params": params}).encode())
            with urllib.request.urlopen(req, timeout=25) as r:
                j = json.loads(r.read())
            if "result" in j and j["result"] not in (None, "0x"):
                return j["result"]
        except Exception:
            continue
    return None


def keccak_sel(sig):
    from Crypto.Hash import keccak
    k = keccak.new(digest_bits=256); k.update(sig.encode())
    return k.hexdigest()[:8]


def impl_of(proxy):
    raw = rpc("eth_getStorageAt", [proxy, IMPL_SLOT, "latest"])
    if not raw or len(raw) < 42:
        return None
    return "0x" + raw[-40:]


def abi_of(addr):
    # NB: field NAMES in the query string 400 (e.g. ?fields=abi,match). The
    # working call on this box is ?fields=all, which returns 1 MB and includes
    # 'abi' (and 'signatures', 'storageLayout', 'proxyResolution').
    url = f"https://sourcify.dev/server/v2/contract/8453/{addr}?fields=all"
    try:
        j = http_get(url)
    except Exception as e:
        return None, f"http:{e}"
    if isinstance(j, dict):
        return j.get("abi"), j.get("match") or j.get("runtimeMatch")
    return None, "shape"


def dec(out):
    if not isinstance(out, str) or not out.startswith("0x") or len(out) < 3:
        return None
    try:
        return int(out, 16)
    except Exception:
        return None


def main():
    print("== resolving proxy -> impl ==")
    impls = {}
    for p in PROXIES:
        i = impl_of(p)
        impls[p] = i
        print(f"  {p} -> {i}")

    print("\n== impl ABIs (Sourcify) ==")
    impl_abi = {}
    for p, i in impls.items():
        if not i:
            continue
        abi, st = abi_of(i)
        n = len(abi) if isinstance(abi, list) else 0
        print(f"  {i}  entries={n:<4} match={st}")
        if n:
            impl_abi[i] = abi

    # find the module that owns the coverage/solvency views
    want = ["interestReserve", "totalActivePrincipal", "effectiveCoverageRequired",
            "interestCoverageRequired", "buybackReserve", "operationalReserve",
            "totalAllocated", "earlyExitPenaltyTotal", "COVERAGE_TARGET_BPS",
            "interestCoverageTarget", "marketingClaimable", "buybackFloorRequired"]
    owner, hits = None, []
    for i, abi in impl_abi.items():
        names = {e.get("name") for e in abi if isinstance(e, dict)}
        got = [w for w in want if w in names]
        if got:
            print(f"\n  module {i} exposes {len(got)} of the wanted views: {got}")
            if len(got) > len(hits):
                owner, hits = i, got

    if not owner:
        print("\n!! no module exposes the coverage views; dumping per-impl function names")
        for i, abi in impl_abi.items():
            names = sorted(e.get("name", "") for e in abi
                           if isinstance(e, dict) and e.get("type") == "function")
            print(f"\n  {i}: {names[:40]}")
        return

    print(f"\n== reading live state on treasury proxy {TREASURY} ==")
    abi = impl_abi[owner]
    sel_map = {}
    for e in abi:
        if e.get("type") != "function" or e.get("inputs"):
            continue
        n = e.get("name")
        if n in want:
            sel_map[keccak_sel(f"{n}()")] = n
    for sel, n in sel_map.items():
        v = dec(rpc("eth_call", [{"to": TREASURY, "data": "0x" + sel}, "latest"]))
        print(f"  {n:<30} = {v if v is not None else 'NO DATA'}")

    # also bond-side
    print(f"\n== reading live state on BondContract {BOND} ==")
    for sel, n in sel_map.items():
        v = dec(rpc("eth_call", [{"to": BOND, "data": "0x" + sel}, "latest"]))
        if v is not None:
            print(f"  {n:<30} = {v}")

    json.dump({p: impls[p] for p in impls}, open(os.path.join(TGT, "pass6_impls.json"), "w"), indent=2)
    print("\nsaved -> pass6_impls.json")


TREASURY = "0x9e2ce9510a89deac71898fd0a86d84214c20607b"
if __name__ == "__main__":
    main()
