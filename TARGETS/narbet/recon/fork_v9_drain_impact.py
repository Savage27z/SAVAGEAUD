#!/usr/bin/env python3
"""nar.bet — FORK v9: compound impact of the operator drain.

v8 (fork, real code + real state): `withdrawNativeFunds(OWNER, 527,653.74 MON)` — one owner-only
call — took the pool from 527,753.74 MON to 0.00. No cap, no timelock, no event emitted.

This script establishes the two severity inputs:
  1. Is the owner key an EOA or a contract/multisig?  (live eth_getCode)
  2. Does draining the pool break live gameplay — i.e. can a player's WINNING bet still be paid
     afterwards? Drain, then settle a winning bet and watch.
"""
import json, os, time, urllib.request
from eth_abi import encode, decode as abi_decode
from eth_utils import keccak

FORK = "http://127.0.0.1:8555"
LIVE = "https://rpc2.monad.xyz"
BASE = os.path.expanduser("~/.hermes/workspace/SAVAGEAUD/TARGETS/narbet")
BR = "0x71dc4a726C92E6bf506F2Afc2Cee8B63A89B29EC"
RPS = "0x843d62ad75f5d0b383f8520e23d19174b7961b8e"
ENTROPY = "0xd458261e832415cfd3bae5e416fdf3230ce6f134"
PROVIDER = "0x52deaa1c84233f7bb8c8a45baede41091c616506"
NATIVE = "0x" + "0" * 40
OWNER = "0x4aD0d8f0A100A74547e4B66C008CaE6e91Ef6d8b"
A2 = "0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC"
WIN_RND = "0x" + "01" * 32
UA = {"Content-Type": "application/json",
      "User-Agent": "Mozilla/5.0 (X11; Linux x86_64) Chrome/124.0 Safari/537.36"}
ABI = json.load(open(os.path.join(BASE, "recon", "abi-real.json")))


def canon(ins):
    if not ins:
        return []
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
    o = []
    for p in parts:
        t = p.split()[0] if p.split() else p
        if t.startswith("tuple"):
            return None
        o.append(t)
    return o


ERR = {}
for n, s in ABI["errors"].items():
    t = canon(s.get("inputs") or "")
    if t is not None:
        ERR["0x" + keccak(text=f"{n}({','.join(t)})")[:4].hex()] = f"{n}({','.join(t)})"

_id = [0]
def raw(url, m, p, t=90):
    _id[0] += 1
    try:
        return json.loads(urllib.request.urlopen(urllib.request.Request(
            url, data=json.dumps({"jsonrpc": "2.0", "id": _id[0], "method": m, "params": p}).encode(),
            headers=UA), timeout=t).read())
    except Exception as e:
        return {"error": {"message": str(e)[:120]}}


def f_call(to, data, frm=A2, value=0):
    d = raw(FORK, "eth_call", [{"from": frm, "to": to, "data": data, "value": hex(value)}, "latest"])
    return d.get("result"), d.get("error")


def f_send(to, data, frm, value=0):
    d = raw(FORK, "eth_sendTransaction", [{"from": frm, "to": to, "data": data, "value": hex(value)}])
    return d.get("result"), d.get("error")


def rc(h):
    for _ in range(40):
        r = raw(FORK, "eth_getTransactionReceipt", [h]).get("result")
        if r:
            return r
        time.sleep(0.25)
    return None


def bal(a):
    v = raw(FORK, "eth_getBalance", [a, "latest"]).get("result")
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


def mine(n):
    d = 0
    while d < n:
        s = min(100, n - d)
        if raw(FORK, "anvil_mine", [hex(s), "0x0"]).get("error"):
            return d
        d += s
    return d


def main():
    out = {}
    MON = 10 ** 18

    print("=== 1. is the owner key an EOA or a contract? (live) ===")
    code = raw(LIVE, "eth_getCode", [OWNER, "latest"]).get("result")
    print(f"   owner {OWNER} code size = {len(code)//2 - 1 if code and code.startswith('0x') else '?'} bytes"
          f"  -> {'EOA (single key)' if code == '0x' else 'CONTRACT'}")
    ob = raw(LIVE, "eth_getBalance", [OWNER, "latest"]).get("result")
    print(f"   owner MON balance (live) = {int(ob,16)/1e18:,.2f}")
    out["owner_is_contract"] = code != "0x"
    out["owner_code_size"] = len(code) // 2 - 1 if code and code.startswith("0x") else 0

    print("\n=== 2. compound impact: does the drain brick live payouts? (fork) ===")
    raw(FORK, "anvil_impersonateAccount", [A2]); raw(FORK, "anvil_setBalance", [A2, hex(10**21)])
    wager = 100 * MON
    fee = int(f_call(RPS, "0x5768c29a")[0], 16)
    d = "0x493e7930" + encode(["uint256", "address", "uint8", "uint32"], [wager, NATIVE, 0, 1]).hex()
    h, e = f_send(RPS, d, A2, value=wager + fee)
    r = rc(h) if h else None
    print(f"   bet {wager/1e18:.0f} MON placed: status={r and r['status']} {expl(e)}")
    st, _ = f_call(RPS, "0xcfea2f6f" + "0" * 24 + A2[2:].lower())
    seq = int(st[2:][64:128], 16)
    print(f"   pending request seq={seq}; pool now {bal(BR)/1e18:,.2f} MON")

    raw(FORK, "anvil_impersonateAccount", [OWNER]); raw(FORK, "anvil_setBalance", [OWNER, hex(10**20)])
    pool = bal(BR)
    hd, ed = f_send(BR, "0x26792aca" + encode(["address", "uint256"], [OWNER, pool]).hex(), OWNER)
    rd = rc(hd) if hd else None
    print(f"   DRAIN by owner: status={rd and rd['status']} {expl(ed)}"
          f"  pool -> {bal(BR)/1e18:,.2f} MON (took {(bal(OWNER))/1e18:,.2f})")
    print(f"   logs emitted by the drain: {len((rd or {}).get('logs', []))}")
    out["drain"] = {"status": rd and rd["status"], "pool_after": bal(BR),
                    "logs": len((rd or {}).get("logs", []))}

    a2_before = bal(A2)
    raw(FORK, "anvil_impersonateAccount", [ENTROPY]); raw(FORK, "anvil_setBalance", [ENTROPY, hex(10**19)])
    dc = "0x52a5f1f8" + encode(["uint64", "address", "bytes32"],
                               [seq, PROVIDER, bytes.fromhex(WIN_RND[2:])]).hex()
    hc, ec = f_send(RPS, dc, ENTROPY)
    rcc = rc(hc) if hc else None
    print(f"   settle the WINNING bet after the drain: status={rcc and rcc['status']} {expl(ec)}")
    print(f"   player balance delta: {(bal(A2)-a2_before)/1e18:+,.2f} MON (bet cost was"
          f" {-(wager+fee)/1e18:,.2f}, expected win payout +{wager*1.9/1e18:,.2f})")
    st2, _ = f_call(RPS, "0xcfea2f6f" + "0" * 24 + A2[2:].lower())
    print(f"   GetState after settle: {[int(st2[2:][i*64:(i+1)*64],16) for i in range(len(st2[2:])//64)]}")
    out["settle_after_drain"] = {"status": rcc and rcc["status"], "err": expl(ec),
                                 "player_delta": (bal(A2) - a2_before) / 1e18}

    json.dump(out, open(os.path.join(BASE, "fork", "v9-drain-impact.json"), "w"), indent=1)
    print("\nsaved fork/v9-drain-impact.json")


if __name__ == "__main__":
    main()
