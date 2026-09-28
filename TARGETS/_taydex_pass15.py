#!/usr/bin/env python3
"""TayDex pass15: recover the CREATE-MARKET EIP-712 struct from the deployed bytecode.

The frontend never builds this signature (the server does), so the struct is not in the bundle.
Recover it from the chain:
  ctrl-1  keccak("TaydexMarket"), keccak("1")      -> must be present (OZ immutables)
  ctrl-2  computed domainSeparator                  -> must be present
  then    brute-force the struct TYPE NAME over a wordlist, using the field types/names the
          ABI already pins down: (uint64 endDate, uint128[] fundingPerOption,
          uint16 creatorFeeShareBps, uint256 nonce, uint256 deadline)
Also dump every PUSH32 constant, so a hit can be cross-checked and non-hits enumerated.
Read-only against my fork.
"""
import json, re, urllib.request

R = "http://127.0.0.1:8546"
C = "0x3ade22fa1ef5ac75437a3734d91ba588e54875dd"
NAME = "TaydexMarket"
VERSION = "1"
CHAINID = 8453

from Crypto.Hash import keccak as _k
def keccak(b): h = _k.new(digest_bits=256); h.update(b); return h.digest()
def kh(s): return keccak(s.encode())

def rpc(m, p):
    req = urllib.request.Request(R, data=json.dumps({"jsonrpc": "2.0", "id": 1,
                                                     "method": m, "params": p}).encode(),
                                 headers={"Content-Type": "application/json"})
    return json.loads(urllib.request.urlopen(req, timeout=40).read())

code = rpc("eth_getCode", [C, "latest"])["result"][2:]
print(f"runtime {len(code)//2:,} bytes\n")

# ---------- controls ----------
print("=" * 92)
print("CONTROLS")
print("=" * 92)
DOMAIN_TH = kh("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)")
hashed_name, hashed_version = kh(NAME), kh(VERSION)
domain_sep = keccak(b"\x19\x01" + DOMAIN_TH + hashed_name + hashed_version
                    + CHAINID.to_bytes(32, "big")
                    + bytes.fromhex(C.lower().replace("0x", "").rjust(64, "0")))
for label, v in [("EIP712Domain typehash", DOMAIN_TH),
                 ('keccak("TaydexMarket")', hashed_name),
                 ('keccak("1")', hashed_version),
                 ("computed domainSeparator", domain_sep)]:
    print(f"  {'OK ' if v.hex() in code else 'MISS'}  {label:<26} {v.hex()[:24]}…")
print(f"\n  -> domainSeparator = 0x{domain_sep.hex()}")
print("     (if OK above, the domain computation is validated and the digest assembly "
      "below is trustworthy)")

# ---------- brute-force the struct type name ----------
FIELD_TAIL = "(uint64 endDate,uint128[] fundingPerOption,uint16 creatorFeeShareBps,uint256 nonce,uint256 deadline)"
NAMES = [
 "CreateMarket", "Market", "MarketParams", "CreateMarketParams", "CreateMarketRequest",
 "CreateMarketData", "CreateParams", "NewMarket", "NewMarketParams", "MarketCreation",
 "CreateMarketArgs", "MarketArgs", "CreateMarketInput", "CreateMarketStruct",
 "TaydexMarket", "TayDexMarket", "TaydexCreateMarket", "TayDexCreateMarket",
 "TaydexMarketCreate", "MarketCreate", "CreateMarketCall", "CreateMarketPayload",
 "OpenMarket", "LaunchMarket", "Create", "MarketCreateParams", "CreateMarketCalldata",
 "CreateMarketMessage", "MarketMessage", "CreateMarketInfo", "MarketInfo",
 "CreateMarketV1", "MarketV1", "CreateMarketAction", "MarketAction",
]
# also try the struct WITHOUT the leading uint64 / with uint256 variants
TAILS = {
 "canonical (ABI types)": FIELD_TAIL,
 "uint256 endDate":       "(uint256 endDate,uint128[] fundingPerOption,uint16 creatorFeeShareBps,uint256 nonce,uint256 deadline)",
 "no-opts array":         "(uint64 endDate,uint128[] fundingPerOption,uint16 creatorFeeShareBps,uint256 nonce,uint256 deadline)",
}
print("\n" + "=" * 92)
print(f"TYPE-NAME BRUTE FORCE  ({len(NAMES)} names x {len(TAILS)} tails = "
      f"{len(NAMES)*len(TAILS)} candidates)")
print("=" * 92)
hits = []
for tail_label, tail in TAILS.items():
    for n in NAMES:
        s = n + tail
        h = kh(s).hex()
        if h in code:
            hits.append((s, h))
            print(f"  *** HIT ***  {h[:24]}…  type = {s}")
if not hits:
    print("  no hit - the struct name is outside this wordlist")

# ---------- dump PUSH32 constants ----------
print("\n" + "=" * 92)
print("PUSH32 CONSTANTS IN THE RUNTIME  (candidate typehashes / secrets)")
print("=" * 92)
by = bytes.fromhex(code)
PUSH1, PUSH32 = 0x60, 0x7f
consts, i, n = {}, 0, len(by)
while i < n:
    op = by[i]
    if op == PUSH32 and i + 32 < n:
        v = by[i+1:i+33].hex()
        consts[v] = consts.get(v, 0) + 1
    if PUSH1 <= op <= 0x7f:
        i += 1 + (op - PUSH1 + 1)
    elif op == 0x5f:
        i += 1
    else:
        i += 1
KNOWN = {
 DOMAIN_TH.hex(): "EIP712Domain typehash",
 hashed_name.hex(): "keccak('TaydexMarket')",
 hashed_version.hex(): "keccak('1')",
 domain_sep.hex(): "domainSeparator",
}
for v, cnt in sorted(consts.items(), key=lambda kv: -kv[1]):
    tag = KNOWN.get(v, "")
    print(f"  {v[:40]}…  x{cnt}  {tag}")
print(f"\n  total distinct PUSH32 constants: {len(consts)}")
json.dump({"hits": hits, "push32": list(consts.keys()),
           "domain_separator": domain_sep.hex()},
          open("taydex/pass15_typehash.json", "w"), indent=1)
print("[saved] pass15_typehash.json")
