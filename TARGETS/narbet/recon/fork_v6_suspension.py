#!/usr/bin/env python3
"""nar.bet — FORK v6: whose suspension is it, and does self-exclusion actually work?

v5 showed `suspend(uint256)` succeeded when called by the BankRoll owner, yet
`isPlayerSuspended(player)` stayed 0 and the player's bet paid out normally. The function
takes **no address argument**, so the likely semantics are SELF-suspension (responsible
gambling / self-exclusion), not an admin ban. Calibrate which address the flag lands on,
then test whether the flag is actually enforced.

Questions:
  Q1 after owner calls suspend(86400), is OWNER suspended (self-service confirmed)?
  Q2 can a player self-suspend, and does that block Play?
  Q3 does an in-flight bet still settle and pay while suspended (funds lock check)?
  Q4 can the player un-suspend themselves immediately (is the exclusion meaningful)?
"""
import json, os, time, urllib.request
from eth_abi import encode, decode as abi_decode
from eth_utils import keccak

RPC = "http://127.0.0.1:8555"
BASE = os.path.expanduser("~/.hermes/workspace/SAVAGEAUD/TARGETS/narbet")
RPS = "0x843d62ad75f5d0b383f8520e23d19174b7961b8e"
BANKROLL = "0x71dc4a726C92E6bf506F2Afc2Cee8B63A89B29EC"
ENTROPY = "0xd458261e832415cfd3bae5e416fdf3230ce6f134"
PROVIDER = "0x52deaa1c84233f7bb8c8a45baede41091c616506"
NATIVE = "0x0000000000000000000000000000000000000000"
OWNER = "0x4aD0d8f0A100A74547e4B66C008CaE6e91Ef6d8b"
ACCT0 = "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"
ACCT1 = "0x70997970C51812dc3A010C7d01b50e0d17dc79C8"
WIN_RND = "0x" + "01" * 32
SEL = {"play": "0x493e7930", "refund": "0x0f0aa179", "state": "0xcfea2f6f",
       "cb": "0x52a5f1f8", "fee": "0x5768c29a", "isSuspended": "0x0a5748a8",
       "suspend": "0x4b865846", "ban": "0xf59b7f71", "lift": "0x3d9f0e52",
       "increase": "0x8177334f", "riskCap": "0x2f836f8d"}

_id = [0]
def rpc(m, p, t=90):
    _id[0] += 1
    try:
        d = json.loads(urllib.request.urlopen(urllib.request.Request(
            RPC, data=json.dumps({"jsonrpc": "2.0", "id": _id[0], "method": m, "params": p}).encode(),
            headers={"Content-Type": "application/json"}), timeout=t).read())
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
    d = 0
    while d < n:
        s = min(100, n - d)
        if isinstance(rpc("anvil_mine", [hex(s), "0x0"]), dict):
            return d
        d += s
    return d


def mine_to(t):
    g = 0
    while blk() < t and g < 300:
        mine(100); g += 1
    return blk()


def suspended(who):
    r = call(BANKROLL, SEL["isSuspended"] + "0" * 24 + who[2:].lower())
    if isinstance(r, dict):
        return f"ERR {r}"
    return int(r, 16)


def as_(addr):
    rpc("anvil_impersonateAccount", [addr])
    rpc("anvil_setBalance", [addr, hex(10 ** 20)])


def fee():
    return int(rpc("eth_call", [{"to": RPS, "data": SEL["fee"]}, "latest"]), 16)


def play_data(w, nb=1, act=0):
    return SEL["play"] + encode(["uint256", "address", "uint8", "uint32"], [w, NATIVE, act, nb]).hex()


def play(w, p=ACCT0, nb=1, act=0):
    h, e = send(RPS, play_data(w, nb, act), p, value=w * nb + fee())
    return h, e, (receipt(h) if h else None)


def lock(h, e):
    return ("OK" if h else f"REVERT {e.get('data','') if isinstance(e,dict) else e}")


def deliver(seq, rnd=WIN_RND):
    as_(ENTROPY)
    d = SEL["cb"] + encode(["uint64", "address", "bytes32"], [seq, PROVIDER, bytes.fromhex(rnd[2:])]).hex()
    h, e = send(RPS, d, ENTROPY)
    return h, e, (receipt(h) if h else None)


def state(p=ACCT0):
    r = call(RPS, SEL["state"] + "0" * 24 + p[2:].lower())
    if isinstance(r, dict):
        return r
    w = r[2:]
    return [int(w[i:i + 64], 16) for i in range(0, len(w), 64)]


def main():
    out = {}
    print(f"fork block {blk()}")
    F = fee()
    print(f"isPlayerSuspended before anything: acct0={suspended(ACCT0)} owner={suspended(OWNER)}")

    # ---- Q1: who does an owner-called suspend(86400) actually suspend? ----
    as_(OWNER)
    h, e = send(BANKROLL, SEL["suspend"] + encode(["uint256"], [86400]).hex(), OWNER)
    rc = receipt(h) if h else None
    print(f"\n[Q1] owner calls suspend(86400): status={rc and rc['status']} err={e}")
    print(f"     suspended now -> OWNER={suspended(OWNER)}  acct0={suspended(ACCT0)}  acct1={suspended(ACCT1)}")
    out["owner_called_suspend"] = {"status": rc and rc["status"],
                                  "owner_flag": suspended(OWNER), "acct0_flag": suspended(ACCT0)}

    # ---- Q2: player self-suspends; does Play get blocked? ----
    print("\n[Q2] acct1 self-suspends for 3600s")
    as_(ACCT1)
    h2, e2 = send(BANKROLL, SEL["suspend"] + encode(["uint256"], [3600]).hex(), ACCT1)
    rc2 = receipt(h2) if h2 else None
    print(f"     suspend tx status={rc2 and rc2['status']}  err={e2}")
    print(f"     suspended: acct1={suspended(ACCT1)} acct0={suspended(ACCT0)}")
    hp, ep, rcp = play(10 * 10 ** 18, p=ACCT1)
    print(f"     Play while self-suspended: status={rcp and rcp['status']} err={ep}")
    out["self_suspend"] = {"tx_status": rc2 and rc2["status"], "flag": suspended(ACCT1),
                           "play_status": rcp and rcp["status"]}
    trapped = None
    if rcp and rcp["status"] == "0x1":
        seq = state(ACCT1)[1]
        trapped = seq
        print(f"     -> a bet got IN while suspended, seq={seq}")

    # ---- Q3: in-flight bet while suspended: settle + pay? ----
    print("\n[Q3] in-flight settlement while suspended")
    hp2, ep2, rcp2 = play(10 * 10 ** 18, p=ACCT0)   # acct0 is NOT suspended -> control
    seq0 = state(ACCT0)[1]
    as_(ACCT0)
    h3, e3 = send(BANKROLL, SEL["suspend"] + encode(["uint256"], [3600]).hex(), ACCT0)
    rc3 = receipt(h3) if h3 else None
    print(f"     acct0 self-suspends with a bet in flight: status={rc3 and rc3['status']}"
          f"  flag={suspended(ACCT0)}")
    b0 = bal(ACCT0)
    hc, ec, rcc = deliver(seq0)
    print(f"     WINNING settle while suspended: status={rcc and rcc['status']}"
          f"  balance delta={(bal(ACCT0)-b0)/1e18:+,.4f} MON")
    out["settle_while_suspended"] = {"status": rcc and rcc["status"],
                                     "delta": (bal(ACCT0) - b0) / 1e18}

    # ---- Q4: can the player lift their own suspension? ----
    print("\n[Q4] self-lift")
    b1 = bal(ACCT0)
    h4, e4 = send(BANKROLL, SEL["lift"], ACCT0)
    rc4 = receipt(h4) if h4 else None
    print(f"     liftSuspension() as the suspended player: status={rc4 and rc4['status']} err={e4}")
    print(f"     flag after lift: acct0={suspended(ACCT0)}  acct1={suspended(ACCT1)}")
    hp3, ep3, rcp3 = play(10 * 10 ** 18, p=ACCT0)
    print(f"     Play after lift: status={rcp3 and rcp3['status']} err={ep3}")
    out["self_lift"] = {"status": rc4 and rc4["status"], "flag_after": suspended(ACCT0),
                        "play_after_status": rcp3 and rcp3["status"]}

    # ---- permantlyBan on a player: self-only? can it be undone? ----
    print("\n[permantlyBan] as acct1 (already the caller's own account)")
    as_(ACCT1)
    h5, e5 = send(BANKROLL, SEL["ban"], ACCT1)
    rc5 = receipt(h5) if h5 else None
    print(f"     permantlyBan() status={rc5 and rc5['status']} err={e5} flag={suspended(ACCT1)}")
    h6, e6 = send(BANKROLL, SEL["lift"], ACCT1)
    rc6 = receipt(h6) if h6 else None
    print(f"     then liftSuspension() status={rc6 and rc6['status']} flag={suspended(ACCT1)}")
    out["permanent_ban"] = {"ban_status": rc5 and rc5["status"], "flag_after_ban": suspended(ACCT1),
                            "lift_status": rc6 and rc6["status"], "flag_after_lift": suspended(ACCT1)}

    json.dump(out, open(os.path.join(BASE, "fork", "v6-suspension.json"), "w"), indent=1)
    print("\nsaved fork/v6-suspension.json")


if __name__ == "__main__":
    main()
