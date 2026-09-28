#!/usr/bin/env python3
"""TayDex pass 2 — map the three own contracts: proxy->impl, selector enumeration,
4byte resolution, and the UMA/oracle wiring. Verification checks carry a POSITIVE CONTROL
(a known-verified address) so a failure is recorded as UNCONFIRMED, never 'unverified'."""
import re, json, time, urllib.request, urllib.error

UA = {"User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) Chrome/128.0 Safari/537.36"}
RPCS = ["https://base.llamarpc.com","https://base-rpc.publicnode.com","https://1rpc.io/base",
        "https://base.drpc.org","https://mainnet.base.org"]
EIP1967 = "0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc"

def rpc(method, params, tries=8):
    for i in range(tries):
        body = json.dumps({"jsonrpc":"2.0","id":1,"method":method,"params":params}).encode()
        try:
            with urllib.request.urlopen(urllib.request.Request(
                    RPCS[i%len(RPCS)], data=body, headers={**UA,"Content-Type":"application/json"}),timeout=25) as r:
                j = json.loads(r.read())
            if "result" in j: return j["result"]
        except Exception:
            time.sleep(1.0*(i+1))
    return None

def sel(sig):
    from Crypto.Hash import keccak
    k = keccak.new(digest_bits=256); k.update(sig.encode()); return k.hexdigest()[:8]

def push4(code_hex):
    b = bytes.fromhex(code_hex[2:]); out={}
    for i in range(min(len(b)-4, 6000)):
        if b[i]==0x63:
            s=b[i+1:i+5].hex()
            if s not in ("00000000","ffffffff"): out[s]=out.get(s,0)+1
    return out

cache={}
def resolve4(h):
    if h in cache: return cache[h]
    try:
        u=f"https://www.4byte.directory/api/v1/signatures/?hex_signature=0x{h}"
        with urllib.request.urlopen(urllib.request.Request(u,headers=UA),timeout=20) as r:
            d=json.loads(r.read())
        sigs=sorted({x["text_signature"] for x in (d.get("results") or [])})[:2]
    except Exception:
        sigs=None
    cache[h]=sigs; time.sleep(0.25); return sigs

KNOWN_SEL = {sel(s): s for s in [
 "take(uint256,uint256)","buy(uint256,uint256)","sell(uint256,uint256)","mint(uint256,uint256)",
 "redeem(uint256[])","merge(uint256[])","splitPosition(address,bytes32,bytes32,uint256[])",
 "payoutDenominator(bytes32)","payoutNumerators(bytes32,uint256)","markets(bytes32)",
 "createMarket(string,string,uint256)","resolveMarket(bytes32)","claim(uint256)",
 "owner()","pendingOwner()","transferOwnership(address)","acceptOwnership()","renounceOwnership()",
 "upgradeToAndCall(address,bytes)","proxiableUUID()","UPGRADE_INTERFACE_VERSION()",
 "initialize(address)","initialize(address,address,uint256)","pause()","unpause()","paused()",
 "setFee(uint256)","setRake(uint256)","withdraw(address,uint256)","rescue(address,uint256)",
 "grantRole(bytes32,address)","getMarket(bytes32)","positionOf(address,bytes32)",
]}
PRIV = re.compile(r"upgrade|owner|admin|pause|fee|rake|withdraw|resc|set[A-Z]|grant|revoke|init|"
                  r"migrate|collect|skim|sweep|kill|destroy|delegate|execute|emergency", re.I)

CONTRACTS = {
 "TayDex A (largest own)": "0x3ade22fa1ef5ac75437a3734d91ba588e54875dd",
 "TayDex B (8469B twin 1)": "0x4be0ddfebca9a5a4a617dee4dece99e7c862dceb",
 "TayDex C (8469B twin 2)": "0x85e23b94e7f5e9cc1ff78bce78cfb15b81f0df00",
}
out={}
for label, a in CONTRACTS.items():
    code = rpc("eth_getCode", [a, "latest"]) or "0x"
    size = (len(code)-2)//2
    slot = rpc("eth_getStorageAt", [a, EIP1967, "latest"])
    impl = None
    if isinstance(slot,str) and len(slot)>=42:
        cand = "0x"+slot[-40:]
        if cand != "0x"+"0"*40:
            impl = cand
            ic = rpc("eth_getCode", [impl,"latest"]) or "0x"
            impl_size = (len(ic)-2)//2
        else: impl_size=None
    print(f"═══ {label}  {a}")
    print(f"    code={size:,} B   EIP-1967 impl slot → {impl or '(empty)'}"
          + (f"  impl_code={impl_size:,} B" if impl and impl_size is not None else ""))
    sels = push4(code)
    doc=[KNOWN_SEL[s] for s in sels if s in KNOWN_SEL]
    print(f"    {len(sels)} PUSH4 constants; {len(doc)} matched a known signature")
    for s in sorted(doc): print(f"       ✓ {s}")
    und=[]
    for h in sels:
        if h in KNOWN_SEL: continue
        sg = resolve4(h)
        if sg: und.append((h, sels[h], sg))
    priv=[(h,n,list(sg)) for h,n,sg in und if any(PRIV.search(x) for x in sg)]
    print(f"    undocumented but resolved: {len(und)}  (privileged-pattern: {len(priv)})")
    for h,n,sg in und[:14]:
        mark = "⚠" if any(PRIV.search(x) for x in sg) else " "
        print(f"      {mark} 0x{h} ×{n}  {' | '.join(sg)}")
    out[label]={"addr":a,"size":size,"impl":impl,"impl_size":locals().get('impl_size'),
                "matched":doc,"undocumented":[{"sel":h,"uses":n,"sigs":sg} for h,n,sg in und]}
    print()
json.dump(out, open("/root/.hermes/workspace/SAVAGEAUD/TARGETS/taydex/pass2_contracts.json","w"), indent=1)

print("═══ VERIFICATION with POSITIVE CONTROL ═══")
def bs(a):
    try:
        with urllib.request.urlopen(urllib.request.Request(
            f"https://base.blockscout.com/api/v2/smart-contracts/{a}", headers=UA), timeout=25) as r:
            return json.loads(r.read())
    except Exception as e:
        return {"__err__": type(e).__name__}
ctrl = bs("0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913")   # USDC on Base = certainly verified
print(f"    CONTROL USDC(Base): is_verified={ctrl.get('is_verified')} name={ctrl.get('name')!r}"
      f"  → {'check WORKS' if ctrl.get('is_verified') else 'check BROKEN → all results UNCONFIRMED'}")
for label,a in CONTRACTS.items():
    d=bs(a); print(f"    {label:24} verified={d.get('is_verified')} name={d.get('name')!r} proxy={d.get('proxy_type')}")
    time.sleep(0.5)
