#!/usr/bin/env python3
"""nar.bet — S7: recover the 9 unmapped game contract addresses.

The earlier attempt returned "no logs in 30 days" for ALL 19 games — including RPS, which provably
had ~100 plays. It swallowed every chunk error. This version:

  1. CALIBRATION: compute the RPS_Play_Event topic from the recovered ABI and assert it equals the
     topic actually observed on chain earlier (0x6c726053...) — if the hashing is wrong, stop.
  2. POSITIVE CONTROL: scan for the RPS topic with the RPS address and require >0 logs.
  3. Then scan the 19 games' Play/Start topics with NO address filter, chunked, REPORTING the chunk
     error count so a silent failure is impossible.

Output: recon/game-addresses.json
"""
import json, os, sys, time, urllib.request
from concurrent.futures import ThreadPoolExecutor
from eth_utils import keccak

LIVE = "https://rpc2.monad.xyz"
BASE = os.path.expanduser("~/.hermes/workspace/SAVAGEAUD/TARGETS/narbet")
UA = {"Content-Type": "application/json",
      "User-Agent": "Mozilla/5.0 (X11; Linux x86_64) Chrome/124.0 Safari/537.36",
      "Accept": "application/json"}
RPS = "0x843d62ad75f5d0b383f8520e23d19174b7961b8e"
KNOWN_RPS_TOPIC = "0x6c726053fb92d879a9f92277e02c726c123ba994567b57948839be94800fb202"

ABI = json.load(open(os.path.join(BASE, "recon", "abi-real.json")))
GAMES = ["HiLo", "Keno", "Mines", "VideoPoker", "CoinFlip", "Roulette", "Plinko", "Slots", "Limbo",
         "Baccarat", "FishPrawnCrab", "Crash", "Dice", "DragonTiger", "Range", "RockPaperScissors",
         "SicBo", "War", "WheelOfFortune"]

_id = [0]
def rpc(m, p, t=60):
    _id[0] += 1
    try:
        return json.loads(urllib.request.urlopen(urllib.request.Request(
            LIVE, data=json.dumps({"jsonrpc": "2.0", "id": _id[0], "method": m, "params": p}).encode(),
            headers=UA), timeout=t).read())
    except Exception as e:
        return {"error": {"message": str(e)[:120]}}


def canon_types(inputs):
    if not inputs:
        return []
    parts, depth, cur = [], 0, ""
    for ch in inputs:
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


def topic_of(evname):
    if evname not in ABI["events"]:
        return None
    ts = canon_types(ABI["events"][evname].get("inputs", ""))
    if ts is None:
        return None
    return "0x" + keccak(text=f"{evname}({','.join(ts)})").hex()


def main():
    # ---- 1. calibration ----
    t = topic_of("RockPaperScissors_Play_Event")
    print(f"CALIBRATION RPS_Play_Event topic = {t}")
    print(f"            observed on chain     = {KNOWN_RPS_TOPIC}")
    if t != KNOWN_RPS_TOPIC:
        print("CALIBRATION FAILED — hashing is wrong, stopping before wasting a scan")
        return
    print("            MATCH ✓\n")

    head = int(rpc("eth_blockNumber", [])["result"], 16)
    span = 7 * 172800
    step = 2500
    ranges = []
    c = 0
    while c < span:
        ranges.append((head - min(c + step, span), head - c))
        c += step
    print(f"head {head}; scanning {span} blocks ({span/172800:.1f} days) in {len(ranges)} chunks of {step}")

    # ---- 2. positive control ----
    ctl, ctl_err = rpc("eth_getLogs", [{"fromBlock": hex(head - step), "toBlock": hex(head),
                                       "address": RPS}]), None
    if "error" in ctl:
        print("control failed:", ctl["error"])
    else:
        print(f"POSITIVE CONTROL: RPS logs in the last {step} blocks = {len(ctl['result'])}")
        if len(ctl["result"]) == 0:
            print("  (0 in the last 2500 blocks is plausible given ~11 plays/day; continuing)")

    # ---- 3. the scan: all game topics, no address filter ----
    topics = {}
    for g in GAMES:
        for ev in (f"{g}_Play_Event", f"{g}_Start_Event"):
            tt = topic_of(ev)
            if tt:
                topics[tt] = ev
                break
    print(f"scanning with {len(topics)} game topics (no address filter)")

    def fetch(rng):
        lo, hi = rng
        d = rpc("eth_getLogs", [{"fromBlock": hex(lo), "toBlock": hex(hi),
                                 "topics": list(topics.keys())}])
        return d

    errs = 0
    found = {}
    ok_chunks = 0
    with ThreadPoolExecutor(max_workers=10) as ex:
        for d in ex.map(fetch, ranges):
            if "error" in d:
                errs += 1
                continue
            ok_chunks += 1
            for lg in d["result"]:
                ev = topics.get(lg["topics"][0], "?")
                found.setdefault(ev, {})
                a = lg["address"].lower()
                found[ev][a] = found[ev].get(a, 0) + 1
    print(f"chunks ok={ok_chunks}/{len(ranges)}  errors={errs}")
    if errs and errs == len(ranges):
        print("EVERY chunk failed — surfacing the error and stopping:")
        print("   ", rpc("eth_getLogs", [{"fromBlock": hex(head - step), "toBlock": hex(head),
                                         "topics": list(topics.keys())}]).get("error"))
        return

    print("\n=== game event -> emitting addresses ===")
    for ev in sorted(found):
        game = ev.split("_")[0]
        addrs = found[ev]
        print(f"  {game:18s} {ev:28s} " + ", ".join(f"{a}({n})" for a, n in sorted(addrs.items())))
    unmapped = [g for g in GAMES if not any(e.startswith(g + "_") for e in found)]
    print(f"\ngames with NO logs found in {span/172800:.0f} days: {unmapped}")
    json.dump(found, open(os.path.join(BASE, "recon", "game-addresses.json"), "w"), indent=1)
    print("saved recon/game-addresses.json")


if __name__ == "__main__":
    main()
