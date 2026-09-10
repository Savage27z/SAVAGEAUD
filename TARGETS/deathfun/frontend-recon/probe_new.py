import json, urllib.request, re
from Crypto.Hash import keccak

RPC = "https://api.mainnet.abs.xyz/"

def k(s):
    h = keccak.new(digest_bits=256); h.update(s.encode()); return h.digest()
def sel(s): return "0x" + k(s).hex()[:8]
def rpc(method, params):
    body = json.dumps({"jsonrpc": "2.0", "method": method, "params": params, "id": 1}).encode()
    req = urllib.request.Request(RPC, data=body,
            headers={"Content-Type": "application/json", "User-Agent": "Mozilla/5.0"})
    return json.load(urllib.request.urlopen(req, timeout=30))

def codesize(a):
    return (len(rpc("eth_getCode", [a, "latest"])["result"]) - 2) // 2

def call(to, sig, args=""):
    try:
        r = rpc("eth_call", [{"to": to, "data": sel(sig) + args}, "latest"])
        return r.get("result", str(r.get("error"))[:90])
    except Exception as e:
        return f"ERR {e}"

CAND = "0xc372B35582933277d5f4431F1a322Abc8DeA0612"
print("=== candidate 0xc372B355... ===")
print("codesize:", codesize(CAND))
res = rpc("eth_getStorageAt", [CAND, "0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc", "latest"])
impl = "0x" + res["result"][-40:]
print("EIP-1967 impl slot:", impl, "codesize:", codesize(impl))

print("\n--- selector probe ---")
for sig, args in [
    ("messagePrefix()", ""), ("createGamePrefix()", ""), ("cashOutPrefix()", ""),
    ("claimRakebackPrefix()", ""), ("claimReferralPrefix()", ""), ("markGameAsLostPrefix()", ""),
    ("serverSignerAddress()", ""), ("owner()", ""), ("gameCounter()", ""),
    ("rakebackNonces(address)", "0"*64), ("referralNonces(address)", "0"*64),
]:
    out = str(call(CAND, sig, args))
    print(f"  {sig:32} {sel(sig)}  {'NO-DATA' if out == '0x' else out[:66]}")

print("\n--- prefixes (decode bytes32->string) ---")
for sig in ["messagePrefix()", "createGamePrefix()", "cashOutPrefix()", "claimRakebackPrefix()",
            "claimReferralPrefix()", "markGameAsLostPrefix()"]:
    out = str(call(CAND, sig))
    if out.startswith("0x") and len(out) > 66:
        raw = out[2:]
        # could be string (offset+len+data) or bytes32
        try:
            off = int(raw[:64], 16)
            if off == 32:
                ln = int(raw[64:128], 16)
                txt = bytes.fromhex(raw[128:128+ln*2]).decode("utf-8", "replace")
                print(f"  {sig:26} -> string({ln}) {txt!r}")
            else:
                bs = bytes.fromhex(raw[:64]).rstrip(b"\x00")
                print(f"  {sig:26} -> bytes32-ish {bs!r}")
        except Exception as e:
            print(f"  {sig:26} -> parse err {e} raw={raw[:80]}")
    else:
        print(f"  {sig:26} -> {out[:40]}")
