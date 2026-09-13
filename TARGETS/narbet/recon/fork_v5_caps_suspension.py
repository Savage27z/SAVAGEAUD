#!/usr/bin/env python3
"""nar.bet — FORK v5: (A) can a bet exceed what the pool can pay, (B) does suspension lock funds?

A. RPS riskCap()=10000 (100%) while Mines/Range sit at 270/275. BankRoll holds ~527,754 MON.
   If riskCap caps the max payout as a share of bankroll, 100% means one bet may be entitled to
   the entire pool. Binary-search the largest wager the game accepts, then hand that bet a
   WINNING outcome and see whether the pool actually pays it.

B. Suspension (`suspend(uint256)` / `permantlyBan()` are BankRoll-only selectors) is the
   funds_locked_dos family: if a suspended player cannot receive a winning payout or claim a
   refund, the operator can strand a player's money mid-bet.

Local fork only (127.0.0.1:8555). Output: fork/v5-caps-and-suspension.json
"""
import json, os, sys, time, urllib.request
from eth_abi import encode, decode as abi_decode
from eth_utils import keccak

RPC = "http://127.0.0.1:8555"
BASE = os.path.expanduser("~/.hermes/workspace/SAVAGEAUD/TARGETS/narbet")
OUT = os.path.join(BASE, "fork")
RPS = "0x843d62ad75f5d0b383f8520e23d19174b7961b8e"
BANKROLL = "0x71dc4a726C92E6bf506F2Afc2Cee8B63A89B29EC"
ENTROPY = "0xd458261e832415cfd3bae5e416fdf3230ce6f134"
PROVIDER = "0x52deaa1c84233f7bb8c8a45baede41091c616506"
NATIVE = "0x0000000000000000000000000000000000000000"
OWNER = "0x4aD0d8f0A100A74547e4B66C008CaE6e91Ef6d8b"
ACCT0 = "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"
WIN_RND = "0x" + "01" * 32
SEL = {"play": "0x493e7930", "refund": "0x0f0aa179", "state": "0xcfea2f6f",
       "cb": "0x52a5f1f8", "fee": "0x5768c29a",
       "isSuspended": "0x0a5748a8", "suspend": "0x4b865846", "ban": "0xf59b7f71",
       "lift": "0x3d9f0e52", "br_owner": "0x893d20e8", "validWager": "0xbfd7f9cc",
       "riskCap": "0x2f836f8d", "houseLiq": "0xb3aa3cbd"}

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
    out = []
    for p in parts:
        t = p.split()[0] if p.split() else p
        if t.startswith("tuple"):
            return None
        out.append(t)
    return out


ERRORS = {}
for n, s in ABI["errors"].items():
    t = canon(s.get("inputs") or "")
    if t is not None:
        ERRORS["0x" + keccak(text=f"{n}({','.join(t)})")[:4].hex()] = (n, t)

_id = [0]
def rpc(method, params, timeout=90):
    _id[0] += 1
    try:
        d = json.loads(urllib.request.urlopen(urllib.request.Request(
            RPC, data=json.dumps({"jsonrpc": "2.0", "id": _id[0], "method": method,
                                  "params": params}).encode(),
            headers={"Content-Type": "application/json"}), timeout=timeout).read())
    except Exception as e:
        return {"code": -1, "message": str(e)[:150]}
    return d["error"] if "error" in d else d.get("result")


def call(to, data, frm=ACCT0, value=0):
    return rpc("eth_call", [{"from": frm, "to": to, "data": data, "value": hex(value)}, "latest"])


def send(to, data, frm, value=0):
    h = rpc("eth_sendTransaction", [{"from": frm, "to": to, "data": data, "value": hex(value)}])
    return (None, h) if isinstance(h, dict) and h.get("code") else (h, None)


def receipt(h):
    for _ in range(40):
        r = rpc("eth_getTransactionReceipt", [h])
        if r:
            return r
        time.sleep(0.25)
    return None


def bal(a):
    v = rpc("eth_getBalance", [a, "latest"])
    return int(v, 16) if isinstance(v, str) else 0


def blk():
    for _ in range(5):
        r = rpc("eth_blockNumber", [])
        if isinstance(r, str):
            return int(r, 16)
        time.sleep(0.4)
    raise RuntimeError("no block")


def mine(n=1):
    done = 0
    while done < n:
        step = min(100, n - done)
        r = rpc("anvil_mine", [hex(step), "0x0"])
        if isinstance(r, dict):
            return done
        done += step
    return done


def mine_to(t):
    g = 0
    while blk() < t and g < 300:
        mine(100); g += 1
    return blk()


def decode_err(res):
    if isinstance(res, dict) and ("code" in res or "message" in res):
        e = res
    elif isinstance(res, dict) and res.get("error"):
        e = res["error"]
    else:
        return ("OK", [])
    data = e.get("data") if isinstance(e, dict) else ""
    if isinstance(data, dict):
        data = data.get("data", "")
    if not data or data == "0x" or len(data) < 10:
        return ("EMPTY_REVERT", [])
    n, t = ERRORS.get(data[:10], (f"unknown{data[:10]}", []))
    args = []
    if t:
        try:
            args = list(abi_decode(t, bytes.fromhex(data[10:])))
        except Exception:
            args = []
    return (n, args)


def uint(addr, key, types="", *args):
    """Call a getter. `key` is the SEL key, `types` the comma-separated arg types."""
    tl = [t for t in types.split(",") if t]
    d = SEL[key] + (encode(tl, list(args)).hex() if tl else "")
    return call(addr, d)


def state(p=ACCT0):
    r = call(RPS, SEL["state"] + "0" * 24 + p[2:].lower())
    if isinstance(r, dict):
        return r
    w = r[2:]
    return [int(w[i:i + 64], 16) for i in range(0, len(w), 64)]


def fee():
    return int(rpc("eth_call", [{"to": RPS, "data": SEL["fee"]}, "latest"]), 16)


def play_data(wager, num_bets=1, action=0):
    return SEL["play"] + encode(["uint256", "address", "uint8", "uint32"],
                                [wager, NATIVE, action, num_bets]).hex()


def play(wager, p=ACCT0, num_bets=1, action=0):
    d = play_data(wager, num_bets, action)
    h, e = send(RPS, d, p, value=wager * num_bets + fee())
    return h, e, (receipt(h) if h else None)


def deliver(seq, rnd=WIN_RND):
    rpc("anvil_impersonateAccount", [ENTROPY])
    rpc("anvil_setBalance", [ENTROPY, hex(10 ** 19)])
    d = SEL["cb"] + encode(["uint64", "address", "bytes32"],
                           [seq, PROVIDER, bytes.fromhex(rnd[2:])]).hex()
    h, e = send(RPS, d, ENTROPY)
    return h, e, (receipt(h) if h else None)


def main():
    out = {}
    F = fee()
    print(f"fork block {blk()}  getRandomFee={F/1e18} MON")
    print(f"BankRoll balance {bal(BANKROLL)/1e18:,.2f} MON")

    # ---------- A. how big a bet will the game accept? ----------
    rpc("anvil_setBalance", [ACCT0, hex(2 * 10 ** 24)])   # 2,000,000 MON of play money
    print(f"\n[A] max accepted wager (RPS, riskCap={int(uint(RPS,'riskCap'),16)}):")
    cands = [10 ** 18, 10 ** 19, 10 ** 20, 5 * 10 ** 20, 10 ** 21, 5 * 10 ** 21,
             10 ** 22, 10 ** 23, 2 * 10 ** 23, 5 * 10 ** 23, 10 ** 24, 19 * 10 ** 23]
    accepted = []
    for w in cands:
        name, args = decode_err(call(RPS, play_data(w), value=w + F))
        ok = name == "OK"
        print(f"    wager {w/1e18:>12,.0f} MON -> {'ACCEPTED' if ok else name+' '+str(args)}")
        if ok:
            accepted.append(w)
        out.setdefault("wager_probe", []).append({"wager": w, "result": name, "args": args})
    if not accepted:
        print("    nothing accepted — abort A"); return
    wmax = max(accepted)
    print(f"    largest accepted: {wmax/1e18:,.0f} MON  (max RPS payout ~1.9x = "
          f"{wmax*1.9/1e18:,.0f} MON vs pool {bal(BANKROLL)/1e18:,.0f} MON)")

    # place the largest accepted bet and hand it a WIN
    b0, br0 = bal(ACCT0), bal(BANKROLL)
    h, e, rc = play(wmax)
    if not rc or rc["status"] != "0x1":
        print("    bet failed:", e, decode_err({"code": 3, "data": ""})); return
    seq = state()[1]
    print(f"    bet placed seq={seq} blk={int(rc['blockNumber'],16)} cost={(wmax+F)/1e18:,.2f}")
    mine_to(blk() + 25)
    hc, ec, rcc = deliver(seq)
    st = state()
    paid = bal(ACCT0) - b0
    print(f"    callback status={rcc and rcc['status']}  balance delta={paid/1e18:+,.2f} MON")
    print(f"    BankRoll delta={(bal(BANKROLL)-br0)/1e18:+,.2f} MON")
    print(f"    GetState={st}")
    out["big_bet"] = {"wager": wmax, "payout_net": paid / 1e18,
                      "bankroll_delta": (bal(BANKROLL) - br0) / 1e18,
                      "callback_status": rcc and rcc["status"]}

    # ---------- B. suspension ----------
    print("\n[B] suspension x money movement")
    small = 10 * 10 ** 18
    h1, e1, rc1 = play(small)
    seq1 = state()[1]
    print(f"    bet {small/1e18:.0f} MON placed, seq={seq1}, blk={int(rc1['blockNumber'],16)}")

    rpc("anvil_impersonateAccount", [OWNER])
    rpc("anvil_setBalance", [OWNER, hex(10 ** 19)])
    hs, es = send(BANKROLL, SEL["suspend"] + encode(["uint256"], [86400]).hex(), OWNER)
    rcs = receipt(hs) if hs else None
    print(f"    suspend(86400) as owner: tx={hs} status={rcs and rcs['status']} err={es}")
    print(f"    isPlayerSuspended={int(uint(BANKROLL, 'isSuspended', 'address', ACCT0), 16)}")

    b1, br1 = bal(ACCT0), bal(BANKROLL)
    h2, e2, rc2 = deliver(seq1)
    print(f"    WINNING payout while SUSPENDED: tx status={rc2 and rc2['status']} err={e2}")
    print(f"    player delta={(bal(ACCT0)-b1)/1e18:+,.4f} MON   bankroll delta={(bal(BANKROLL)-br1)/1e18:+,.4f}")

    # refund while suspended
    h3, e3, rc3 = play(small)
    seq3 = state()[1]
    print(f"    second bet placed while suspended: status={rc3 and rc3['status']} err={e3} seq={seq3}")
    if rc3 and rc3["status"] == "0x1":
        b2 = bal(ACCT0)
        mine_to(blk() + 2010)
        hr1, er1 = send(RPS, SEL["refund"], ACCT0)
        rcr1 = receipt(hr1) if hr1 else None
        print(f"    refund commit while suspended: status={rcr1 and rcr1['status']} err={er1}")
        mine_to(blk() + 25)
        hr2, er2 = send(RPS, SEL["refund"], ACCT0)
        rcr2 = receipt(hr2) if hr2 else None
        print(f"    refund CLAIM while suspended: status={rcr2 and rcr2['status']} err={er2}"
              f"  balance delta={(bal(ACCT0)-b2)/1e18:+,.4f} MON")
        out["refund_while_suspended"] = {
            "commit_status": rcr1 and rcr1["status"], "claim_status": rcr2 and rcr2["status"],
            "balance_delta": (bal(ACCT0) - b2) / 1e18, "claim_err": er2}

    out["suspension"] = {"payout_while_suspended_status": rc2 and rc2["status"],
                         "payout_delta": (bal(ACCT0) - b1) / 1e18,
                         "bet_while_suspended": rc3 and rc3["status"]}
    json.dump(out, open(os.path.join(OUT, "v5-caps-and-suspension.json"), "w"), indent=1)
    print("\nsaved fork/v5-caps-and-suspension.json")


if __name__ == "__main__":
    main()
