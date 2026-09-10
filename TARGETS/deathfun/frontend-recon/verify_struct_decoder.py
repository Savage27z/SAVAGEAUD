import importlib.util, json
from Crypto.Hash import keccak
spec = importlib.util.spec_from_file_location(
    "rd", "/root/.hermes/workspace/SAVAGEAUD/TARGETS/deathfun/disclosure/live-demo/replay_demo.py")
rd = importlib.util.module_from_spec(spec); spec.loader.exec_module(rd)

def k(b):
    h = keccak.new(digest_bits=256); h.update(b); return h.hexdigest()

topic0 = "0x" + k(b"GameCreated(string,uint256,address,uint256,bytes32)")
gc = int(rd.call(rd.CONTRACT, rd.selector("gameCounter()")), 16)

# sample real games spread across history
ids = [gc - 1, gc - 2, gc - 10, gc - 100, gc - 1000, gc - 100000, 500000, 200000, 100000, 50000, 10000, 1000]
print(f"gameCounter = {gc}; cross-checking {len(ids)} games against the GameCreated event oracle\n")
ok = bad = skip = 0
for gid in ids:
    if gid <= 0:
        continue
    logs = rd.rpc("eth_getLogs", [{"address": rd.CONTRACT, "fromBlock": "0x0", "toBlock": "latest",
                                   "topics": [topic0, "0x" + rd.enc_uint(gid)]}])
    if not logs:
        print(f"  game {gid:>8}: no GameCreated log (skip)"); skip += 1; continue
    lg = logs[0]
    ev_player = "0x" + lg["topics"][2][-40:]
    d = bytes.fromhex(lg["data"][2:])
    ev_bet = int.from_bytes(d[32:64], "big")
    try:
        st = rd.game_state_full(gid)
    except Exception as e:
        print(f"  game {gid:>8}: decoder error {str(e)[:60]}"); bad += 1; continue
    pm = st["player"].lower() == ev_player.lower()
    bm = st["betAmount_wei"] == ev_bet
    flag = "MATCH" if (pm and bm) else "MISMATCH"
    if pm and bm: ok += 1
    else: bad += 1
    print(f"  game {gid:>8}: {flag:8} player={'ok' if pm else st['player']+' != '+ev_player} "
          f"bet={'ok' if bm else str(st['betAmount_wei'])+' != '+str(ev_bet)} "
          f"status={st['status']} algo={st['algoVersion']!r} cfgLen={len(st['gameConfig'])}")

print(f"\n  matched {ok} / mismatched {bad} / skipped {skip}")
print("  --> decoder verified against an independent on-chain oracle" if bad == 0 else "  --> DECODER STILL WRONG")
