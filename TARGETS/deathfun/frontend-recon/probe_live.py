import json, urllib.request
from Crypto.Hash import keccak

RPC = "https://api.mainnet.abs.xyz/"
def k(s):
    h = keccak.new(digest_bits=256); h.update(s.encode()); return h.digest()
def sel(s): return "0x" + k(s).hex()[:8]
def rpc(method, params):
    body = json.dumps({"jsonrpc":"2.0","method":method,"params":params,"id":1}).encode()
    req = urllib.request.Request(RPC, data=body,
          headers={"Content-Type":"application/json","User-Agent":"Mozilla/5.0"})
    return json.load(urllib.request.urlopen(req, timeout=30))

PROXY = "0x27EDd16eE56958fddCBA08947f12C43DDeC2B20C"
OLD_IMPL = "0x2c133230CFca00b9bf78c46DAe03A97019D96551"

IMPLEMENTATION_SLOT = "0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc"
res = rpc("eth_getStorageAt", [PROXY, IMPLEMENTATION_SLOT, "latest"])
impl = "0x" + res["result"][-40:]
print("proxy impl slot    :", impl)
print("old impl we audited:", OLD_IMPL.lower())
print("SAME as audited?   :", impl.lower() == OLD_IMPL.lower())

def codesize(a):
    return (len(rpc("eth_getCode", [a, "latest"])["result"]) - 2) // 2
print("code size proxy    :", codesize(PROXY))
print("code size new impl :", codesize(impl))
print("code size old impl :", codesize(OLD_IMPL))

def call(to, sig, args=""):
    try:
        r = rpc("eth_call", [{"to": to, "data": sel(sig) + args}, "latest"])
        return r.get("result", str(r.get("error"))[:100])
    except Exception as e:
        return f"ERR {e}"

print("\n=== live selector probe on PROXY ===")
probes = [
    ("messagePrefix()", ""),
    ("createGamePrefix()", ""),
    ("cashOutPrefix()", ""),
    ("claimRakebackPrefix()", ""),
    ("claimReferralPrefix()", ""),
    ("markGameAsLostPrefix()", ""),
    ("serverSignerAddress()", ""),
    ("rakebackNonces(address)", "0"*64),
    ("referralNonces(address)", "0"*64),
    ("owner()", ""),
    ("gameCounter()", ""),
    ("increaseBet(uint256,uint256,uint256,bytes)", ""),
]
for sig, args in probes:
    out = str(call(PROXY, sig, args))
    nodata = out == "0x"
    print(f"  {sig:44} {sel(sig)}  {'NO-DATA / not implemented' if nodata else out[:70]}")
