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
def call(to, sig):
    try:
        r = rpc("eth_call", [{"to": to, "data": sel(sig)}, "latest"])
        return r.get("result", str(r.get("error"))[:60])
    except Exception as e:
        return f"ERR {e}"

CANDS = {
 "0xc372B35582933277d5f4431F1a322Abc8DeA0612": "frontend cfg (unknown)",
 "0x34ca1501FAE231cC2ebc995CE013Dbe882d7d081": "chunk 0i5enl",
 "0x74b9ae28EC45E3FA11533c7954752597C3De3e7A": "chunk 0i5enl",
 "0x9B947df68D35281C972511B3E7BC875926f26C1A": "chunk 0i5enl",
 "0xd5E3efDA6bB5aB545cc2358796E96D9033496Dda": "chunk 0i5enl",
 "0xfD20b9d7A406e2C4f5D6Df71ABE3Ee48B2EccC9F": "chunk 0i5enl",
 "0x303a465b659cbb0ab36ee643ea362c509eeb5213": "chunk 0i5enl",
 "0xc10dcfe266c1f71ef476efbd3223555750dc271e": "chunk 0i5enl",
 "0x35A54c8C757806eB6820629bc82d90E056394C92": "chunk 0i5enl",
 "0x56315b90c40730925ec5485cf004d835058518A0": "chunk 2dv16j (new abi)",
 "0x3154Cf16ccdb4C6d922629664174b904d80F2C35": "chunk 2dv16j (new abi)",
 "0x43edB88C4B80fDD2AdFF2412A7BebF9dF42cB40e": "chunk 2dv16j (new abi)",
 "0x84457ca9D0163FbC4bbfe4Dfbb20ba46e48DF254": "chunk 2dv16j (new abi)",
 "0xAa4De41dba0Ca5dCBb288b7cC6b708F3aaC759E7": "chunk 2dv16j (new abi)",
 "0xd6E6dBf4F7EA0ac412fD8b65ED297e64BB7a06E1": "chunk 2dv16j (new abi)",
 "0xfd0Bf71F60660E2f608ed56e1659C450eB113120": "chunk 2dv16j (new abi)",
 "0x49048044D57e1C92A77f79988d21Fa8fAF74E97e": "chunk 2dv16j (new abi)",
}

print(f"{'address':44} {'size':>7}  incBet claimRake claimRef serverSigner  label")
for a, label in CANDS.items():
    cs = codesize(a)
    if cs == 0:
        print(f"{a:44} {cs:>7}  (no code / EOA)                                  {label}")
        continue
    ib = str(call(a, "increaseBet(uint256,uint256,uint256,bytes)"))
    cr = str(call(a, "claimRakeback(uint256,uint256,bytes)"))
    cf = str(call(a, "claimReferral(uint256,uint256,bytes)"))
    ss = str(call(a, "serverSignerAddress()"))
    def mark(x):
        return "yes" if (x.startswith("0x") and x != "0x") else "no"
    print(f"{a:44} {cs:>7}  {mark(ib):7} {mark(cr):9} {mark(cf):9} {mark(ss):11}  {label}")

# nonce of the placeholder address
print()
ph = "0xc372B35582933277d5f4431F1a322Abc8DeA0612"
txc = rpc("eth_getTransactionCount", [ph, "latest"])
bal = rpc("eth_getBalance", [ph, "latest"])
print("placeholder nonce:", int(txc["result"], 16), " balance wei:", int(bal["result"], 16))
