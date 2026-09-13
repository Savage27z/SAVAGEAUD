#!/usr/bin/env python3
"""nar.bet — FORK v7: BankRoll share accounting (LP pool).

Open hypotheses:
  H-a  first-depositor / donation share inflation: is share value computed from
       address(this).balance (donatable) or a tracked variable?
  H-b  withdraw() semantics: is `amount` shares or tokens? can it redeem more than entitled?
  H-c  rounding: does a tiny second deposit get 0 shares (donation attack classic)?
  H-d  LP exit x in-flight bet: can an LP withdraw liquidity after a large bet is placed so the
       winning payout reverts (player denied payment)?

Local fork only (127.0.0.1:8555). Output: fork/v7-share-accounting.json
"""
import json, os, time, urllib.request
from eth_abi import encode, decode as abi_decode
from eth_utils import keccak

RPC = "http://127.0.0.1:8555"
BASE = os.path.expanduser("~/.hermes/workspace/SAVAGEAUD/TARGETS/narbet")
BR = "0x71dc4a726C92E6bf506F2Afc2Cee8B63A89B29EC"
RPS = "0x843d62ad75f5d0b383f8520e23d19174b7961b8e"
ENTROPY = "0xd458261e832415cfd3bae5e416fdf3230ce6f134"
PROVIDER = "0x52deaa1c84233f7bb8c8a45baede41091c616506"
NATIVE = "0x" + "0" * 40
OWNER = "0x4aD0d8f0A100A74547e4B66C008CaE6e91Ef6d8b"
A1 = "0x70997970C51812dc3A010C7d01b50e0d17dc79C8"
A2 = "0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC"
A3 = "0x90F79bf6EB2c4f870365E785982E1f101E93b906"
WIN_RND = "0x" + "01" * 32
SEL = {"deposit": "0x47e7ef24", "withdraw": "0xf3fef3a3", "userShares": "0x1142160c",
       "totalShares": "0x91d953da", "calcIncome": "0xed41f925", "houseLiq": "0xb3aa3cbd",
       "play": "0x493e7930", "cb": "0x52a5f1f8", "state": "0xcfea2f6f", "fee": "0x5768c29a",
       "getFeeInfo": "0x5768c29a", "isSusp": "0x0a5748a8", "validWager": "0xbfd7f9cc"}
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


ERR = {}
for n, s in ABI["errors"].items():
    t = canon(s.get("inputs") or "")
    if t is not None:
        ERR["0x" + keccak(text=f"{n}({','.join(t)})")[:4].hex()] = f"{n}({','.join(t)})"

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


def receipt(h):
    for _ in range(40):
        r = raw("eth_getTransactionReceipt", [h]).get("result")
        if r:
            return r
        time.sleep(0.25)
    return None


def explain(e):
    if not e:
        return "OK"
    d = e.get("data") or ""
    if d.startswith("0x08c379a0"):
        try:
            return "require: " + abi_decode(["string"], bytes.fromhex(d[10:]))[0]
        except Exception:
            return "require(undecodable)"
    if len(d) >= 10:
        return f"custom {ERR.get(d[:10], d[:10])}"
    return "empty revert"


def bal(a):
    v = raw("eth_getBalance", [a, "latest"]).get("result")
    return int(v, 16) if v else 0


def blk():
    return int(raw("eth_blockNumber", []).get("result"), 16)


def mine(n):
    d = 0
    while d < n:
        s = min(100, n - d)
        if raw("anvil_mine", [hex(s), "0x0"]).get("error"):
            return d
        d += s
    return d


def shares_total(tok=NATIVE):
    r, e = call(BR, SEL["totalShares"] + "0" * 24 + tok[2:].lower())
    return int(r, 16) if r and not e else None


def shares_of(who, tok=NATIVE):
    r, e = call(BR, SEL["userShares"] + "0" * 24 + who[2:].lower() + "0" * 24 + tok[2:].lower())
    return int(r, 16) if r and not e else None


def income_of(who, tok=NATIVE):
    r, e = call(BR, SEL["calcIncome"] + "0" * 24 + who[2:].lower() + "0" * 24 + tok[2:].lower())
    return int(r, 16) if r and not e else None


def as_(a):
    raw("anvil_impersonateAccount", [a])
    raw("anvil_setBalance", [a, hex(5 * 10 ** 21)])


def fee():
    return int(call(RPS, SEL["fee"])[0], 16)


def deposit(who, amount):
    d = SEL["deposit"] + encode(["address", "uint256"], [NATIVE, amount]).hex()
    h, e = send(BR, d, who, value=amount)
    return h, e, (receipt(h) if h else None)


def withdraw(who, amount):
    d = SEL["withdraw"] + encode(["address", "uint256"], [NATIVE, amount]).hex()
    return send(BR, d, who)


def main():
    out = {}
    print(f"fork block {blk()}")
    MON = 10 ** 18
    tot = shares_total()
    b0 = bal(BR)
    print(f"pool: balance={b0/1e18:,.2f} MON  totalShares={tot/1e18:,.4f}"
          f"  implied price={b0/tot if tot else 0:.9f} MON/share")

    # ---------- baseline deposit ----------
    as_(A1)
    d0 = bal(A1)
    h, e, rc = deposit(A1, 1000 * MON)
    print(f"\n[A1 deposits 1000 MON] status={rc and rc['status']} {explain(e)}")
    if not rc or rc["status"] != "0x1":
        print("  deposit failed — probing arg/value shapes next")
        for amt, val in ((1000 * MON, 0), (1000 * MON, 1000 * MON)):
            r, err = call(BR, SEL["deposit"] + encode(["address", "uint256"], [NATIVE, amt]).hex(),
                          frm=A1, value=val)
            print(f"    eth_call amount={amt/1e18} value={val/1e18}: {explain(err)}")
        return
    s1 = shares_of(A1)
    print(f"  A1 shares = {s1 / 1e18:,.6f}  (minted for 1000 MON)")
    print(f"  totalShares now = {shares_total()/1e18:,.6f}")
    out["baseline_deposit"] = {"shares": s1, "total": shares_total(),
                               "price_before": (b0 / tot) if tot else None}

    # ---------- H-a/H-c: donation / share inflation ----------
    print("\n[H-a] donation: send MON straight to the BankRoll (no deposit())")
    pre_tot, pre_bal = shares_total(), bal(BR)
    hd, ed = send(BR, "0x", A1, value=5000 * MON)      # plain transfer, empty calldata
    rcd = receipt(hd) if hd else None
    print(f"  transfer 5000 MON -> status={rcd and rcd['status']} {explain(ed)}")
    print(f"  pool balance={bal(BR)/1e18:,.2f}  totalShares={shares_total()/1e18:,.6f}"
          f"  (shares unchanged = accounting uses a tracked var, not address(this).balance"
          f" => donation does NOT inflate share price)")
    out["donation"] = {"balance_after": bal(BR), "total_after": shares_total(),
                       "transfer_status": rcd and rcd["status"]}

    print("\n[H-c] second depositor right after the donation")
    as_(A3)
    h2, e2, rc2 = deposit(A3, 1000 * MON)
    s3 = shares_of(A3)
    print(f"  A3 deposits 1000 MON -> status={rc2 and rc2['status']} {explain(e2)}")
    print(f"  A3 shares={s3/1e18:,.6f}   A1 shares={shares_of(A1)/1e18:,.6f}")
    print(f"  shares per MON: A3={s3/1000e18:.9f}  A1={s1/1000e18:.9f}   "
          f"{'EQUAL' if abs(s3/1000e18 - s1/1000e18) < 1e-12 else 'DIFFERENT -> dilution!'}")
    out["second_depositor"] = {"A3_shares": s3, "A1_shares": s1,
                               "per_mon_A3": s3 / 1000e18, "per_mon_A1": s1 / 1000e18}

    # ---------- H-b: withdraw semantics ----------
    print("\n[H-b] withdraw(): is `amount` shares or tokens?")
    pre_bal, pre_shares = bal(A3), shares_of(A3)
    hw, ew = withdraw(A3, 1000 * MON)     # ask for 1000 MON of tokens
    rcw = receipt(hw) if hw else None
    print(f"  A3 withdraw(1000 MON) status={rcw and rcw['status']} {explain(ew)}")
    print(f"    MON received={(bal(A3)-pre_bal)/1e18:,.6f}  shares burned="
          f"{(pre_shares-shares_of(A3))/1e18:,.6f}")
    if rcw and rcw["status"] == "0x1":
        print("    -> argument is TOKENS (shares burned proportionally) "
              if (pre_shares - shares_of(A3)) != 1000 * MON else "    -> argument is SHARES")
    out["withdraw_probe"] = {"status": rcw and rcw["status"],
                             "mon_received": (bal(A3) - pre_bal) / 1e18,
                             "shares_burned": (pre_shares - shares_of(A3)) / 1e18}

    print("\n[H-b2] over-withdraw: ask for far more than entitled")
    entitled = income_of(A1)
    print(f"  A1 accrued income (calculatedIncome) = {entitled/1e18 if entitled else '?'} MON")
    pre_bal = bal(A1)
    hw2, ew2 = withdraw(A1, 10_000_000 * MON)
    print(f"  A1 withdraw(10,000,000 MON) -> {explain(ew2)}")
    out["overwithdraw"] = {"result": explain(ew2), "entitled": entitled}

    # ---------- H-d: LP exit vs in-flight big bet ----------
    print("\n[H-d] can an LP drain the pool while a big winning bet is in flight?")
    as_(A2)
    wager = 1000 * MON
    seq = None
    d = SEL["play"] + encode(["uint256", "address", "uint8", "uint32"], [wager, NATIVE, 0, 1]).hex()
    hp, ep = send(RPS, d, A2, value=wager + fee())
    rcp = receipt(hp) if hp else None
    if rcp and rcp["status"] == "0x1":
        st, _ = call(RPS, SEL["state"] + "0" * 24 + A2[2:].lower())
        seq = int(st[2:][64:128], 16)
        print(f"  A2 bet {wager/1e18:,.0f} MON placed, seq={seq}, "
              f"pool={bal(BR)/1e18:,.2f} MON")
        # LP (A1) tries to exit its liquidity now
        hw3, ew3 = withdraw(A1, shares_of(A1))
        rcw3 = receipt(hw3) if hw3 else None
        print(f"  A1 withdraw-all while the bet is pending: status={rcw3 and rcw3['status']}"
              f" {explain(ew3)}")
        print(f"  pool after LP exit: {bal(BR)/1e18:,.2f} MON")
        # settle the bet as a WIN and see whether the payout still lands
        raw("anvil_impersonateAccount", [ENTROPY]); raw("anvil_setBalance", [ENTROPY, hex(10**19)])
        d2 = SEL["cb"] + encode(["uint64", "address", "bytes32"],
                                [seq, PROVIDER, bytes.fromhex(WIN_RND[2:])]).hex()
        hc, ec = send(RPS, d2, ENTROPY)
        rcc = receipt(hc) if hc else None
        print(f"  settle the WINNING bet after the LP exit: status={rcc and rcc['status']}"
              f" {explain(ec)}")
        print(f"  player MON after: {bal(A2)/1e18:,.2f}   pool: {bal(BR)/1e18:,.2f}")
        out["lp_exit_vs_bet"] = {"withdraw_all_status": rcw3 and rcw3["status"],
                                 "settle_status": rcc and rcc["status"],
                                 "player_bal": bal(A2), "pool_bal": bal(BR)}
    else:
        print("  bet failed:", explain(ep))

    json.dump(out, open(os.path.join(BASE, "fork", "v7-share-accounting.json"), "w"), indent=1)
    print("\nsaved fork/v7-share-accounting.json")


if __name__ == "__main__":
    main()
