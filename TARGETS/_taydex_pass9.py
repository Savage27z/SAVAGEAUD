#!/usr/bin/env python3
"""TayDex pass9: settle whether the app's bundled ABI is the LIVE contract's interface.
 (A) bundle: resolve the contract-address accessor the encoders call ((0,n.Eq)()) -- which
     address, which chain? Look for testnet branches.
 (B) chain: PROPER selector census of the deployed runtime via a linear EVM disassembler
     (PUSH4 constants), then diff BOTH ways against the app ABI.
 (C) proxy patterns: EIP-1967 impl/beacon, EIP-1822, EIP-1167 minimal proxy.
 (D) eip712Domain() -> the live signing domain.
Read-only: eth_getCode / eth_getStorageAt / eth_call. Nothing signed, nothing broadcast.
"""
import json, os, re, time, urllib.error, urllib.request

TGT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "taydex")
RAW = os.path.join(TGT, "raw")
CORE = "0x3ade22fa1ef5ac75437a3734d91ba588e54875dd"
RPCS = ["https://base-rpc.publicnode.com", "https://1rpc.io/base",
        "https://mainnet.base.org", "https://base.drpc.org"]
UA = ("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36")
from Crypto.Hash import keccak as _k
def keccak(b): h = _k.new(digest_bits=256); h.update(b); return h.digest()
def sig4(s): return keccak(s.encode()).hex()[:8]

def rpc(m, p, tries=3):
    last = None
    for _ in range(tries):
        for url in RPCS:
            try:
                body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": m,
                                   "params": p}).encode()
                req = urllib.request.Request(url, data=body,
                    headers={"Content-Type": "application/json", "User-Agent": UA})
                raw = urllib.request.urlopen(req, timeout=25).read()
            except urllib.error.HTTPError as e:
                raw = e.read()
            except Exception as e:
                last = str(e); continue
            try: r = json.loads(raw)
            except Exception: last = raw[:80]; continue
            if "result" in r: return r["result"]
            if "error" in r:  return {"__e__": r["error"]}
        time.sleep(1)
    return {"__e__": last}

src = {f: open(os.path.join(RAW, f), encoding="utf-8", errors="replace").read()
       for f in os.listdir(RAW) if f.endswith(".js")}

# ---------- (A) the address accessor ----------
print("=" * 100)
print("(A) WHICH ADDRESS DO THE ENCODERS TARGET?  resolve module n.Eq()")
print("=" * 100)
enc = src.get("69191-0d044baaec4da351.js", "")
# the encoder module does: var s=t(86931),n=t(59652);  -> n is the address provider
m = re.search(r'var s=t\((\d+)\),n=t\((\d+)\);', enc)
print("  encoder module imports:", m.groups() if m else "?")
provider_id = m.group(2) if m else None
# find that module's definition:  <id>:(e,t,n)=>{ n.d(t,{Eq:()=>X}); ... }
if provider_id:
    pm = re.search(rf'{provider_id}:\(e,t,n\)=>\{{(.{{0,1500}})', enc, re.S)
    if pm:
        print(f"\n  provider module {provider_id}:\n  {pm.group(1)[:1200]}")

print("\n  --- every chain-id / network switch near contract addresses ---")
for f, s in src.items():
    for kw in ["Eq:()=>", "8453", "84532", "11155111", "chainId"]:
        for mm in re.finditer(re.escape(kw), s):
            a = max(0, mm.start() - 90)
            seg = s[a:mm.end() + 150].replace("\n", " ")
            print(f"    [{f}] {kw:<12} ...{seg[:240]}...")
            break

# ---------- (B) deployed selector census ----------
print("\n" + "=" * 100)
print("(B) DEPLOYED SELECTOR CENSUS (linear EVM disassembler, PUSH4 constants)")
print("=" * 100)
code = rpc("eth_getCode", [CORE, "latest"])
if not isinstance(code, str):
    raise SystemExit(f"getCode failed: {code}")
code = code[2:] if code.startswith("0x") else code
by = bytes.fromhex(code)
print(f"  runtime bytes: {len(by):,}")

PUSH1 = 0x60
def disassemble_push4(buf):
    """Linear scan tracking instruction boundaries; returns PUSH4 immediates."""
    out, i, n = set(), 0, len(buf)
    while i < n:
        op = buf[i]
        if op == 0x63 and i + 4 < n:                      # PUSH4
            out.add(buf[i + 1:i + 5].hex())
        if PUSH1 <= op <= 0x7f:                            # PUSH1..PUSH32
            i += 1 + (op - PUSH1 + 1)
        elif op == 0x5f:                                   # PUSH0
            i += 1
        else:
            i += 1
    return out

push4 = disassemble_push4(by)
print(f"  distinct PUSH4 immediates: {len(push4)}")

abi = json.load(open(os.path.join(TGT, "abi_core.json")))
def sig_of(e):
    ins = []
    for i in e.get("inputs", []):
        t = i.get("type", "?")
        if t.startswith("tuple"):
            t = "(" + ",".join(c.get("type", "?") for c in i.get("components", [])) + ")" + t[5:]
        ins.append(t)
    return f"{e['name']}({','.join(ins)})"

abi_funcs = {sig_of(e): sig4(sig_of(e)) for e in abi if e.get("type") == "function"}
deployed = set(push4)
in_both = {s: sel for s, sel in abi_funcs.items() if sel in deployed}
app_only = {s: sel for s, sel in abi_funcs.items() if sel not in deployed}
print(f"\n  app ABI functions        : {len(abi_funcs)}")
print(f"  of those, IN bytecode    : {len(in_both)}")
print(f"  of those, ABSENT         : {len(app_only)}")
print("\n  --- ABSENT from the deployed contract ---")
for s, sel in sorted(app_only.items()):
    print(f"      0x{sel}  {s}")

# ---------- (C) proxy patterns ----------
print("\n" + "=" * 100)
print("(C) PROXY PATTERNS")
print("=" * 100)
SLOTS = {
    "EIP-1967 impl":     "0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc",
    "EIP-1967 beacon":   "0xa3f0ad74e5423aebfd80d3ef4346578335a9a72aeaee59ff6cb3582b35133d50",
    "EIP-1967 admin":    "0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103",
    "EIP-1822 proxiable": "0xc5f16f0fcc639fa48a6947836d9850f504798523bf8c9a3a87d5876cf622bcf7",
    "OZ v4 impl slot":   "0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbd",
}
for name, slot in SLOTS.items():
    v = rpc("eth_getStorageAt", [CORE, slot, "latest"])
    print(f"  {name:<20} = {v}")
# EIP-1167 minimal proxy prefix check
print(f"  first 20 bytes       = 0x{by[:20].hex()}  "
      f"(EIP-1167 clone if == 363d3d373d3d3d363d73...)")
print(f"  has fallback?        = {'yes (code after dispatcher)' if len(by) > 500 else 'no'}")

# ---------- (D) live EIP-712 domain ----------
print("\n" + "=" * 100)
print("(D) LIVE eip712Domain()  -> the real signing domain")
print("=" * 100)
r = rpc("eth_call", [{"from": "0x000000000000000000000000000000000000dEaD",
                      "to": CORE, "data": "0x" + sig4("eip712Domain()")}, "latest"])
print(f"  raw: {r}")
if isinstance(r, str) and len(r) > 2:
    b = r[2:]
    def word(i): return b[i * 64:(i + 1) * 64]
    print(f"  fields: {word(0)}")
    # dynamic decoding is fiddly; print each 32-byte word offset
    for i in range(0, min(len(b) // 64, 12)):
        print(f"    word{i:<2} = {word(i)}")

json.dump({"deployed_push4": len(push4), "app_only": app_only, "in_both": in_both},
          open(os.path.join(TGT, "pass9_selectors.json"), "w"), indent=1)
print("\n[saved] pass9_selectors.json")
