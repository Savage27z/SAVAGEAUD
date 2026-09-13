#!/usr/bin/env python3
"""nar.bet — FORK v8: LP pool, part 2.

Open from part 1 (live-chain confirmed):
  * deposit(native, ANY amount>0) reverts "Staking amount exceeds limit"; WMON reverts
    "not whitelist token" -> LP deposits are closed on the live contract while it holds
    527,753 MON of LP capital.
  * BankRoll emits NO logs in 30 days -> share movements leave no trace.
  * `0xb84e8289 = unlockTimestamp(address,address)` (dictionary match) -> per-player token lock.
  * Two owner-only fns (0x4a9aa3c5, 0x7320ca26) took a PLAYER address with no observable effect;
    hypothesis: they take a TOKEN address (whitelist toggle) and I passed the wrong kind.

Tests here (all on the local fork):
  1. identify the two owner-only fns by passing TOKEN addresses and re-testing deposit(WMON)
  2. read unlockTimestamp for candidates
  3. can the operator drain the LP pool? withdrawNativeFunds / withdrawFunds as owner
"""
import json, os, time, urllib.request
from eth_abi import encode, decode as abi_decode
from eth_utils import keccak

RPC = "http://127.0.0.1:8555"
BASE = os.path.expanduser("~/.hermes/workspace/SAVAGEAUD/TARGETS/narbet")
BR = "0x71dc4a726C92E6bf506F2Afc2Cee8B63A89B29EC"
NATIVE = "0x" + "0" * 40
WMONl = "0x3bd359c1119da7da1d913d1c4d2b7c461115433a"
OWNER = "0x4aD0d8f0A100A74547e4B66C008CaE6e91Ef6d8b"
A1 = "0x70997970C51812dc3A010C7d01b50e0d17dc79C8"

_id = [0]
def raw(m, p, t=90):
    _id[0] += 1
    try:
        return json.loads(urllib.request.urlopen(urllib.request.Request(
            RPC, data=json.dumps({"jsonrpc": "2.0", "id": _id[0], "method": m, "params": p}).encode(),
            headers={"Content-Type": "application/json"}), timeout=t).read())
    except Exception as e:
        return {"error": {"message": str(e)[:120]}}


def call(to, data, frm=A1, value=0):
    d = raw("eth_call", [{"from": frm, "to": to, "data": data, "value": hex(value)}, "latest"])
    return d.get("result"), d.get("error")


def send(to, data, frm, value=0):
    d = raw("eth_sendTransaction", [{"from": frm, "to": to, "data": data, "value": hex(value)}])
    return d.get("result"), d.get("error")


def rc(h):
    for _ in range(40):
        r = raw("eth_getTransactionReceipt", [h]).get("result")
        if r:
            return r
        time.sleep(0.25)
    return None


def bal(a):
    v = raw("eth_getBalance", [a, "latest"]).get("result")
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
        return f"custom {d[:10]}"
    return f"empty revert ({e.get('message')})"


def dep_call(tok, amt, frm=BR, value=None):
    v = amt if value is None else value
    return expl(call(BR, "0x47e7ef24" + encode(["address", "uint256"], [tok, amt]).hex(),
                     frm=frm, value=v)[1])


def as_(a):
    raw("anvil_impersonateAccount", [a])
    raw("anvil_setBalance", [a, hex(10 ** 21)])


def tstamp(player, tok):
    r, e = call(BR, "0xb84e8289" + encode(["address", "address"], [player, tok]).hex())
    if e:
        return expl(e)
    h = r[2:]
    return [int(h[i * 64:(i + 1) * 64], 16) for i in range(len(h) // 64)]


def main():
    out = {}
    MON = 10 ** 18
    print(f"fork block {int(raw('eth_blockNumber', []).get('result', '0x0'), 16)}")
    print(f"pool balance: {bal(BR)/1e18:,.2f} MON   owner: {bal(OWNER)/1e18:,.2f} MON")

    print("\n[1] deposit baselines")
    print("   native 1 MON  ->", dep_call(NATIVE, MON))
    print("   WMON   1 MON  ->", dep_call(WMONl, MON, value=0))

    print("\n[1b] do the two owner-only fns take a TOKEN address? (called as owner)")
    as_(OWNER)
    for sel in ("0x4a9aa3c5", "0x7320ca26"):
        for tok, tn in ((WMONl, "WMON"), (NATIVE, "NATIVE")):
            h, e = send(BR, sel + "0" * 24 + tok[2:], OWNER)
            r = rc(h) if h else None
            after = dep_call(WMONl, MON, value=0)
            print(f"   {sel}({tn}) status={r and r['status']} {expl(e)}")
            print(f"      deposit(WMON) now -> {after}")
            out.setdefault("owner_fn_probe", []).append({"sel": sel, "arg": tn,
                                                         "status": r and r["status"], "after": after})

    print("\n[2] unlockTimestamp(player, token)")
    for p, pn in ((A1, "acct1"), (OWNER, "owner"), (BR, "BankRoll")):
        print(f"   {pn:9s} native -> {tstamp(p, NATIVE)}   wmon -> {tstamp(p, WMONl)}")

    print("\n[3] OPERATOR DRAIN TEST — can the owner take LP capital?")
    b0 = bal(BR)
    for name, data in (("withdrawNativeFunds(owner,100)", "0x26792aca" + encode(["address", "uint256"], [OWNER, 100 * MON]).hex()),
                       ("withdrawFunds(owner,(native),100)", "0x1c20fadd" + encode(["address", "address", "uint256"], [OWNER, NATIVE, 100 * MON]).hex())):
        h, e = send(BR, data, OWNER)
        r = rc(h) if h else None
        delta = (bal(BR) - b0) / 1e18
        print(f"   {name}: status={r and r['status']} {expl(e)}  pool delta={delta:+,.2f} MON")
        out.setdefault("drain_probe", []).append({"fn": name, "status": r and r["status"],
                                                  "pool_delta": delta, "err": expl(e)})
        b0 = bal(BR)

    print("\n[3b] largest drain attempt: owner asks for the whole pool")
    b0 = bal(BR)
    h, e = send(BR, "0x26792aca" + encode(["address", "uint256"], [OWNER, b0]).hex(), OWNER)
    r = rc(h) if h else None
    print(f"   withdrawNativeFunds(owner, {b0/1e18:,.2f}) status={r and r['status']} {expl(e)}")
    print(f"   pool after: {bal(BR)/1e18:,.2f} MON   owner: {bal(OWNER)/1e18:,.2f} MON")
    out["drain_all"] = {"status": r and r["status"], "err": expl(e),
                        "pool_after": bal(BR), "owner_after": bal(OWNER)}

    json.dump(out, open(os.path.join(BASE, "fork", "v8-lp-pool.json"), "w"), indent=1)
    print("\nsaved fork/v8-lp-pool.json")


if __name__ == "__main__":
    main()
