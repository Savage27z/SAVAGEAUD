#!/usr/bin/env python3
"""GILDer Phase 1b — does the DEPLOYMENT match the security model the source claims?

GilderAccessControl.sol / GilderProxy.sol comments assert:
  (1) "the governance multisig and the UUPS proxy both enforce a 48h timelock"
  (2) "DEFAULT_ADMIN_ROLE is held by the multisig"
  (3) "Production deploys MUST call setGuardianCouncil" (else unfreeze falls back to PAUSER_ROLE)
Each is checkable. A deployment that does not match its documented model is a finding.
Read-only: eth_call / eth_getCode / eth_getStorageAt.
"""
import json, os, time, urllib.error, urllib.request

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

def code_size(a):
    c = rpc("eth_getCode", [a, "latest"])
    return (len(c) - 2) // 2 if isinstance(c, str) else -1

def call(to, sig, args=""):
    r = rpc("eth_call", [{"to": to, "data": "0x" + sig4(sig) + args}, "latest"])
    return r

def as_addr(r):
    if isinstance(r, str) and len(r) == 66:
        return "0x" + r[-40:]
    return None

BOND = "0x5d25cfc927f95cb519c0fef438afaa64cb374e10"
PROXIES = ["0x13a18c43be8d5faefb4d00a70817af74be81f06c",
           "0x41e5d0ea02cccae1d8acf0d8533afd9ddf0f1bca",
           "0x904e0e92ebd0a40d04c5b54be4c75447879c2a5d",
           "0x9e2ce9510a89deac71898fd0a86d84214c20607b",
           "0xaa199c5605c221574d9738ada3d04ceea493e658",
           "0xf2e668f7e457d16e546ba56f531b007a17f946e8"]
ADMIN_EOA = "0xb358e81b0f92698215bbe821b8c25986ad523a1b"
DEFAULT_ADMIN_HOLDER = "0x54f2316b0c02808354fd7f0d48e64a788f7be533"

print("=" * 100)
print("CLAIM CHECK — is the described security model actually deployed?")
print("=" * 100)

print("\n(2) DEFAULT_ADMIN_ROLE holder — should be 'the multisig'")
for label, a in [("DEFAULT_ADMIN holder", DEFAULT_ADMIN_HOLDER), ("proxy admin", ADMIN_EOA)]:
    n = code_size(a)
    kind = "CONTRACT" if n > 100 else "EOA  <-- not a multisig" if n == 0 else "?"
    print(f"  {label:<22} {a}  runtime {n:>6,}B  {kind}")
    if n > 100:
        for s in ["getThreshold()", "getOwners()", "VERSION()", "owner()", "delay()",
                  "getMinDelay()", "isUnanimousExecution()", "ownerCount()"]:
            r = call(a, s)
            if isinstance(r, str) and r != "0x":
                print(f"      {s:<26} = {str(r)[:70]}")

print("\n(3) guardianCouncil / deployer / emergency guardians")
gc = as_addr(call(BOND, "guardianCouncil()"))
dep = as_addr(call(BOND, "deployer()"))
print(f"  guardianCouncil() = {gc}")
if gc and gc != "0x" + "0" * 40:
    n = code_size(gc)
    print(f"      council runtime {n:,}B  {'CONTRACT' if n > 100 else 'EOA (!)'}")
    for s in ["isUnanimousExecution()", "ownerCount()", "getThreshold()", "getOwners()"]:
        r = call(gc, s)
        print(f"      {s:<26} = {str(r)[:70]}")
else:
    print("      -> NOT WIRED: emergencyUnfreeze falls back to PAUSER_ROLE (single signer)")
print(f"  deployer()        = {dep}")
if dep and dep != "0x" + "0" * 40:
    print(f"      deployer runtime {code_size(dep):,}B "
          f"({'CONTRACT' if code_size(dep) > 100 else 'EOA'})")
    print("      -> deployer still holds FREEZE power (renounceDeployerFreeze not called)"
          if dep != "0x" + "0" * 40 else "")

print("\n(1) TIMELOCK — the comments claim a 48h timelock on upgrades")
for p in PROXIES[:2]:
    # ERC1967 admin slot
    adm = rpc("eth_getStorageAt", [p, "0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103", "latest"])
    impl = rpc("eth_getStorageAt", [p, "0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc", "latest"])
    admin_addr = as_addr(adm)
    print(f"\n  proxy {p}")
    print(f"    admin = {admin_addr}   runtime {code_size(admin_addr):,}B")
    print(f"    impl  = {as_addr(impl)}")
    # probe common timelock selectors on the admin
    if admin_addr:
        for s in ["getMinDelay()", "delay()", "minDelay()", "getDelay()", "GRACE_PERIOD()",
                  "TIMELOCK_ADMIN_ROLE()", "isOperationPending(bytes32)", "delaySeconds()"]:
            r = call(admin_addr, s)
            if isinstance(r, str) and r != "0x":
                v = int(r, 16) if len(r) == 66 else r
                print(f"      {s:<28} = {v}")

print("\n(4) live config getters on BondContract")
for s in ["paused()", "depositsEnabled()", "pegOk()", "nextDepositId()", "asset()",
          "lendingContract()", "cyrContract()", "turboContract()", "tvtContract()",
          "autoCompoundContract()", "tokenBuyRouter()", "liquidityManager()",
          "liquidityRecipient()", "marketingWallet()", "safeVault()", "treasury()"]:
    r = call(BOND, s)
    if not isinstance(r, str) or r == "0x":
        print(f"  {s:<26} <revert/no getter>"); continue
    raw = r[2:]
    if len(raw) == 64:
        v = int(raw, 16)
        out = ("0x" + raw[-40:]) if v > 2**96 else str(v)
    else:
        out = "0x" + raw[:40] + "…"
    print(f"  {s:<26} = {out}")
