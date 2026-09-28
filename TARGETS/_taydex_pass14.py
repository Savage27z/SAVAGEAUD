#!/usr/bin/env python3
"""TayDex pass14: locate the trust variables and resolve the EIP-712 struct definition
from the DEPLOYED bytecode (on my own Base fork).

Three decisive questions:
 (1) Are signer/usdc/feeRecipient immutables (address baked into code) or storage vars?
     An immutable cannot be changed at runtime -> tells us the upgrade surface.
     It also decides whether the signer-override fork attack is possible.
 (2) Which EIP-712 typehash is compiled into the contract? Compute candidates and search.
     Control = the EIP712Domain typehash, which must be present.
 (3) What ASCII strings live in the code (error messages reveal internal checks).

Read-only against my own fork (127.0.0.1:8546).
"""
import json, re, urllib.request

R = "http://127.0.0.1:8546"
C = "0x3ade22fa1ef5ac75437a3734d91ba588e54875dd"
from Crypto.Hash import keccak as _k
def keccak(b): h = _k.new(digest_bits=256); h.update(b); return h.digest()
def khex(s): return keccak(s.encode()).hex()

def rpc(m, p):
    req = urllib.request.Request(R, data=json.dumps({"jsonrpc": "2.0", "id": 1,
                                                     "method": m, "params": p}).encode(),
                                 headers={"Content-Type": "application/json"})
    return json.loads(urllib.request.urlopen(req, timeout=40).read())

code = rpc("eth_getCode", [C, "latest"])["result"][2:]
print(f"runtime {len(code)//2:,} bytes\n")

# ---------- (1) immutables vs storage ----------
print("=" * 92)
print("(1) WHERE DO THE TRUST VARIABLES LIVE?  (address present in CODE => immutable)")
print("=" * 92)
VARS = {
    "usdc()":         "833589fcd6edb6e08f4c7c32d4f71b54bda02913",
    "signer()":       "b5932a150f48dcd5b299702dd0091670368ea4c9",
    "feeRecipient()": "c0b085c1a5514d8541adcb105aa7e6e8e5bc74ed",
    "owner()":        "ef869234bb919bbde0f44d98912e87d1ce0463f8",
}
for label, a in VARS.items():
    print(f"  {label:<16} in CODE: {'YES -> immutable' if a in code else 'no  -> storage/slot'}"
          f"   [{(code.count(a))} occurrence(s)]")

print("\n  storage slots 0..14:")
for i in range(15):
    r = rpc("eth_getStorageAt", [C, hex(i), "latest"])
    v = r.get("result")
    tail = v[-40:] if isinstance(v, str) else ""
    tag = {a: l for l, a in VARS.items()}.get(tail, "")
    dec = int(v, 16) if isinstance(v, str) else None
    small = f"{dec}" if dec is not None and dec < 2**80 else ""
    print(f"    slot {i:<3} {v}  {small:<14} {'-> ' + tag if tag else ''}")

# ---------- (2) typehash hunt ----------
print("\n" + "=" * 92)
print("(2) EIP-712 TYPEHASH HUNT  (control first)")
print("=" * 92)
CTRL = "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
cands = {
    "CREATE-MARKET  (app ABI, NO actor)":
        "CreateMarket(uint64 endDate,uint128[] fundingPerOption,uint16 creatorFeeShareBps,uint256 nonce,uint256 deadline)",
    "CREATE-MARKET  (+address creator, FIRST)":
        "CreateMarket(address creator,uint64 endDate,uint128[] fundingPerOption,uint16 creatorFeeShareBps,uint256 nonce,uint256 deadline)",
    "CREATE-MARKET  (+address creator, LAST)":
        "CreateMarket(uint64 endDate,uint128[] fundingPerOption,uint16 creatorFeeShareBps,uint256 nonce,uint256 deadline,address creator)",
    "CREATE-MARKET  (+address msgSender)":
        "CreateMarket(address msgSender,uint64 endDate,uint128[] fundingPerOption,uint16 creatorFeeShareBps,uint256 nonce,uint256 deadline)",
    "CREATE-MARKET  (+address sender,uint32 ref)":
        "CreateMarket(uint64 endDate,uint128[] fundingPerOption,uint16 creatorFeeShareBps,uint256 nonce,uint256 deadline,address sender)",
    "Market  (alt name, NO actor)":
        "Market(uint64 endDate,uint128[] fundingPerOption,uint16 creatorFeeShareBps,uint256 nonce,uint256 deadline)",
    "CreateMarketParams (NO actor)":
        "CreateMarketParams(uint64 endDate,uint128[] fundingPerOption,uint16 creatorFeeShareBps,uint256 nonce,uint256 deadline)",
    "BUY  (app ABI, ref only)":
        "Buy(uint256 marketId,uint16 optionIndex,uint8 outcome,uint256 usdcIn,uint256 sharesOut,uint256 fee,address referrer,uint256 referralFee,uint256 nonce,uint256 deadline)",
    "SELL (app ABI, ref only)":
        "Sell(uint256 marketId,uint16 optionIndex,uint8 outcome,uint256 sharesIn,uint256 usdcOut,uint256 fee,address referrer,uint256 referralFee,uint256 nonce,uint256 deadline)",
}
for label, s in [("CONTROL domain", CTRL)] + list(cands.items()):
    h = khex(s)
    hit = h in code
    print(f"  {'HIT ' if hit else '    '} {h[:16]}…  {label}")
    if hit:
        print(f"          exact string: {s}")

# ---------- (3) ASCII strings in the code ----------
print("\n" + "=" * 92)
print("(3) ASCII STRINGS IN THE RUNTIME (error messages / reverts)")
print("=" * 92)
seen = set()
for m in re.finditer(rb"[\x20-\x7e]{5,80}", bytes.fromhex(code)):
    s = m.group().decode()
    if s in seen:
        continue
    seen.add(s)
    if any(c.isalpha() for c in s) and not re.fullmatch(r"[0-9a-fA-F]{40}", s):
        print(f"  {s!r}")
