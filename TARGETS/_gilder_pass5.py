#!/usr/bin/env python3
"""
GILDer pass 5 - the ECONOMIC/DESIGN surface (post-code-review class).

Reads the Treasury module's live coverage state and computes the gap between:
  (a) what the protocol OWES depositors (principal + 20%/yr simple for 3yr = 160%),
  (b) what is actually DEPLOYED to earn it (80% of principal),
  (c) what the protocol's OWN coverage target says it must hold (11% of active
      principal = six months of interest).

All read-only. Browser UA required (public Base RPCs WAF-block python-urllib).
"""
import json, os, glob, urllib.request, urllib.error

TGT = "/root/.hermes/workspace/SAVAGEAUD/TARGETS/gilder"
ABI_DIR = os.path.join(TGT, "abi")
TREASURY = "0x9e2ce9510a89deac71898fd0a86d84214c20607b"   # treasury() proxy
BOND     = "0x5d25cfc927f95cb519c0fef438afaa64cb374e10"

RPCS = ["https://mainnet.base.org",
        "https://base-rpc.publicnode.com",
        "https://1rpc.io/base",
        "https://base.drpc.org"]
UA = ("Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/125.0 Safari/537.36")

SEL = {}   # selector -> (name, [input types])


def keccak_sel(sig):
    from Crypto.Hash import keccak
    k = keccak.new(digest_bits=256); k.update(sig.encode())
    return k.hexdigest()[:8]


def rpc(method, params, rpc_url=None):
    for url in ([rpc_url] if rpc_url else RPCS):
        try:
            req = urllib.request.Request(url, method="POST",
                headers={"Content-Type": "application/json", "User-Agent": UA},
                data=json.dumps({"jsonrpc": "2.0", "id": 1,
                                 "method": method, "params": params}).encode())
            with urllib.request.urlopen(req, timeout=25) as r:
                j = json.loads(r.read())
            if "result" in j:
                return j["result"], url
        except Exception:
            continue
    return None, None


def load_abis():
    """Collect view functions of interest across every ABI we saved."""
    want = ("interestReserve", "buybackReserve", "operationalReserve",
            "totalAllocated", "earlyExitPenaltyTotal", "totalActivePrincipal",
            "interestCoverageRequired", "buybackFloorRequired",
            "effectiveCoverageRequired", "interestCoverageTarget",
            "COVERAGE_TARGET_BPS", "registry", "marketingClaimable",
            "reserveBuckets", "tier1CoverageBps")
    found = {}
    for p in glob.glob(os.path.join(ABI_DIR, "*.json")):
        try:
            abi = json.load(open(p))
        except Exception:
            continue
        if isinstance(abi, dict):
            abi = abi.get("abi", [])
        for e in abi:
            if not isinstance(e, dict) or e.get("type") != "function":
                continue
            n = e.get("name", "")
            if n not in want:
                continue
            ins = [i.get("type") for i in e.get("inputs", [])]
            sig = f"{n}({','.join(ins)})"
            found[keccak_sel(sig)] = (n, ins, sig, os.path.basename(p))
    return found


def call(addr, sel, ins, args=None):
    data = "0x" + sel + ("".join(a.rjust(64, "0") for a in (args or [])))
    out, _ = rpc("eth_call", [{"to": addr, "data": data}, "latest"])
    return out


def dec(out):
    if not isinstance(out, str) or not out.startswith("0x") or len(out) < 3:
        return None
    try:
        return int(out, 16)
    except Exception:
        return None


def main():
    print("== ABI symbols found in saved ABIs ==")
    fns = load_abis()
    for sel, (n, ins, sig, src) in sorted(fns.items(), key=lambda kv: kv[1][0]):
        print(f"  0x{sel}  {sig:<52} [{src}]")

    print("\n== Treasury live state (%s) ==" % TREASURY)
    results = {}
    for sel, (n, ins, sig, _src) in fns.items():
        if ins:
            continue          # only zero-arg views here
        out = call(TREASURY, sel, ins)
        v = dec(out)
        results[n] = v
        raw = out[:20] if isinstance(out, str) else repr(out)[:20]
        print(f"  {n:<28} = {v if v is not None else 'NO DATA'}   raw={raw}")

    print("\n== BondContract live state (%s) ==" % BOND)
    for sel, (n, ins, sig, _src) in fns.items():
        if ins or n not in ("totalActivePrincipal",):
            continue
        out = call(BOND, sel, ins)
        print(f"  {n:<28} = {dec(out)}")

    print("\n== THE ECONOMIC GAP (unit deposit of 1000 USDC) ==")
    P = 1000.0
    # split
    sv, tb, tr, lq = P * 0.80, P * 0.10, P * 0.09, P * 0.01
    rate, term_days = 0.20, 1095
    interest_owed = P * rate * (term_days / 365.0)
    total_owed = P + interest_owed
    print(f"  deposit                    {P:>10.2f}")
    print(f"  -> SafeVault (80%)         {sv:>10.2f}   <- the ONLY earning asset")
    print(f"  -> token-buy (10%)         {tb:>10.2f}")
    print(f"  -> treasury  (9%)          {tr:>10.2f}")
    print(f"  -> liquidity (1%)          {lq:>10.2f}")
    print(f"  interest owed @20%/3yr     {interest_owed:>10.2f}")
    print(f"  TOTAL OWED at maturity     {total_owed:>10.2f}")
    yrs = term_days / 365.0
    req = (total_owed / sv) ** (1 / yrs) - 1
    print(f"  yield required on the 80%  {req*100:>9.2f}%  CAGR (just to break even)")

    cap = results.get("COVERAGE_TARGET_BPS")
    if cap:
        target = P * (cap / 10000.0)
        print(f"\n  protocol's OWN coverage target ({cap} bps = {cap/100:.0f}% of principal):")
        print(f"    holds                      {target:>10.2f}")
        print(f"    vs interest obligation     {interest_owed:>10.2f}")
        print(f"    coverage ratio             {target/interest_owed*100:>9.1f}%  of the interest owed")
        print(f"    months of interest covered {target/(interest_owed/yrs*12):>9.1f}  of 36")

    tot = results.get("totalActivePrincipal")
    res = results.get("interestReserve")
    if tot is not None and res is not None and tot > 0:
        print(f"\n  LIVE: activePrincipal={tot/1e6:,.2f} USDC  interestReserve={res/1e6:,.2f} USDC")
        print(f"  LIVE: reserve covers {res/tot*100:.2f}% of active principal")
        oblig = tot * (1 + 0.20 * 3) - tot      # interest still owed on live principal
        print(f"  LIVE: interest obligation on active principal = {oblig/1e6:,.2f} USDC")
        print(f"  LIVE: coverage of that obligation            = {res/oblig*100:.2f}%")

    json.dump(results, open(os.path.join(TGT, "pass5_econ.json"), "w"), indent=2)
    print("\nsaved -> pass5_econ.json")


if __name__ == "__main__":
    main()
