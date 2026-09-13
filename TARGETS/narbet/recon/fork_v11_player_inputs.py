#!/usr/bin/env python3
"""nar.bet — FORK v11: player-supplied game state (OUTSIDER-reachable surface).

HiLo_Play(wager, token, uint8 currentCard, bool isHigher, uint32 numBets)
  - the player PASSES their own current card, while the next card comes from Entropy AFTERWARDS.
  - `InvalidCurrentCard(uint8)` exists, so *some* check is intended. What exactly?
Mines_Start(wager, token, uint8 numMines, bool[25] tiles, bool isCashout)
  - the player passes the tile array up front; the mine layout is only known once the random lands.
  - Question 1: is the board (mine positions) exposed to the player BEFORE they must decide?
  - Question 2: can a claimed reveal array be inconsistent with the actual board?

Local fork only. Output: fork/v11-player-inputs.json
"""
import json, os, time, urllib.request
from eth_abi import encode, decode as abi_decode
from eth_utils import keccak

FORK = "http://127.0.0.1:8555"
BASE = os.path.expanduser("~/.hermes/workspace/SAVAGEAUD/TARGETS/narbet")
BR = "0x71dc4a726C92E6bf506F2Afc2Cee8B63A89B29EC"
GAMES = {
    "HiLo": "0xb9e0b5447B92eb5CF246693F7b533d5c84AA8dC5",
    "Mines": "0x3014d056Db789984552084Db359D7C56A620549b",
    "VideoPoker": "0xb86A1955E96147665d7bdd70E50bD6Af38E086d1",
}
ENT = "0xd458261e832415cfd3bae5e416fdf3230ce6f134"
PROV = "0x52deaa1c84233f7bb8c8a45baede41091c616506"
NATIVE = "0x" + "0" * 40
A2 = "0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC"
SEL_PLAY_RPS = "0x493e7930"
ABI = json.load(open(os.path.join(BASE, "recon", "abi-real.json")))


def sigsel(name):
    """Canonical selector from the recovered ABI inputs (skips tuple-typed args)."""
    ins = ABI["functions"][name].get("inputs", "")
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
    for p in parts:
        t = p.split()[0] if p.split() else p
        if t.startswith("tuple"):
            return None, None
        types.append(t)
    return "0x" + keccak(text=f"{name}({','.join(types)})")[:4].hex(), types


ERR = {}
for n, s in ABI["errors"].items():
    ins = s.get("inputs") or ""
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
        ERR["0x" + keccak(text=f"{n}({','.join(tt)})")[:4].hex()] = f"{n}({','.join(tt)})"

_id = [0]
def rpc(m, p, t=90):
    _id[0] += 1
    try:
        return json.loads(urllib.request.urlopen(urllib.request.Request(
            FORK, data=json.dumps({"jsonrpc": "2.0", "id": _id[0], "method": m, "params": p}).encode(),
            headers={"Content-Type": "application/json"}), timeout=t).read())
    except Exception as e:
        return {"error": {"message": str(e)[:120]}}


def call(to, data, frm=A2, value=0):
    d = rpc("eth_call", [{"from": frm, "to": to, "data": data, "value": hex(value)}, "latest"])
    return d.get("result"), d.get("error")


def send(to, data, frm, value=0):
    d = rpc("eth_sendTransaction", [{"from": frm, "to": to, "data": data, "value": hex(value)}])
    return d.get("result"), d.get("error")


def rc(h):
    for _ in range(40):
        r = rpc("eth_getTransactionReceipt", [h]).get("result")
        if r:
            return r
        time.sleep(0.25)
    return None


def bal(a):
    v = rpc("eth_getBalance", [a, "latest"]).get("result")
    return int(v, 16) if v else 0


def expl(e):
    if not e:
        return "OK"
    d = e.get("data") or ""
    if d.startswith("0x08c379a0"):
        try:
            return "require: " + abi_decode(["string"], bytes.fromhex(d[10:]))[0]
        except Exception:
            return "require?"
    if len(d) >= 10:
        return f"custom {ERR.get(d[:10], d[:10])}"
    return f"empty revert ({e.get('message')})"


def main():
    MON = 10 ** 18
    out = {}
    rpc("anvil_impersonateAccount", [A2]); rpc("anvil_setBalance", [A2, hex(1000 * MON)])
    fee = int(call(GAMES["HiLo"], "0x5768c29a")[0], 16)
    print(f"fork block {int(rpc('eth_blockNumber', []).get('result','0x0'),16)}  fee={fee/1e18}")

    print("\n=== HiLo: is the player-supplied currentCard validated? ===")
    sel, types = sigsel("HiLo_Play")
    print(f"  selector {sel} types={types}")
    for card in [0, 1, 8, 13, 52, 53, 60, 255]:
        data = sel + encode(types, [10 * MON, NATIVE, card, True, 1]).hex()
        r, e = call(GAMES["HiLo"], data, value=10 * MON + fee)
        print(f"    currentCard={card:3d} isHigher=True  -> "
              f"{'ACCEPTED' if not e else expl(e)}")
        out.setdefault("hilo_card_probe", []).append({"card": card, "err": expl(e)})

    print("\n=== Mines: is the board exposed before the player decides? ===")
    msel, mtypes = sigsel("Mines_Start")
    print(f"  Mines_Start selector {msel} types={mtypes}")
    tiles = [False] * 25
    tiles[0] = True                      # claim: reveal tile 0
    data = msel + encode(mtypes, [10 * MON, NATIVE, 3, tiles, False]).hex()
    h, e = send(GAMES["Mines"], data, A2, value=10 * MON + fee)
    r = rc(h) if h else None
    print(f"  Mines_Start(status={r and r['status']}) {expl(e)}")
    if r and r["status"] == "0x1":
        print(f"    logs: {[(l['topics'][0][:14], l['address'][:12]) for l in r['logs']]}")
        gs, ge = call(GAMES["Mines"], "0x" + keccak(text="Mines_GetState(address)")[:4].hex()
                      + "0" * 24 + A2[2:].lower())
        if ge:
            print("    Mines_GetState ->", expl(ge))
        else:
            w = gs[2:]
            words = [int(w[i * 64:(i + 1) * 64], 16) for i in range(len(w) // 64)]
            print(f"    Mines_GetState -> {len(words)} words: {words[:8]}{'...' if len(words)>8 else ''}")
            print("    (if the mine layout were readable here, the player could reveal only")
            print("     safe tiles AFTER the random landed -> guaranteed win)")
        print(f"    raw GetState hex (first 600): {gs[:600] if gs else None}")
        out["mines_state"] = {"raw": gs[:200] if gs else None}

    json.dump(out, open(os.path.join(BASE, "fork", "v11-player-inputs.json"), "w"), indent=1)
    print("\nsaved fork/v11-player-inputs.json")


if __name__ == "__main__":
    main()
