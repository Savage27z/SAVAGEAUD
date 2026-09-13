#!/usr/bin/env python3
"""nar.bet — calibrate topic0 -> event name, then measure real Entropy latency.

Step 1: match observed topic0s against hashes computed from the recovered ABI,
        and against Pyth Entropy V2 variants. A topic that fails to match is a
        detector failure -> must be reported, never guessed.
Step 2: chunked wide scan (rpc2 caps getLogs at 29999 blocks) over the game
        proxies + the Entropy proxy, correlating Requested/Revealed by sequence.

Output: recon/topic-labels.json, recon/entropy-latency-wide.json
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
EXTRA = {"BankRoll": "0x71dc4a726c92e6bf506f2afc2cee8b63a89b29ec",
         "config209": "0x0b1e533e33f9e82849e71fb5c0a33f38462d5ed4"}
ALLADDR = list(GAMES.values()) + list(EXTRA.values())

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
            time.sleep(1.2 * (att + 1))


def split_top(s):
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


def topic_of(name, inputs_str):
    types = []
    for p in split_top(inputs_str):
        t = p.split()[0] if p.split() else p
        if t.startswith("tuple"):
            return None
        types.append(t)
    return "0x" + keccak(text=f"{name}({','.join(types)})").hex()


ENTROPY_CANDIDATES = {
    "RequestedWithCallback(address,address,uint64,bytes32,bytes32)": None,
    "RevealedWithCallback(address,address,uint64,bytes32,bytes32)": None,
    "Requested(address,address,uint64,bytes32,uint32)": None,
    "Revealed(address,address,uint64,bytes32)": None,
    "CallbackFailed(address,address,uint64)": None,
    "ProviderFeeUpdated(address,uint128)": None,
    "DefaultGasLimitUpdated(uint32)": None,
    "Paused(address)": None,
    "Unpaused(address)": None,
}
for k in ENTROPY_CANDIDATES:
    ENTROPY_CANDIDATES[k] = "0x" + keccak(text=k).hex()


def label(obs_topics, abi_events):
    """Return {topic0: name} for observed topics, using computed hashes only."""
    labels = {}
    computed = {}
    for n, s in abi_events.items():
        t = topic_of(n, s["inputs"])
        if t:
            computed[t] = n
    computed.update({v: k for k, v in ENTROPY_CANDIDATES.items()})
    for t in obs_topics:
        labels[t] = computed.get(t, "UNMATCHED")
    return labels, computed


def main(days=14):
    abi = json.load(open(os.path.join(OUT, "abi-real.json")))
    head, err = rpc("eth_blockNumber", [])
    if err:
        print("head fail", err); return
    head = int(head, 16)
    per_day = 172800  # 0.5s blocks
    span = days * per_day
    chunks = []
    c = 0
    while c < span:
        lo = head - min(c + 29999, span)
        hi = head - c
        chunks.append((lo, hi))
        c += 29999
    print(f"head {head} span {span} ({days}d) chunks {len(chunks)}")

    def one_batch(addr_set):
        res = []
        def fn(rng):
            lo, hi = rng
            got, e = rpc("eth_getLogs", [{"fromBlock": hex(lo), "toBlock": hex(hi),
                                          "address": addr_set}])
            return got, e
        with ThreadPoolExecutor(max_workers=10) as ex:
            for got, e in ex.map(fn, chunks):
                if e:
                    res.append((None, e))
                else:
                    res.extend((lg, None) for lg in got)
        return res

    t0 = time.time()
    game_logs = [x for x, e in one_batch(ALLADDR) if x]
    print(f"game/anchor logs: {len(game_logs)} in {time.time()-t0:.1f}s")
    t0 = time.time()
    ent_logs = [x for x, e in one_batch([ENTROPY_PROXY]) if x]
    print(f"entropy proxy logs: {len(ent_logs)} in {time.time()-t0:.1f}s")

    obs = set()
    for lg in game_logs + ent_logs:
        if lg.get("topics"):
            obs.add(lg["topics"][0])
    labels, computed = label(obs, abi["events"])
    print("\n--- observed topics labelled from computed hashes ---")
    for t, n in labels.items():
        cnt = sum(1 for lg in game_logs + ent_logs if lg["topics"] and lg["topics"][0] == t)
        who = Counter(lg["address"].lower() for lg in game_logs + ent_logs
                      if lg["topics"] and lg["topics"][0] == t)
        rev = {v: k for k, v in {**GAMES, **EXTRA}.items()}
        print(f"  {t} {n:45s} n={cnt} [{','.join(rev.get(a,a[:12]) for a in list(who)[:4])}]")

    unsupported = [n for n, s in abi["events"].items() if topic_of(n, s["inputs"]) is None]
    print(f"\nABI events not canonicalisable (tuple types, skipped): {len(unsupported)}")

    out = {"head": head, "days": days, "labels": labels,
           "counts": {t: sum(1 for lg in game_logs + ent_logs
                             if lg["topics"] and lg["topics"][0] == t) for t in labels},
           "game_logs": len(game_logs), "entropy_logs": len(ent_logs),
           "n_unmatchable_abi_events": len(unsupported)}
    with open(os.path.join(OUT, "topic-labels.json"), "w") as f:
        json.dump(out, f, indent=1)

    # ---- Entropy latency, using whichever Requested/Revealed names matched ----
    req_t = [t for t, n in labels.items() if n and n.startswith("Requested")]
    rev_t = [t for t, n in labels.items() if n and n.startswith("Revealed")]
    print("\nrequested topics:", req_t, "revealed topics:", rev_t)
    if req_t and rev_t:
        reqs, revs = {}, {}
        for lg in ent_logs:
            try:
                if lg["topics"][0] in req_t:
                    reqs[int(lg["topics"][3], 16)] = (int(lg["blockNumber"], 16),
                                                      "0x" + lg["topics"][2][-40:])
                elif lg["topics"][0] in rev_t:
                    revs[int(lg["topics"][3], 16)] = int(lg["blockNumber"], 16)
            except Exception:
                continue
        lat, ours, per_game = [], [], defaultdict(list)
        rev_g = {v: k for k, v in GAMES.items()}
        for seq, (blk, caller) in reqs.items():
            if seq in revs:
                d = revs[seq] - blk
                lat.append(d)
                if caller.lower() in rev_g:
                    ours.append(d); per_game[rev_g[caller.lower()]].append(d)
        def st(xs):
            if not xs:
                return None
            xs = sorted(xs)
            return {"n": len(xs), "min": xs[0], "p50": statistics.median(xs),
                    "p90": xs[max(0, int(len(xs) * 0.9) - 1)], "max": xs[-1],
                    "mean": round(statistics.mean(xs), 2)}
        print("ALL callers:", st(lat))
        print("nar.bet    :", st(ours))
        for g, xs in sorted(per_game.items(), key=lambda kv: -len(kv[1])):
            print("   ", g, st(xs))
        wide = {"head": head, "days": days, "n_req": len(reqs), "n_rev": len(revs),
                "latency_all": st(lat), "latency_narbet": st(ours),
                "per_game": {g: st(xs) for g, xs in per_game.items()},
                "commit_wait_blocks": 20,
                "narbet_reveals_over_commit_wait": (sum(1 for d in ours if d > 20) if ours else None)}
        with open(os.path.join(OUT, "entropy-latency-wide.json"), "w") as f:
            json.dump(wide, f, indent=1)
        print("saved recon/entropy-latency-wide.json")
    else:
        print("could not identify both Requested and Revealed topics -> latency UNMEASURED")


if __name__ == "__main__":
    main(int(sys.argv[1]) if len(sys.argv) > 1 else 14)
