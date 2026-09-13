#!/usr/bin/env python3
"""nar.bet — FORK v10: clean A/B for the operator-drain impact.

QUESTION: if the owner drains the pool, can a player with a WINNING bet still be paid?

A (control, no drain): bet -> settle a win -> expect payout (~1.9x), callback status 0x1
B (drain first):       bet -> owner drains 100% -> settle the same win -> observe

Everything funded explicitly (Monad base fee is 100 gwei; the bet needs wager+fee in value).
Fresh fork required. Output: fork/v10-drain-ab.json
"""
import json, os, time, urllib.request
from eth_abi import encode, decode as abi_decode
from eth_utils import keccak

FORK = "http://127.0.0.1:8555"
BASE = os.path.expanduser("~/.hermes/workspace/SAVAGEAUD/TARGETS/narbet")
BR = "0x71dc4a726C92E6bf506F2Afc2CEE8b63A89B29EC".replace("CEE8b", "Cee8B")
RPS = "0x843d62ad75f5d0b383f8520e23d19174b7961b8e"
ENT = "0xd458261e832415cfd3bae5e416fdf3230ce6f134"
PROV = "0x52deaa1c84233f7bb8c8a45baede41091c616506"
NATIVE = "0x" + "0" * 40
OWNER = "0x4aD0d8f0A100A74547e4B66C008CaE6e91Ef6d8b"
A2 = "0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC"
A3 = "0x90F79bf6EB2c4f870365E785982E1f101E93b906"
WIN_RND = "0x" + "01" * 32
ABI = json.load(open(os.path.join(BASE, "recon", "abi-real.json")))
ERR = {}
for n, s in ABI["errors"].items():
    ins = (s.get("inputs") or "")
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


def call(to, data, frm=A2, value=0):
    d = rpc("eth_call", [{"from": frm, "to": to, "data": data, "value": hex(value)}, "latest"])
    return d.get("result"), d.get("error")


def send(to, data, frm, value=0):
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


def seq_of(p):
    st, _ = call(RPS, "0xcfea2f6f" + "0" * 24 + p[2:].lower())
    if not st:
        return None
    return int(st[2:][64:128], 16)


def fund(a, mon):
    rpc("anvil_impersonateAccount", [a])
    rpc("anvil_setBalance", [a, hex(mon)])


def cb_data(seq):
    return "0x52a5f1f8" + encode(["uint64", "address", "bytes32"],
                                [seq, PROV, bytes.fromhex(WIN_RND[2:])]).hex()


def main():
    MON = 10 ** 18
    out = {}
    for a in (A2, A3, ENT, OWNER):
        fund(a, 1000 * MON)
    fee = int(call(RPS, "0x5768c29a")[0], 16)
    wager = 100 * MON
    print(f"fork block {int(rpc('eth_blockNumber', []).get('result','0x0'),16)} fee={fee/1e18} "
          f"pool={bal(BR)/1e18:,.2f}")

    # ---------------- A: control, no drain ----------------
    print("\n=== A. CONTROL: settle a winning bet with the pool intact ===")
    h, e = send(RPS, "0x493e7930" + encode(["uint256", "address", "uint8", "uint32"],
                                           [wager, NATIVE, 0, 1]).hex(), A2, value=wager + fee)
    r = rc(h) if h else None
    print(f"   bet: status={r and r['status']} {expl(e)}")
    seqA = seq_of(A2)
    cash = bal(A2)
    e_call = call(RPS, cb_data(seqA), frm=ENT)[1]
    print(f"   callback eth_call pre-check -> {expl(e_call)}")
    hc, ec = send(RPS, cb_data(seqA), ENT)
    rcc = rc(hc) if hc else None
    print(f"   settle: status={rcc and rcc['status']} {expl(ec)}")
    print(f"   player delta={(bal(A2)-cash)/1e18:+,.2f} MON  pool={bal(BR)/1e18:,.2f}")
    out["control"] = {"bet_status": r and r["status"], "settle_status": rcc and rcc["status"],
                      "player_delta": (bal(A2) - cash) / 1e18}

    # ---------------- B: drain first ----------------
    print("\n=== B. DRAIN FIRST, then settle the same way ===")
    h2, e2 = send(RPS, "0x493e7930" + encode(["uint256", "address", "uint8", "uint32"],
                                             [wager, NATIVE, 0, 1]).hex(), A3, value=wager + fee)
    r2 = rc(h2) if h2 else None
    seqB = seq_of(A3)
    print(f"   bet (A3): status={r2 and r2['status']} {expl(e2)} seq={seqB} pool={bal(BR)/1e18:,.2f}")
    pool = bal(BR)
    hd, ed = send(BR, "0x26792aca" + encode(["address", "uint256"], [OWNER, pool]).hex(), OWNER)
    rd = rc(hd) if hd else None
    print(f"   DRAIN 100%: status={rd and rd['status']} {expl(ed)}"
          f"  pool -> {bal(BR)/1e18:,.2f} MON  logs={len((rd or {}).get('logs', []))}")
    cash3 = bal(A3)
    e_call2 = call(RPS, cb_data(seqB), frm=ENT)[1]
    print(f"   callback eth_call pre-check -> {expl(e_call2)}")
    hc2, ec2 = send(RPS, cb_data(seqB), ENT)
    rcc2 = rc(hc2) if hc2 else None
    print(f"   settle: status={rcc2 and rcc2['status']} {expl(ec2)}")
    print(f"   player delta={(bal(A3)-cash3)/1e18:+,.2f} MON  pool={bal(BR)/1e18:,.2f}")
    st = call(RPS, "0xcfea2f6f" + "0" * 24 + A3[2:].lower())[0]
    words = [int(st[2:][i * 64:(i + 1) * 64], 16) for i in range(len(st[2:]) // 64)] if st else None
    print(f"   GetState(A3) still awaiting? {words} (word4=1 means the request never settled)")
    out["drain"] = {"bet_status": r2 and r2["status"], "drain_status": rd and rd["status"],
                    "drain_logs": len((rd or {}).get("logs", [])),
                    "precheck": expl(e_call2), "settle_status": rcc2 and rcc2["status"],
                    "player_delta": (bal(A3) - cash3) / 1e18, "state": words}

    json.dump(out, open(os.path.join(BASE, "fork", "v10-drain-ab.json"), "w"), indent=1)
    print("\nsaved fork/v10-drain-ab.json")


if __name__ == "__main__":
    main()
