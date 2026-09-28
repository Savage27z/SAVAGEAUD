#!/usr/bin/env python3
"""TayDex pass16: (a) read the immutable tail of the runtime, which is where OZ EIP712 stores
    _CACHED_DOMAIN_SEPARATOR / _HASHED_NAME / _HASHED_VERSION / _TYPE_HASH; compare against my
    computed values to find why the domainSeparator missed and to confirm the digest recipe.
(b) classify every PUSH32 constant: event topics (from the ABI) vs known constants vs
    unexplained -> the unexplained 32-byte constants are TYPEHASH candidates.
Read-only against my fork.
"""
import json, urllib.request, os

R = "http://127.0.0.1:8546"
C = "0x3ade22fa1ef5ac75437a3734d91ba588e54875dd"
TGT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "taydex")
from Crypto.Hash import keccak as _k
def keccak(b): h = _k.new(digest_bits=256); h.update(b); return h.digest()
def kh(s): return keccak(s.encode())

def rpc(m, p):
    req = urllib.request.Request(R, data=json.dumps({"jsonrpc": "2.0", "id": 1,
                                                     "method": m, "params": p}).encode(),
                                 headers={"Content-Type": "application/json"})
    return json.loads(urllib.request.urlopen(req, timeout=40).read())

code = rpc("eth_getCode", [C, "latest"])["result"][2:]
by = bytes.fromhex(code)

# ---------- (a) immutable tail ----------
print("=" * 96)
print("(a) RUNTIME TAIL (last 352 bytes) -- solc appends immutables here as raw 32-byte words")
print("=" * 96)
tail = by[-352:]
for off in range(0, len(tail), 32):
    w = tail[off:off + 32]
    printable = "".join(chr(c) if 32 <= c < 127 else "." for c in w)
    print(f"  -{len(tail)-off:>4}  {w.hex()}   {printable}")

NAME, VERSION, CHAINID = "TaydexMarket", "1", 8453
DOMAIN_TH = kh("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)")
hn, hv = kh(NAME), kh(VERSION)
addr32 = bytes.fromhex(C.lower().replace("0x", "").rjust(64, "0"))
ds = keccak(b"\x19\x01" + DOMAIN_TH + hn + hv + CHAINID.to_bytes(32, "big") + addr32)
# also the non-\x19\x01 variant
ds_plain = keccak(DOMAIN_TH + hn + hv + CHAINID.to_bytes(32, "big") + addr32)
print("\n  my computed values:")
for label, v in [("domainSeparator (\\x19\\x01 form)", ds),
                 ("domainSeparator (plain concat)", ds_plain),
                 ("_HASHED_NAME", hn), ("_HASHED_VERSION", hv),
                 ("_TYPE_HASH (domain)", DOMAIN_TH),
                 ("chainId word", CHAINID.to_bytes(32, "big"))]:
    print(f"    {label:<32} {v.hex()}")
    if v.hex() in code:
        print(f"      -> FOUND in runtime code")
    else:
        print(f"      -> not found in code")

# ---------- (b) classify constants ----------
print("\n" + "=" * 96)
print("(b) CLASSIFY EVERY 32-BYTE IMMEDIATE: event topics vs unexplained")
print("=" * 96)
push32 = json.load(open(os.path.join(TGT, "pass15_typehash.json")))["push32"]

abi = json.load(open(os.path.join(TGT, "abi_core.json")))
topics = {}
for e in abi:
    if e.get("type") == "event":
        sig = f"{e['name']}({','.join(i.get('type','?') for i in e.get('inputs',[]))})"
        # canonical: tuples not present in these events
        topics[kh(sig).hex()] = f"event {sig}"
KNOWN32 = {
 DOMAIN_TH.hex(): "EIP712Domain typehash",
 hn.hex(): "keccak('TaydexMarket')",
 hv.hex(): "keccak('1')",
 ds.hex(): "domainSeparator (mine)",
 ds_plain.hex(): "domainSeparator plain (mine)",
 keccak(b"").hex(): "keccak('') ",
 kh("OwnershipTransferred(address,address)").hex(): "OwnershipTransferred topic",
 "7fffffffffffffffffffffffffffffff5d576e7357a4501ddfe92f46681b20a0":
     "secp256k1 n/2 (OZ ECDSA malleability bound)",
 "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff": "max uint256",
}
cands = []
print(f"{'constant':<66} classification")
print("-" * 96)
for v in push32:
    if v in KNOWN32:
        tag = KNOWN32[v]; kind = "known"
    elif v in topics:
        tag = topics[v]; kind = "topic"
    else:
        # error strings / small numbers / addresses
        raw = bytes.fromhex(v)
        printable = "".join(chr(c) if 32 <= c < 127 else "" for c in raw).strip("\x00")
        if len(printable) >= 6:
            tag = f"string constant {printable!r} (extcode err msg)"; kind = "string"
        elif v.startswith("0" * 24):
            tag = f"left-padded address 0x{v[-40:]}"; kind = "address"
        elif v.lstrip("0") == "":
            tag = "zero"; kind = "zero"
        else:
            tag = "*** UNEXPLAINED 32-byte constant -> TYPEHASH CANDIDATE ***"
            kind = "candidate"; cands.append(v)
    print(f"  0x{v[:62]:<64} {tag}")

print(f"\n  TYPEHASH CANDIDATES ({len(cands)}):")
for v in cands:
    print(f"    0x{v}")
json.dump(cands, open(os.path.join(TGT, "pass16_typehash_candidates.json"), "w"), indent=1)
print("\n[saved] pass16_typehash_candidates.json")
