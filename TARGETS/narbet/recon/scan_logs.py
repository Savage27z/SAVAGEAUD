#!/usr/bin/env python3
"""nar.bet — chunked getLogs scanner (this RPC rejects spans >~100 blocks).

Scans backward from head in 100-block chunks, all 15 known proxies in one address
list per call, no topic filter, and aggregates topic0 -> count + block range.
Positive control built in: WMON must return logs or the scanner reports INVALID.

Usage: scan_logs.py <n_chunks> [workers]
Output: recon/log-scan.json
"""
import json, os, sys, time, urllib.request
from collections import Counter, defaultdict
from concurrent.futures import ThreadPoolExecutor
from eth_utils import keccak

RPC = "https://rpc.monad.xyz"
OUT = os.path.expanduser("~/.hermes/workspace/SAVAGEAUD/TARGETS/narbet/recon")

PROXIES = {
    "BankRoll": "0x71dc4a726C92E6bf506F2Afc2Cee8B63A89B29EC",
    "config209": "0x0B1E533e33f9E82849E71fb5c0a33F38462D5eD4",
    "root149": "0xE6d461c863987F2a1096eA3476137F30f75B3d46",
    "registry149": "0xa4338eadf4D2e0851eFb225b0Eab90bE47A095F1",
    "resolver149": "0x314582158A0a72802aD8F6EeE6243C73dCf1F562",
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
WMON = "0x3bd359C1119dA7Da1D913D1C2B7c461115433A"

_id = [0]
def rpc(method, params, timeout=30):
    _id[0] += 1
    body = json.dumps({"jsonrpc": "2.0", "id": _id[0], "method": method, "params": params}).encode()
    req = urllib.request.Request(RPC, data=body, headers={"Content-Type": "application/json"})
    for att in range(3):
        try:
            d = json.loads(urllib.request.urlopen(req, timeout=timeout).read())
            if "error" in d:
                return None, d["error"]
            return d.get("result"), None
        except Exception as e:
            if att == 2:
                return None, str(e)
            time.sleep(1.0)


def chunk_logs(args):
    frm, to = args
    got, err = rpc("eth_getLogs", [{"fromBlock": hex(frm), "toBlock": hex(to),
                                    "address": list(PROXIES.values())}])
    return frm, to, got, err


def main():
    n_chunks = int(sys.argv[1]) if len(sys.argv) > 1 else 50
    workers = int(sys.argv[2]) if len(sys.argv) > 2 else 12
    head = int(rpc("eth_blockNumber", [])[0], 16)
    print("head", head, "chunks", n_chunks, "->", n_chunks * 100, "blocks of history")

    # positive control
    ctl, err = rpc("eth_getLogs", [{"fromBlock": hex(head - 100), "toBlock": hex(head),
                                    "address": WMON}])
    if err or not ctl:
        print("POSITIVE CONTROL FAILED — scanner invalid:", err)
        return
    print("control WMON logs in 100 blk:", len(ctl))

    ranges = []
    for i in range(n_chunks):
        to = head - i * 100
        ranges.append((to - 99, to))
    t0 = time.time()
    topic_ct = Counter()
    topic_first_seen = {}
    per_addr = Counter()
    addr_by_topic = defaultdict(Counter)
    errs = 0
    with ThreadPoolExecutor(max_workers=workers) as ex:
        for frm, to, got, err in ex.map(chunk_logs, ranges):
            if err:
                errs += 1
                continue
            for lg in got:
                t = lg["topics"][0] if lg.get("topics") else "none"
                topic_ct[t] += 1
                addr_by_topic[t][lg["address"].lower()] += 1
                per_addr[lg["address"].lower()] += 1
                b = int(lg["blockNumber"], 16)
                if t not in topic_first_seen or b < topic_first_seen[t]:
                    topic_first_seen[t] = b
    print(f"scanned in {time.time()-t0:.1f}s; chunk errors={errs}")
    print("total logs:", sum(topic_ct.values()))
    rev = {v.lower(): k for k, v in PROXIES.items()}
    for t, n in topic_ct.most_common(30):
        who = ",".join(f"{rev.get(a,a[:10])}:{c}" for a, c in addr_by_topic[t].most_common(3))
        print(f"  {t} n={n} firstBlk={topic_first_seen[t]} [{who}]")

    res = {"head": head, "n_chunks": n_chunks, "blocks": n_chunks * 100,
           "control_logs": len(ctl), "chunk_errors": errs,
           "topic_counts": dict(topic_ct), "topic_first_block": topic_first_seen,
           "per_address": dict(per_addr),
           "topic_addrs": {t: dict(c) for t, c in addr_by_topic.items()}}
    with open(os.path.join(OUT, "log-scan.json"), "w") as f:
        json.dump(res, f, indent=1)
    print("saved recon/log-scan.json")


if __name__ == "__main__":
    main()
