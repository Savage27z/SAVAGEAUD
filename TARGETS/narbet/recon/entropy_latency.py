#!/usr/bin/env python3
"""nar.bet — Entropy latency probe (top hypothesis #1: the refund race).

Measures the real block-latency between Pyth Entropy `Requested` and `Revealed`
for nar.bet's own game contracts, then compares it to
REFUND_COMMIT_WAIT_BLOCKS() = 20 (the anti-abort guard).

Attack shape under test:
  a player commits a refund (claimableBlock = N + 20). If the reveal lands
  AFTER that block, the player can refund ... but that alone is not profit.
  The profitable shape is the reverse: reveal lands INSIDE the window and the
  player can still see the random number before the settle tx is mined, or the
  reveal latency can be forced past the wait window by an attacker.

Uses rpc2.monad.xyz (rpc.monad.xyz rate-limits and 413s everything).
Output: recon/entropy-latency.json
"""
import json, os, sys, urllib.request, time
from collections import Counter, defaultdict
from eth_utils import keccak

RPC = "https://rpc2.monad.xyz"
OUT = os.path.expanduser("~/.hermes/workspace/SAVAGEAUD/TARGETS/narbet/recon")
UA = {"Content-Type": "application/json",
      "User-Agent": "Mozilla/5.0 (X11; Linux x86_64) Chrome/124.0 Safari/537.36",
      "Accept": "application/json"}

ENTROPY = "0xd458261e832415cfd3bae5e416fdf3230ce6f134"

GAMES = {
    "Mines": "0x3014d056db789984552084db359d7c56a620549b",
    "CoinFlip": "0xb82360d08784f0ff24a740adad6b1ac2391c8d57",
    "Roulette": "0x4a050dd00c08856cc3d7c5bd152e4e601ffdaa35",
    "Plinko": "0x5859e2926750f3981f95bba16b86d8e69cf4334b",
    "Slots": "0xd6f08af222c8aa69f99b6099f93c6d96897d378f",
    "Limbo": "0xb9e0b5447b92eb5cf246693f7b533d5c84aa8dc5",
    "VideoPoker": "0xb86a1955e96147665d7bdd70e50bd6af38e086d1",
    "RockPaperScissors": "0x843d62ad75f5d0b383f8520e23d19174b7961b8e",
    "Baccarat": "0x8261a173dc96e206b8d8621ca1231a3e7bcb851e",
    "FishPrawnCrab": "0xbbe3fa39912355c49aa3ccdd02c51d989fb33e79",
}

_id = [0]
def rpc(method, params, timeout=90):
    _id[0] += 1
    body = json.dumps({"jsonrpc": "2.0", "id": _id[0], "method": method, "params": params}).encode()
    req = urllib.request.Request(RPC, data=body, headers=UA)
    for att in range(3):
        try:
            d = json.loads(urllib.request.urlopen(req, timeout=timeout).read())
            if "error" in d:
                return None, d["error"]
            return d.get("result"), None
        except Exception as e:
            if att == 2:
                return None, str(e)
            time.sleep(1.5)


T_REQUESTED = "0x" + keccak(text="Requested(address,address,uint64,bytes32,uint32)").hex()
T_REVEALED = "0x" + keccak(text="Revealed(address,address,uint64,bytes32)").hex()


def scan(span):
    head, err = rpc("eth_blockNumber", [])
    if err:
        return None, err, None
    head = int(head, 16)
    out = {}
    for label, topic in (("requested", T_REQUESTED), ("revealed", T_REVEALED)):
        logs, err = rpc("eth_getLogs", [{"fromBlock": hex(head - span), "toBlock": hex(head),
                                        "address": ENTROPY, "topics": [topic]}])
        if err:
            return None, f"{label}: {err}", head
        out[label] = logs
    return out, None, head


def main():
    span = int(sys.argv[1]) if len(sys.argv) > 1 else 2_000_000
    # calibration: does the Entropy address even have code / these events?
    code, err = rpc("eth_getCode", [ENTROPY, "latest"])
    print("entropy codesize:", len(code) // 2 if code else code, err)
    print("T_REQUESTED", T_REQUESTED)
    print("T_REVEALED ", T_REVEALED)

    res, err, head = scan(span)
    if err:
        print("SCAN FAILED:", err)
        return
    req, rev = res["requested"], res["revealed"]
    print(f"head {head} span {span} ({span*0.5/3600:.1f}h): requested={len(req)} revealed={len(rev)}")

    # positive control: entropy must show SOME traffic, else the probe is void
    if not req or not rev:
        print("NO ENTROPY TRAFFIC FOUND — probe void; report honestly, widen range")
        return

    # sequenceNumber is topic index 3 for both (provider, caller, sequenceNumber indexed)
    req_by_seq = {}
    req_by_caller = Counter()
    for lg in req:
        try:
            seq = int(lg["topics"][3], 16)
            caller = "0x" + lg["topics"][2][-40:]
        except Exception:
            continue
        req_by_seq[seq] = {"block": int(lg["blockNumber"], 16), "caller": caller}
        req_by_caller[caller] += 1

    rev_by_seq = {}
    for lg in rev:
        try:
            seq = int(lg["topics"][3], 16)
        except Exception:
            continue
        rev_by_seq[seq] = {"block": int(lg["blockNumber"], 16)}

    lat = []
    ours = []
    per_game = defaultdict(list)
    for seq, r in req_by_seq.items():
        v = rev_by_seq.get(seq)
        if not v:
            continue
        d = v["block"] - r["block"]
        lat.append(d)
        if r["caller"].lower() in GAMES.values():
            g = [k for k, x in GAMES.items() if x == r["caller"].lower()][0]
            ours.append(d)
            per_game[g].append(d)

    import statistics
    def stats(xs):
        if not xs:
            return None
        xs = sorted(xs)
        return {"n": len(xs), "min": xs[0], "p50": statistics.median(xs),
                "p90": xs[int(len(xs) * 0.9) - 1 if len(xs) > 1 else 0],
                "max": xs[-1], "mean": round(statistics.mean(xs), 2)}

    print("\nALL callers latency (blocks):", stats(lat))
    print("nar.bet callers latency  :", stats(ours))
    for g, xs in sorted(per_game.items(), key=lambda kv: -len(kv[1])):
        print(f"   {g:18s} n={len(xs)} {stats(xs)}")
    print("\ntop callers:", req_by_caller.most_common(8))
    print("nar.bet caller share:", sum(c for k, c in req_by_caller.items() if k in GAMES.values()),
          "/", len(req))

    # the refund-race verdict inputs
    out = {"head": head, "span": span, "entropy": ENTROPY,
           "n_requested": len(req), "n_revealed": len(rev),
           "latency_all": stats(lat), "latency_narbet": stats(ours),
           "per_game": {g: stats(xs) for g, xs in per_game.items()},
           "top_callers": req_by_caller.most_common(10),
           "REFUND_COMMIT_WAIT_BLOCKS": 20}
    if lat:
        over = sum(1 for d in lat if d > 20)
        out["reveals_slower_than_commit_wait_all"] = f"{over}/{len(lat)}"
    if ours:
        over = sum(1 for d in ours if d > 20)
        out["reveals_slower_than_commit_wait_narbet"] = f"{over}/{len(ours)}"
        print(f"\nVERDICT INPUT: reveals slower than the 20-block commit wait "
              f"(nar.bet): {over}/{len(ours)}")
    with open(os.path.join(OUT, "entropy-latency.json"), "w") as f:
        json.dump(out, f, indent=1)
    print("saved recon/entropy-latency.json")


if __name__ == "__main__":
    main()
