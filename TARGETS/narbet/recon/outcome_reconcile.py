#!/usr/bin/env python3
"""nar.bet — Next-Step #3: reconcile REAL settled outcomes against the documented edge.

Free read-only work (no state change, no fork needed yet).

For each game proxy:
  * pull X_Outcome_Event logs over a recent window
  * sum wager vs payout  -> empirical RTP, compare to 9500/10000 edgeFactor
  * count X_Refund_Event and RefundCommitmentCreated -> the refund-race tell
  * measure Entropy sequenceNumber gaps / min sequence (is randomness actually flying?)

Output: recon/outcome-reconcile.json
"""
import json, os, time, urllib.request
from eth_utils import keccak

RPC = "https://rpc.monad.xyz"
OUT = os.path.expanduser("~/.hermes/workspace/SAVAGEAUD/TARGETS/narbet/recon")

GAMES = {
    "Mines": "0x3014d056Db789984552084Db359D7C56A620549b",
    "CoinFlip": "0xb82360d08784f0Ff24A740ADaD6b1AC2391C8D57",
    "Roulette": "0x4A050DD00c08856cc3d7C5BD152E4e601ffDaa35",
    "Plinko": "0x5859E2926750F3981f95bbA16b86d8e69cf4334B",
    "Slots": "0xd6F08aF222C8aa69F99B6099F93C6d96897d378f",
    "Limbo": "0xb9e0b5447B92eb5CF246693F7b533d5c84AA8dC5",
    "VideoPoker": "0xb86A1955E96147665d7bdd70E50bD6Af38E086d1",
    "RockPaperScissors": "0x843D62ad75F5d0b383f8520e23d19174b7961b8E",
    "Baccarat": "0x8261A173DC96e206b8D8621ca1231a3E7bcB851E",
    "FishPrawnCrab": "0xbbE3FA39912355C49Aa3ccdD02C51d989Fb33E79",
}

_id = 0
def rpc(method, params, timeout=30):
    global _id
    _id += 1
    body = json.dumps({"jsonrpc": "2.0", "id": _id, "method": method, "params": params}).encode()
    req = urllib.request.Request(RPC, data=body, headers={"Content-Type": "application/json"})
    for attempt in range(3):
        try:
            r = json.loads(urllib.request.urlopen(req, timeout=timeout).read())
            if "error" in r:
                return None, r["error"]
            return r.get("result"), None
        except Exception as e:
            if attempt == 2:
                return None, str(e)
            time.sleep(1.5)


def split_top(s):
    """Split an ABI inputs string on top-level commas."""
    out, depth, cur = [], 0, ""
    for ch in s:
        if ch in "([":
            depth += 1
        elif ch in ")]":
            depth -= 1
        if ch == "," and depth == 0:
            out.append(cur.strip()); cur = ""
        else:
            cur += ch
    if cur.strip():
        out.append(cur.strip())
    return out


def canon_type(part):
    """'uint256 wager' -> 'uint256'. Returns None when a tuple type is involved."""
    toks = part.split()
    if len(toks) >= 2 and toks[0].startswith("tuple"):
        return None
    t = toks[0] if toks else part
    if "tuple" in t:
        return None
    return t


def topic0(name, inputs_str):
    types = []
    for p in split_top(inputs_str):
        t = canon_type(p)
        if t is None:
            return None
        types.append(t)
    return "0x" + keccak(text=f"{name}({','.join(types)})").hex()


def main():
    abi = json.load(open(os.path.join(OUT, "abi-real.json")))
    events = abi["events"]

    # Build topic map per game
    topics = {}   # topic0 -> (game, kind)
    for g in GAMES:
        for kind, evname in (("outcome", f"{g}_Outcome_Event"), ("refund", f"{g}_Refund_Event")):
            s = events.get(evname)
            if not s:
                continue
            t = topic0(evname, s["inputs"])
            topics[t] = (g, kind, evname, s["inputs"])
    # shared
    t_commit = topic0("RefundCommitmentCreated", events["RefundCommitmentCreated"]["inputs"])
    topics[t_commit] = ("*", "commit", "RefundCommitmentCreated",
                        events["RefundCommitmentCreated"]["inputs"])

    head, err = rpc("eth_blockNumber", [])
    if err:
        print("head error", err); return
    head = int(head, 16)
    print("head", head)

    # probe the getLogs range limit with the shared commit topic (all games)
    span = 50000
    logs = None
    while span >= 500:
        got, err = rpc("eth_getLogs", [{"fromBlock": hex(head - span), "toBlock": hex(head),
                                        "topics": [t_commit]}])
        if err is None:
            logs = got
            print(f"getLogs OK at span {span} -> {len(got)} commit logs")
            break
        print(f"span {span} rejected: {str(err)[:120]}")
        span //= 2
    if logs is None:
        print("NO USABLE RANGE — getLogs blocked; report honestly")
        return

    print(f"window: {head-span}..{head} ({span} blocks)")

    # now pull per-topic for the same window
    result = {"head": head, "from": head - span, "span": span, "commit_logs": len(logs),
              "games": {}}
    for t, (g, kind, evname, inputs) in topics.items():
        if kind == "commit":
            continue
        got, err = rpc("eth_getLogs", [{"fromBlock": hex(head - span), "toBlock": hex(head),
                                        "topics": [t], "address": GAMES[g]}])
        if err is not None:
            result["games"].setdefault(g, {})[kind] = {"error": str(err)[:160]}
            continue
        result["games"].setdefault(g, {})[kind] = {"n": len(got), "topic0": t, "ev": evname}

    with open(os.path.join(OUT, "outcome-reconcile.json"), "w") as f:
        json.dump(result, f, indent=1)
    for g, d in result["games"].items():
        print(g, {k: v.get("n") for k, v in d.items()})

    # decode the non-tuple outcome events properly in a second pass
    print("\n--- second pass: decode wager/payout for non-tuple outcome events ---")
    for t, (g, kind, evname, inputs) in topics.items():
        if kind != "outcome":
            continue
        parts = split_top(inputs)
        types = [canon_type(p) for p in parts]
        if any(x is None for x in types):
            print(f"{g}: tuple event, skipped from decode ({inputs[:60]}...)")
            continue
        got, err = rpc("eth_getLogs", [{"fromBlock": hex(head - span), "toBlock": hex(head),
                                        "topics": [t], "address": GAMES[g]}])
        if err or not got:
            continue
        # decode only static leading fields: address player, uint256 wager, uint256 payout
        # data word layout (non-indexed assumed): word0=player, word1=wager, word2=payout
        W = int(10000); tw = tp = 0; ns = 0
        seqs = []
        for lg in got:
            data = lg["data"][2:]
            words = [data[i:i+64] for i in range(0, len(data), 64)]
            if len(words) < 3:
                continue
            try:
                wa = int(words[1], 16) / 1e18
                pa = int(words[2], 16) / 1e18
            except Exception:
                continue
            tw += wa; tp += pa; ns += 1
            try:
                seqs.append(int(words[-1], 16))
            except Exception:
                pass
        if ns:
            rtp = (tp / tw) if tw else 0
            print(f"{g}: n={ns} wagered={tw:.4f} payout={tp:.4f} RTP={rtp:.4f} "
                  f"(expected {0.95}) seq min/max={min(seqs) if seqs else '-'}/{max(seqs) if seqs else '-'}")
            result["games"].setdefault(g, {})["reconcile"] = {
                "n": ns, "wagered": tw, "payout": tp, "rtp": rtp,
                "seq_min": min(seqs) if seqs else None, "seq_max": max(seqs) if seqs else None}

    with open(os.path.join(OUT, "outcome-reconcile.json"), "w") as f:
        json.dump(result, f, indent=1)
    print("\nsaved", os.path.join(OUT, "outcome-reconcile.json"))


if __name__ == "__main__":
    main()
