#!/usr/bin/env python3
"""TayDex pass12: identify what the DEPLOYED contract actually implements.
 (1) resolve the 27 deployed-only PUSH4 selectors via 4byte.directory
 (2) raw-byte search for buy/sell/createMarket selectors in the runtime code
     (second, independent method vs the disassembler)
Read-only.
"""
import json, os, time, urllib.error, urllib.request

TGT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "taydex")
CORE = "0x3ade22fa1ef5ac75437a3734d91ba588e54875dd"
RPCS = ["https://base-rpc.publicnode.com", "https://1rpc.io/base",
        "https://mainnet.base.org", "https://base.drpc.org"]
UA = ("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36")

def post(url, data, headers=None):
    h = {"Content-Type": "application/json", "User-Agent": UA}
    h.update(headers or {})
    req = urllib.request.Request(url, data=json.dumps(data).encode(), headers=h)
    try:
        return json.loads(urllib.request.urlopen(req, timeout=25).read())
    except urllib.error.HTTPError as e:
        try: return json.loads(e.read())
        except Exception: return None
    except Exception:
        return None

def getcode():
    for _ in range(4):
        for url in RPCS:
            r = post(url, {"jsonrpc": "2.0", "id": 1, "method": "eth_getCode",
                           "params": [CORE, "latest"]})
            if r and "result" in r:
                return r["result"][2:]
        time.sleep(1)
    return ""

code = getcode()
by = bytes.fromhex(code)
print(f"runtime {len(by):,} bytes\n")

# ---------- (1) resolve deployed-only selectors ----------
sel = json.load(open(os.path.join(TGT, "deployed_only_selectors.json")))
print("=" * 96)
print("(1) 4byte.directory resolution of the deployed-only selectors")
print("=" * 96)
KNOWN_ERR = {
    "118cdaa7": "OwnableUnauthorizedAccount(address)  [ERROR, OZ v5]",
    "1e4fbdf7": "OwnableInvalidOwner(address)  [ERROR, OZ v5]",
    "3ee5aeb5": "ReentrancyGuardReentrantCall()  [ERROR]",
    "4e487b71": "Panic(uint256)  [PANIC]",
    "ffffffff": "<not a real selector - dispatch sentinel>",
    "7a65726f": "<ascii 'zero' - string constant, not a selector>",
    "f645eedf": "ECDSAInvalidSignature()  [ERROR]",
    "5274afe7": "SafeERC20FailedOperation(address)  [ERROR]",
    "fce698f7": "SafeCastOverflowedUintDownDowncast(uint8,uint256)  [ERROR]",
    "23b872dd": "transferFrom(address,address,uint256)  [ERC20 op]",
    "a9059cbb": "transfer(address,uint256)  [ERC20 op]",
    "bc197c81": "onERC1155BatchReceived(...)  [receiver hook check]",
    "f23a6e61": "onERC1155Received(...)  [receiver hook check]",
}
resolved = {}
for s in sel:
    if s in KNOWN_ERR:
        resolved[s] = KNOWN_ERR[s]
        print(f"  0x{s}  {KNOWN_ERR[s]}")
        continue
    r = post("https://www.4byte.directory/api/v1/signatures/?hex_signature=0x" + s, None)
    # the endpoint is GET; redo properly
    try:
        req = urllib.request.Request(
            "https://www.4byte.directory/api/v1/signatures/?hex_signature=0x" + s,
            headers={"User-Agent": UA})
        r = json.loads(urllib.request.urlopen(req, timeout=25).read())
    except Exception:
        r = None
    names = [x["text_signature"] for x in (r or {}).get("results", [])][:3]
    resolved[s] = names
    print(f"  0x{s}  {names if names else '<no match>'}")
    time.sleep(0.3)

# ---------- (2) raw-byte existence check, independent of the disassembler ----------
print("\n" + "=" * 96)
print("(2) RAW-BYTE CHECK of the app's mutating selectors in the runtime code")
print("=" * 96)
from Crypto.Hash import keccak as _k
def keccak(b): h = _k.new(digest_bits=256); h.update(b); return h.digest()
def sig4(s): return keccak(s.encode()).hex()[:8]

CHECK = [
 "createMarket((uint64,uint128[],uint16,uint256,uint256),bytes)",
 "buy((uint256,uint16,uint8,uint256,uint256,uint256,address,uint256,uint256,uint256),bytes)",
 "sell((uint256,uint16,uint8,uint256,uint256,uint256,address,uint256,uint256,uint256),bytes)",
 "claim(uint256,uint16)",
 "claimCreatorFees(uint256)",
 "dispute(uint256)",
 "resolveMarket(uint256,uint16)",
 "resolveSingleBinary(uint256,bool)",
 "resolveDispute(uint256,bool)",
 "sweepLeftover(uint256,uint16)",
 "setSigner(address)",
 "setFeeRecipient(address)",
 "setConfig(uint256,uint256)",
 "setDisputeFee(uint256)",
 "rescueToken(address,address,uint256)",
 "voidMarket(uint256)",
 "pause()",
 "unpause()",
 "pushReferral(uint256,address)",
 "claimReferral(uint256)",
 "setMarketCreatorFeeShare(uint256,uint16)",
 "userShares(address,uint256,uint16,uint8)",
 "balanceOf(address,uint256)",
]
print(f"{'selector':<12} {'raw bytes in code':<18} function")
print("-" * 96)
for sig in CHECK:
    s = sig4(sig)
    hit = s in code
    print(f"0x{s:<10} {'YES' if hit else 'no':<18} {sig}")

json.dump(resolved, open(os.path.join(TGT, "pass12_deployed_iface.json"), "w"), indent=1)
print("\n[saved] pass12_deployed_iface.json")
