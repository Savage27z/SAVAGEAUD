#!/usr/bin/env python3
"""TayDex pass8: two decisive read-only tests.
 (A) exact revert DATA for every mutating function, simulated from a random address.
     An `onlyOwner`/role modifier runs before the body, so a gated function ALWAYS reverts
     with the same auth selector regardless of arguments. A function that reverts with a
     BODY reason ("no leftover", "not creator") reached its body -> no auth gate in front.
 (B) ABI-vs-BY TECODE selector diff: which selectors in the app's ABI actually exist in the
     deployed runtime code. Tells us if the frontend is ahead of / behind the chain.
Read-only: eth_call + eth_getCode only. Nothing signed, nothing broadcast.
"""
import json, os, re, time, urllib.error, urllib.request

TGT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "taydex")
CORE = "0x3ade22fa1ef5ac75437a3734d91ba588e54875dd"
RPCS = ["https://base-rpc.publicnode.com", "https://1rpc.io/base",
        "https://mainnet.base.org", "https://base.drpc.org"]
UA = ("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36")

from Crypto.Hash import keccak as _k
def keccak(b): h = _k.new(digest_bits=256); h.update(b); return h.digest()
def sig4(s): return "0x" + keccak(s.encode()).hex()[:8]

def rpc(method, params, tries=3):
    last = None
    for _ in range(tries):
        for url in RPCS:
            try:
                body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method,
                                   "params": params}).encode()
                req = urllib.request.Request(url, data=body,
                    headers={"Content-Type": "application/json", "User-Agent": UA})
                raw = urllib.request.urlopen(req, timeout=25).read()
            except urllib.error.HTTPError as e:
                raw = e.read()
            except Exception as e:
                last = f"{type(e).__name__}: {e}"; continue
            try:
                r = json.loads(raw)
            except Exception:
                last = f"non-JSON {raw[:80]!r}"; continue
            if "result" in r: return r["result"], url
            if "error" in r:  return {"__e__": r["error"]}, url
        time.sleep(1.0)
    return {"__e__": last}, None

def u(v):  return f"{int(v):064x}"
def a(x):  return x.lower().replace("0x", "").rjust(64, "0")

abi = json.load(open(os.path.join(TGT, "abi_core.json")))

# ---------- custom errors from the ABI ----------
ERR = {}
for e in abi:
    if e.get("type") == "error":
        ERR[sig4(f"{e['name']}({','.join(i.get('type','?') for i in e.get('inputs',[]))})")] = e["name"]
ERR.update({
    "0x118cdaa7": "OwnableUnauthorizedAccount(address) [OZ v5]",
    "0x8f4eb604": "EnforcedPause()",
    "0xd93c0665": "ExpectedPause()",
    "0x82b42900": "Unauthorized()",
    "0xe450d38c": "ERC20InsufficientBalance(...)",
    "0xfb8f41b2": "ERC20InsufficientAllowance(...)",
    "0xcd3f1659": "ERC1155InsufficientBalance(...)",
    "0xd0b6a3b8": "ERC1155MissingApprovalForAll(...)",
})

def decode_revert(d):
    if not isinstance(d, str) or not d.startswith("0x") or len(d) < 10:
        return None
    s = d[:10]
    # Error(string)
    if s == "0x08c379a0":
        try:
            ln = int(d[10:74], 16)
            msg = bytes.fromhex(d[74:74 + ln * 2]).decode("utf-8", "replace")
            return f'Error("{msg}")'
        except Exception:
            return "Error(string) <undecodable>"
    if s == "0x4e487b71":
        try:
            return f"Panic(0x{int(d[10:74],16):02x})"
        except Exception:
            return "Panic(?)"
    return ERR.get(s, f"UNKNOWN selector {s}")

RAND = "0x" + "9a7f" * 10   # arbitrary address with no role, never used

PROBES = [
    ("sweepLeftover(uint256,uint16)",        sig4("sweepLeftover(uint256,uint16)") + u(2) + u(0)),
    ("sweepLeftover(uint256,uint16) [m1]",   sig4("sweepLeftover(uint256,uint16)") + u(1) + u(0)),
    ("pushReferral(uint256,address)",        sig4("pushReferral(uint256,address)") + u(1) + a(RAND)),
    ("claimReferral(uint256)",               sig4("claimReferral(uint256)") + u(1)),
    ("pushReferralBatch(uint256[],address[])", None),
    ("rescueToken(address,address,uint256)", sig4("rescueToken(address,address,uint256)") + a("0x833589fcd6edb6e08f4c7c32d4f71b54bda02913") + a(RAND) + u(1)),
    ("setMarketCreatorFeeShare(uint256,uint16)", sig4("setMarketCreatorFeeShare(uint256,uint16)") + u(3) + u(9999)),
    ("setSigner(address)",                   sig4("setSigner(address)") + a(RAND)),
    ("setFeeRecipient(address)",             sig4("setFeeRecipient(address)") + a(RAND)),
    ("setDisputeFee(uint256)",               sig4("setDisputeFee(uint256)") + u(1)),
    ("setConfig(uint256,uint256)",           sig4("setConfig(uint256,uint256)") + u(1) + u(1)),
    ("setURI(string)",                       None),
    ("pause()",                              sig4("pause()")),
    ("unpause()",                            sig4("unpause()")),
    ("voidMarket(uint256)",                  sig4("voidMarket(uint256)") + u(3)),
    ("resolveMarket(uint256,uint16)",        sig4("resolveMarket(uint256,uint16)") + u(3) + u(0)),
    ("resolveSingleBinary(uint256,bool)",    sig4("resolveSingleBinary(uint256,bool)") + u(3) + u(1)),
    ("resolveDraw(uint256)",                 sig4("resolveDraw(uint256)") + u(3)),
    ("resolveDispute(uint256,bool)",         sig4("resolveDispute(uint256,bool)") + u(1) + u(1)),
    ("claim(uint256,uint16)",                sig4("claim(uint256,uint16)") + u(1) + u(0)),
    ("claimCreatorFees(uint256)",            sig4("claimCreatorFees(uint256)") + u(1)),
    ("dispute(uint256)",                     sig4("dispute(uint256)") + u(3)),
    ("acceptOwnership()",                    sig4("acceptOwnership()")),
]
print("=" * 100)
print("(A) REVERT-DATA PROBE  from random address", RAND)
print("   rule: auth modifiers run BEFORE the body -> a gated fn always reverts with the")
print("   auth selector. A body reason means the call reached the body.")
print("=" * 100)
res = {}
for label, data in PROBES:
    if data is None:
        print(f"  {label:<44} (dynamic args - skipped)")
        continue
    r, _ = rpc("eth_call", [{"from": RAND, "to": CORE, "data": data}, "latest"])
    if isinstance(r, dict):
        err = r["__e__"]
        d = err.get("data") if isinstance(err, dict) else None
        msg = err.get("message") if isinstance(err, dict) else str(err)
        dec = decode_revert(d) if d else None
        res[label] = {"message": msg, "data": d, "decoded": dec}
        print(f"  {label:<44} {msg}")
        print(f"      data={d}   => {dec}")
    else:
        res[label] = {"returned": r}
        print(f"  {label:<44} *** SURVIVED *** returned {str(r)[:70]}")

# ---------- (B) ABI vs deployed bytecode ----------
print("\n" + "=" * 100)
print("(B) SELECTOR EXISTENCE: app ABI  vs  deployed runtime bytecode")
print("=" * 100)
code, _ = rpc("eth_getCode", [CORE, "latest"])
code = code or ""
print(f"  runtime size = {(len(code) - 2) // 2:,} bytes\n")

def sig_of(e):
    ins = []
    for i in e.get("inputs", []):
        t = i.get("type", "?")
        if t.startswith("tuple"):
            t = "(" + ",".join(c.get("type", "?") for c in i.get("components", [])) + ")" + t[5:]
        ins.append(t)
    return f"{e['name']}({','.join(ins)})"

missing, present = [], []
for e in abi:
    if e.get("type") != "function":
        continue
    s = sig4(sig_of(e))
    (present if s[2:] in code else missing).append((s, sig_of(e)))

print(f"  PRESENT in bytecode: {len(present)}")
print(f"  MISSING from bytecode: {len(missing)}")
if missing:
    print("\n  --- declared in the app ABI but NOT in the deployed contract ---")
    for s, sig in missing:
        print(f"      {s}  {sig}")
json.dump({"reverts": res, "missing_selectors": [m[1] for m in missing],
           "present_count": len(present), "missing_count": len(missing)},
          open(os.path.join(TGT, "pass8_guards.json"), "w"), indent=1)
print("\n[saved] pass8_guards.json")
