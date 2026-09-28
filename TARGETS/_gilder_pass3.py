#!/usr/bin/env python3
"""GILDer Phase 1a — the role model, on-chain.

The BondContract ABI declares role constants as public getters, so the bytes32 values can be read
rather than guessed. Plain OZ AccessControl has no getRoleMemberCount (only the Enumerable variant
does), which is why my earlier enumeration found nothing -- so membership is probed with
hasRole(role, candidate) against every plausible candidate address.
Read-only: eth_call.
"""
import json, os, urllib.error, urllib.request, time

BASE = os.path.dirname(os.path.abspath(__file__))
TGT = os.path.join(BASE, "gilder")
UA = {"User-Agent": "Mozilla/5.0", "Content-Type": "application/json"}
RPC = "https://mainnet.base.org"
from Crypto.Hash import keccak as _k
def keccak(b): h = _k.new(digest_bits=256); h.update(b); return h.digest()
def sig4(s): return keccak(s.encode()).hex()[:8]

def rpc(m, p, tries=3):
    for a in range(tries):
        try:
            req = urllib.request.Request(RPC, data=json.dumps(
                {"jsonrpc": "2.0", "id": 1, "method": m, "params": p}).encode(), headers=UA)
            return json.loads(urllib.request.urlopen(req, timeout=25).read()).get("result")
        except Exception:
            time.sleep(0.5)
    return None

def call(to, data):
    return rpc("eth_call", [{"to": to, "data": data}, "latest"])

BOND = "0x5d25cfc927f95cb519c0fef438afaa64cb374e10"
NFT = "0x809c4ee02279a38c9c32e63d4e1d9f0f8cc7da02"
CANDIDATES = {
    "proxyAdmin(EOA)": "0xb358e81b0f92698215bbe821b8c25986ad523a1b",
    "tokenBuyRouter.admin": "0x54f2316b0c02808354fd7f0d48e64a788f7be533",
    "treasuryProxy": "0x9e2ce9510a89deac71898fd0a86d84214c20607b",
    "safeVault": "0x9b937b72172c0706b51984a09992bb8007771e67",
    "depositNFT": NFT,
    "bondContract": BOND,
    "tokenBuyRouter": "0xd144cdceb6a49bc9be906964abeb6de5d39952d0",
    "gilderToken": "0xa6c3b8dcb7c31132dcef64ef099f68b731db1e73",
    "zero": "0x0000000000000000000000000000000000000000",
}
ROLES = ["DEFAULT_ADMIN_ROLE", "UPGRADER_ROLE", "PARAMETER_ROLE", "BOND_ENGINE_ROLE",
         "LENDING_OPERATOR_ROLE", "LIQUIDATOR_ROLE", "NFT_MINTER_ROLE",
         "TREASURY_OPERATOR_ROLE", "COMPOUND_OPERATOR_ROLE", "PAUSER_ROLE"]

# read the role constants off the contract
role_vals = {}
print("=" * 100)
print("ROLE CONSTANTS (read, not guessed)")
print("=" * 100)
for r in ROLES:
    v = call(BOND, "0x" + sig4(f"{r}()"))
    if isinstance(v, str) and len(v) == 66:
        role_vals[r] = v[2:]
        print(f"  {r:<24} = 0x{v[2:]}")
    else:
        print(f"  {r:<24} <no getter>")

print("\n" + "=" * 100)
print("hasRole PROBES  (rows = candidate address, cols = role)")
print("=" * 100)
hdr = "  " + "candidate".ljust(22) + "".join(r.split("_")[0][:6].rjust(7) for r in ROLES)
print(hdr)
found = {}
for label, addr in CANDIDATES.items():
    line = "  " + label.ljust(22)
    for r in ROLES:
        if r not in role_vals:
            line += "".rjust(7); continue
        res = call(BOND, "0x" + sig4("hasRole(bytes32,address)")
                   + role_vals[r] + addr.lower().replace("0x", "").rjust(64, "0"))
        bit = "yes" if isinstance(res, str) and int(res, 16) == 1 else "."
        line += bit.rjust(7)
        if bit == "yes":
            found.setdefault(label, []).append(r)
    print(line)

print("\n" + "=" * 100)
print("SUMMARY")
print("=" * 100)
for label, roles in found.items():
    print(f"  {label:<24} holds: {', '.join(roles)}")
if not found:
    print("  no roles matched any candidate -> holders are other addresses (need event scan)")

json.dump({"roles": role_vals, "holders": found},
          open(os.path.join(TGT, "phase1_roles.json"), "w"), indent=1)
print("\n[saved] phase1_roles.json")
