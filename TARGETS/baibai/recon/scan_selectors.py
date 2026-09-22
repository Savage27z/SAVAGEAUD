#!/usr/bin/env python3
"""Selector enumeration on UNVERIFIED runtime bytecode.
Extracts the dispatcher's PUSH4 selectors, then diffs them against the ABI the
project publishes in its own docs. Anything extra is an undocumented entry point."""
import json, urllib.request, re, sys

BASE_RPC = "https://mainnet.base.org"
UA = {"User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) Chrome/128.0 Safari/537.36"}

def rpc(m, p):
    body = json.dumps({"jsonrpc":"2.0","id":1,"method":m,"params":p}).encode()
    req = urllib.request.Request(BASE_RPC, data=body, headers={**UA,"Content-Type":"application/json"})
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.loads(r.read()).get("result")

try:
    from Crypto.Hash import keccak
    def sel(sig):
        k = keccak.new(digest_bits=256); k.update(sig.encode()); return k.hexdigest()[:8]
except Exception:
    def sel(sig):
        return "??"

DOCUMENTED = [
    # from docs/takers/quoting-and-swapping.md
    "quoteFor(address,address,uint256,address)",
    "swapExactAmountIn(address,address,uint256,uint256,address)",
    "curveBook()", "custodian()", "quoteToken()", "entrypoint()",
    "quote(address,address,uint256)", "pair(address)", "knot(address,uint8,uint256)",
    "ttl()", "validUntil(address)", "cUnit()",
    "decimals()", "name()", "symbol()", "totalSupply()", "balanceOf(address)",
    "allowance(address,address)", "approve(address,uint256)", "transfer(address,uint256)",
    "transferFrom(address,address,uint256)",
]
PRIVILEGED_WATCH = {
    "upgradeTo(address)":"UUPS upgrade", "upgradeToAndCall(address,bytes)":"UUPS upgrade+init",
    "owner()":"ownership", "transferOwnership(address)":"ownership transfer",
    "renounceOwnership()":"ownership renounce", "pause()":"pausable", "unpause()":"pausable",
    "paused()":"pausable", "setFee(uint256)":"fee control", "setFees(uint256,uint256)":"fee control",
    "withdraw(address,uint256)":"fund egress", "withdrawToken(address,uint256)":"fund egress",
    "withdrawAll()":"fund egress", "sweep(address)":"fund egress", "rescue(address,uint256)":"fund egress",
    "setCurve(address)":"curve control", "updateCurve(address,bytes)":"curve control",
    "setEntrypoint(address)":"wiring", "setCustodian(address)":"wiring", "setCurveBook(address)":"wiring",
    "grantRole(bytes32,address)":"access control", "revokeRole(bytes32,address)":"access control",
    "setAdmin(address)":"access control", "initialize()":"initializer", "initialize(address)":"initializer",
    "setProxyAdmin(address)":"proxy admin", "multicall(bytes[])":"batched calls",
    "execute(address,uint256,bytes)":"arbitrary call", "setTakerWhitelist(address,bool)":"allowlist",
}
WATCH_SEL = {sel(s): s for s in PRIVILEGED_WATCH if sel(s) != "??"}

def dispatch_selectors(code_hex):
    """PUSH4 (0x63) immediates in the first N bytes = dispatcher constants."""
    b = bytes.fromhex(code_hex[2:])
    found = {}
    for i in range(min(len(b) - 4, 4000)):
        if b[i] == 0x63:
            s = b[i+1:i+5].hex()
            if s != "00000000":
                found[s] = found.get(s, 0) + 1
    return found

IMPLS = {
    "BaibaiEntrypoint.impl": "0x8fEF5FDEfCf738997B8833A28378fCB2F9DFD29A",
    "BaibaiCurveBook.impl":  "0xBfF02E9E504B88c84f41205f561E45c2FADdf203",
    "BaibaiCustodian.impl":  "0x997b2D1B539DFccC9D42f2d10Fe804F0Ac9b3076",
}

doc_sels = {sel(s): s for s in DOCUMENTED}
for label, addr in IMPLS.items():
    code = rpc("eth_getCode", [addr, "latest"]) or "0x"
    sels = dispatch_selectors(code)
    print(f"═══ {label}  {addr}")
    print(f"    runtime = {(len(code)-2)//2:,} bytes · {len(sels)} distinct PUSH4 constants")
    hits = [(s, WATCH_SEL[s], n) for s, n in sels.items() if s in WATCH_SEL]
    documented = [(s, doc_sels[s]) for s in sels if s in doc_sels]
    print(f"    documented selectors present: {len(documented)}")
    for s, sig in sorted(documented): print(f"       ✓ {s}  {sig}")
    print(f"    ⚠ PRIVILEGED-PATTERN matches:")
    if hits:
        for s, sig, n in sorted(hits): print(f"       ! {s}  {sig}   (×{n})")
    else:
        print("       (none matched the watchlist)")
    print()
