#!/usr/bin/env python3
"""nar.bet — Entropy request->reveal latency CENSUS (hypothesis #1, the refund race).

Method (no signature guessing):
  * the 4 Entropy-proxy topics are UNMATCHED against every Pyth signature we hashed,
    so label them by *transaction origin* instead of by name:
      - tx `to` == Entropy proxy  -> reveal-side (provider fulfillment call)
      - tx `to` in game proxies   -> request-side (player action)
  * sequenceNumber is indexed in topics[3] for the 3-indexed-topic events, and is
    word 1 of the data for the single-topic event -> pair req/reveal by sequence.
  * latency = reveal_block - request_block, compared against
    REFUND_COMMIT_WAIT_BLOCKS() = 20.

Output: recon/entropy-race.json
"""
import json, os, sys, urllib.request, time, statistics
from collections import Counter, defaultdict
from concurrent.futures import ThreadPoolExecutor
from eth_utils import keccak

RPC = "https://rpc2.monad.xyz"
UA = {"Content-Type": "application/json",
      "User-Agent": "Mozilla/5.0 (X11; Linux x86_64) Chrome/124.0 Safari/537.36",
      "Accept": "application/json"}
OUT = os.path.expanduser("~/.hermes/workspace/SAVAGEAUD/TARGETS/narbet/recon")
ENTROPY_PROXY = "0xd458261e832415cfd3bae5e416fdf3230ce6f134"
COMMIT_WAIT = 20

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
    for att in range(4):
        try:
            d = json.loads(urllib.request.urlopen(urllib.request.Request(RPC, data=body, headers=UA),
                                                  timeout=timeout).read())
            if "error" in d:
                return None, d["error"]
            return d.get("result"), None
        except Exception as e:
            if att == 3:
                return None, str(e)
            time.sleep(1.0 * (att + 1))


def main(days=30):
    head, _ = rpc("eth_blockNumber", [])
    head = int(head, 16)
    span = days * 172800
    ranges = []
    c = 0
    while c < span:
        ranges.append((head - min(c + 29999, span), head - c))
        c += 29999
    print(f"head {head} days {days} chunks {len(ranges)}")

    def fetch(rng):
        lo, hi = rng
        got, err = rpc("eth_getLogs", [{"fromBlock": hex(lo), "toBlock": hex(hi),
                                        "address": ENTROPY_PROXY}])
        return got, err

    logs, errs = [], 0
    with ThreadPoolExecutor(max_workers=10) as ex:
        for got, err in ex.map(fetch, ranges):
            if err:
                errs += 1
                print("  chunk err:", str(err)[:80])
            else:
                logs.extend(got)
    print(f"entropy logs {len(logs)} (chunk errors {errs})")
    if not logs:
        print("VOID"); return

    by_topic = Counter(l["topics"][0] for l in logs)
    print("topic counts:", dict(by_topic))

    # receipts -> which side each log came from (tx `to`)
    uniq = sorted({l["transactionHash"] for l in logs})
    print("unique txs", len(uniq))
    recs = {}

    def getrec(h):
        r, e = rpc("eth_getTransactionReceipt", [h])
        return h, r, e

    with ThreadPoolExecutor(max_workers=16) as ex:
        for h, r, e in ex.map(getrec, uniq):
            if r:
                recs[h.lower()] = r
    print("receipts", len(recs))

    side_by_topic = defaultdict(Counter)
    reqs, revs = {}, {}
    ev_blocks = {}
    for l in logs:
        r = recs.get(l["transactionHash"].lower())
        if not r:
            continue
        to = (r.get("to") or "").lower()
        t = l["topics"][0]
        blk = int(l["blockNumber"], 16)
        if to == ENTROPY_PROXY.lower():
            side = "reveal"
        elif to in GAMES.values():
            side = "request"
        else:
            side = f"other:{to[:10]}"
        side_by_topic[t][side] += 1
        # sequence number: topics[3] for 4-topic logs, data word 1 for 1-topic logs
        try:
            if len(l["topics"]) >= 4:
                seq = int(l["topics"][3], 16)
            else:
                w = l["data"][2:]
                seq = int(w[64:128], 16)
        except Exception:
            continue
        if side == "request":
            reqs.setdefault(seq, []).append((blk, "0x" + l["topics"][2][-40:], t))
        elif side == "reveal":
            revs.setdefault(seq, []).append((blk, t))

    print("\n--- side by topic (from tx origin) ---")
    for t, c in side_by_topic.items():
        print(f"  {t} {dict(c)}")

    lat, per_game, game_lat = [], defaultdict(list), {}
    rev_g = {v: k for k, v in GAMES.items()}
    unpaired = 0
    for seq, rs in reqs.items():
        if seq not in revs:
            unpaired += 1
            continue
        rb = min(b for b, _, _ in rs)
        vb = min(b for b, _ in revs[seq])
        d = vb - rb
        lat.append(d)
        caller = rs[0][1].lower()
        g = rev_g.get(caller, caller[:10])
        per_game[g].append(d)

    def st(xs):
        if not xs:
            return None
        xs = sorted(xs)
        return {"n": len(xs), "min": xs[0], "p50": statistics.median(xs),
                "p90": xs[max(0, int(len(xs) * .9) - 1)], "p99": xs[max(0, int(len(xs) * .99) - 1)],
                "max": xs[-1], "mean": round(statistics.mean(xs), 2),
                "over_commit_wait": sum(1 for x in xs if x > COMMIT_WAIT)}

    print(f"\npaired {len(lat)} cycles, unpaired requests {unpaired}")
    print("latency (blocks) ALL:", st(lat))
    for g, xs in sorted(per_game.items(), key=lambda kv: -len(kv[1])):
        print(f"   {g:18s}", st(xs))

    out = {"head": head, "days": days, "n_logs": len(logs), "chunk_errors": errs,
           "topic_counts": dict(by_topic),
           "side_by_topic": {t: dict(c) for t, c in side_by_topic.items()},
           "n_cycles": len(lat), "unpaired_requests": unpaired,
           "latency_all": st(lat), "per_game": {g: st(x) for g, x in per_game.items()},
           "commit_wait_blocks": COMMIT_WAIT}
    with open(os.path.join(OUT, "entropy-race.json"), "w") as f:
        json.dump(out, f, indent=1)
    print("saved recon/entropy-race.json")


if __name__ == "__main__":
    main(int(sys.argv[1]) if len(sys.argv) > 1 else 30)
