#!/usr/bin/env python3
"""
GILDer pass 7 - FULL solvency accounting.

Reads every USDC balance the protocol controls + the SafeVault's claim ledger,
then compares against what the protocol has actually PROMISED.

Obligation per the code's own constants (BondContract):
  principal is returned in full, PLUS simple interest
  interest = principal * SIMPLE_ANNUAL_RATE_BPS/10000 * (FIXED_TERM/365d)
           = principal * 0.20 * 3
  -> total owed = 1.60 x principal

Assets = USDC held by every module + USDC out on loan (still an asset).
"""
import json, os, urllib.request

TGT = "/root/.hermes/workspace/SAVAGEAUD/TARGETS/gilder"
USDC = "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913"

ADD = {
    "bondContract":   "0x5d25cfc927f95cb519c0fef438afaa64cb374e10",
    "safeVault":      "0x9b937b72172c0706b51984a09992bb8007771e67",
    "treasuryProxy":  "0x9e2ce9510a89deac71898fd0a86d84214c20607b",
    "tokenBuyRouter": "0xd144cdceb6a49bc9be906964abeb6de5d39952d0",
    "depositNft":     "0x809c4ee02279a38c9c32e63d4e1d9f0f8cc7da02",
    "liquidityRecip": "0x85bb2a352be250d9e0ed3d499e46984ae831414b",
    "lendingProxy":   "0x1d5388448eec2462329671419853adfc3faf0a76",
    "liquidityMgr":   "0xe703430cf3e0309388fe0d2be509f1af0ac62ffe",
    "gilderToken":    "0xa6c3b8dcb7c31132dcef64ef099f68b731db1e73",
    "multisig":       "0xb358e81b0f92698215bbe821b8c25986ad523a1b",
};

RPCS = ["https://mainnet.base.org", "https://base-rpc.publicnode.com",
        "https://1rpc.io/base", "https://base.drpc.org"]
UA = ("Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/125.0 Safari/537.36")


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


def sel(sig):
    from Crypto.Hash import keccak
    k = keccak.new(digest_bits=256); k.update(sig.encode())
    return k.hexdigest()[:8]


def call(to, sig, args=()):
    data = "0x" + sel(sig) + "".join(a.rjust(64, "0") for a in args)
    out = rpc("eth_call", [{"to": to, "data": data}, "latest"])
    if not isinstance(out, str) or len(out) < 3:
        return None
    try:
        return int(out, 16)
    except Exception:
        return None


def usd(x):
    return f"{x/1e6:,.6f}" if x is not None else "NO DATA"


def main():
    print("== USDC balances held by each module ==")
    bal = {}
    for name, addr in ADD.items():
        v = call(USDC, "balanceOf(address)", [addr[2:].rjust(64, "0")])
        bal[name] = v
        print(f"  {name:<16} {addr}  {usd(v):>16}")

    print("\n== SafeVault claim ledger ==")
    svp = ADD["safeVault"]
    acct = call(svp, "accountedPrincipal()")
    loaned = call(svp, "totalLoaned()")
    buf = call(svp, "protocolBuffer()")
    print(f"  accountedPrincipal  {usd(acct):>16}   <- sum of depositor claims in the vault")
    print(f"  totalLoaned         {usd(loaned):>16}")
    print(f"  protocolBuffer      {usd(buf):>16}")

    print("\n== Treasury ledger ==")
    tap = call(ADD["treasuryProxy"], "totalActivePrincipal()")
    ires = call(ADD["treasuryProxy"], "interestReserve()")
    ores = call(ADD["treasuryProxy"], "operationalReserve()")
    bres = call(ADD["treasuryProxy"], "buybackReserve()")
    tall = call(ADD["treasuryProxy"], "totalAllocated()")
    for n, v in [("totalActivePrincipal", tap), ("interestReserve", ires),
                 ("operationalReserve", ores), ("buybackReserve", bres),
                 ("totalAllocated", tall)]:
        print(f"  {n:<22} {usd(v):>16}")

    print("\n== SYSTEM SOLVENCY ==")
    if tap:
        P = tap / 1e6
        owed_principal = P
        owed_interest = P * 0.20 * 3
        owed_total = owed_principal + owed_interest
        print(f"  deposits outstanding (principal)   {owed_principal:>16,.2f}")
        print(f"  interest promised 20%/yr x 3yr     {owed_interest:>16,.2f}")
        print(f"  TOTAL OWED TO DEPOSITORS           {owed_total:>16,.2f}")

        # assets: every USDC the protocol controls
        sv_bal = (bal.get("safeVault") or 0) / 1e6
        tr_bal = (bal.get("treasuryProxy") or 0) / 1e6
        bd_bal = (bal.get("bondContract") or 0) / 1e6
        tb_bal = (bal.get("tokenBuyRouter") or 0) / 1e6
        ln_bal = (bal.get("lendingProxy") or 0) / 1e6
        lm_bal = (bal.get("liquidityMgr") or 0) / 1e6
        total_usdc = sv_bal + tr_bal + bd_bal + tb_bal + ln_bal + lm_bal
        print(f"\n  USDC in SafeVault                   {sv_bal:>16,.2f}")
        print(f"  USDC in Treasury                    {tr_bal:>16,.2f}")
        print(f"  USDC in BondContract                {bd_bal:>16,.2f}")
        print(f"  USDC in TokenBuyRouter              {tb_bal:>16,.2f}")
        print(f"  USDC in Lending                     {ln_bal:>16,.2f}")
        print(f"  USDC in LiquidityManager            {lm_bal:>16,.2f}")
        print(f"  TOTAL USDC CONTROLLED               {total_usdc:>16,.2f}")

        print(f"\n  coverage of PRINCIPAL alone         {total_usdc/owed_principal*100:>15,.2f}%")
        print(f"  coverage of PRINCIPAL + INTEREST    {total_usdc/owed_total*100:>15,.2f}%")
        gap = owed_total - total_usdc
        print(f"  SHORTFALL vs full obligation        {gap:>16,.2f}")
        if ires:
            print(f"\n  interestReserve vs interest owed    {ires/1e6/owed_interest*100:>15,.2f}%")
            print(f"  months of accrual the reserve covers{ires/1e6/(P*0.20/12):>15,.1f}  (of 36)")
        yrs = 3.0
        if sv_bal > 0:
            need = (owed_total / sv_bal) ** (1 / yrs) - 1
            print(f"  yield needed on SafeVault to break even {need*100:>11,.2f}% CAGR")

    json.dump({"balances": bal, "accountedPrincipal": acct, "totalLoaned": loaned,
               "totalActivePrincipal": tap, "interestReserve": ires},
              open(os.path.join(TGT, "pass7_solvency.json"), "w"), indent=2)
    print("\nsaved -> pass7_solvency.json")


if __name__ == "__main__":
    main()
