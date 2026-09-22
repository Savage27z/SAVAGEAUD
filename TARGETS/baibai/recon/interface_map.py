#!/usr/bin/env python3
"""Resolve EVERY dispatcher selector on the unverified impls to a real signature
via 4byte.directory, then diff against the ABI the project publishes in its own docs.
Output: complete external interface map + undocumented/privileged deltas."""
import json, urllib.request, re, time, os

BASE_RPC = "https://mainnet.base.org"
UA = {"User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) Chrome/128.0 Safari/537.36"}
OUT = os.path.dirname(os.path.abspath(__file__))

def rpc(m, p):
    body = json.dumps({"jsonrpc":"2.0","id":1,"method":m,"params":p}).encode()
    req = urllib.request.Request(BASE_RPC, data=body, headers={**UA,"Content-Type":"application/json"})
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.loads(r.read()).get("result")

def sel(sig):
    from Crypto.Hash import keccak
    k = keccak.new(digest_bits=256); k.update(sig.encode()); return k.hexdigest()[:8]

DOCUMENTED = [
    "quoteFor(address,address,uint256,address)",
    "swapExactAmountIn(address,address,uint256,uint256,address)",
    "curveBook()", "custodian()", "quoteToken()", "entrypoint()",
    "quote(address,address,uint256)", "pair(address)", "knot(address,uint8,uint256)",
    "ttl()", "validUntil(address)", "cUnit()",
    "balanceOf(address)", "decimals()", "name()", "symbol()", "totalSupply()",
]
DOC = {sel(s): s for s in DOCUMENTED}

def push4s(code_hex):
    b = bytes.fromhex(code_hex[2:]); out = {}
    for i in range(min(len(b)-4, 6000)):
        if b[i] == 0x63:
            s = b[i+1:i+5].hex()
            if s not in ("00000000","ffffffff"): out[s] = out.get(s,0)+1
    return out

def lookup(h):
    try:
        u = f"https://www.4byte.directory/api/v1/signatures/?hex_signature=0x{h}"
        with urllib.request.urlopen(urllib.request.Request(u, headers=UA), timeout=20) as r:
            d = json.loads(r.read())
        res = d.get("results") or []
        sigs = sorted({x["text_signature"] for x in res})
        return sigs[:3] if sigs else None
    except Exception as e:
        return [f"__err__{type(e).__name__}"]

IMPLS = {
    "BaibaiEntrypoint.impl": "0x8fEF5FDEfCf738997B8833A28378fCB2F9DFD29A",
    "BaibaiCurveBook.impl":  "0xBfF02E9E504B88c84f41205f561E45c2FADdf203",
    "BaibaiCustodian.impl":  "0x997b2D1B539DFccC9D42f2d10Fe804F0Ac9b3076",
}
PRIV = re.compile(r"upgrade|owner|admin|pause|fee|withdraw|sweep|rescue|set[A-Z]|grant|revoke|"
                  r"initialize|kill|destroy|selfdestruct|delegate|execute|whitelist|freeze|"
                  r"migrate|pull|drain|skim|collect|transfer.*Ownership", re.I)

report = {}
for label, addr in IMPLS.items():
    code = rpc("eth_getCode", [addr, "latest"]) or "0x"
    sels = push4s(code)
    rows, undocumented = [], []
    for h, n in sorted(sels.items()):
        if h in DOC:
            continue
        sigs = lookup(h)
        time.sleep(0.25)
        rows.append((h, n, sigs))
        if sigs and any(PRIV.search(s) for s in sigs):
            undocumented.append((h, n, sigs))
    documented = [DOC[h] for h in sels if h in DOC]
    report[label] = {"address": addr, "runtime_bytes": (len(code)-2)//2,
                     "push4_total": len(sels), "documented": sorted(documented),
                     "undocumented": [{"sel":h,"uses":n,"sigs":s} for h,n,s in rows],
                     "undocumented_privileged": [{"sel":h,"uses":n,"sigs":s} for h,n,s in undocumented]}
    print(f"═══ {label}  ({report[label]['runtime_bytes']:,} bytes, {len(sels)} PUSH4)")
    print(f"    documented in project docs : {len(documented)}")
    print(f"    UNDOCUMENTED (resolved)    :")
    for h, n, sigs in rows:
        if sigs:
            flag = "  ⚠" if sigs and any(PRIV.search(s) for s in sigs) else "   "
            print(f"    {flag} 0x{h} ×{n:<3} {' | '.join(sigs)}")
    print()

json.dump(report, open(f"{OUT}/interface_map.json","w"), indent=1)
print(f"[saved] {OUT}/interface_map.json")
