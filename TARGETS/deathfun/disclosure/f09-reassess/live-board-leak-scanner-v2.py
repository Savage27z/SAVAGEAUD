#!/usr/bin/env python3
"""
live-board-leak-scanner-v2.py — death.fun live-board leak detector, CORRECTED.

Why v2 exists: v1 (disclosure/live-capture/live-board-leak-scanner.py) parses only
`currentGame` and `history`. It never reads `previousGame` — which is precisely the shape
F08 left open ("does a second concurrent game make the first appear as previousGame with
its seed while still playable?"). The v1 verdict "leaks: NONE across every read path" was
therefore silent about that shape rather than negative on it.

F09-d demonstrated the blind spot with a local mock: an ACTIVE game with its seed and all
25 skulls planted in `previousGame` produced "leaks: NONE" from v1, while the identical
leak planted in `currentGame` was caught. A detector that cannot fire on a shape returns
NONE for that shape regardless of the truth.

v2 changes:
  1. parses `previousGame` as a first-class read path (gated on status == "active")
  2. factors detection into a PURE function `detect_leaks(...)`
  3. ships `--self-test`: three fixtures (secure / leak-current / leak-previous) that
     assert the detector fires on each leak shape and stays quiet on the secure one

Rule for a reportable leak: an ACTIVE game exposes `gameSeed`, or an unplayed row's
`deathTileIndex`. Completed games legitimately reveal both, so every check is gated on
status == "active".

Usage:
  python3 live-board-leak-scanner-v2.py --self-test
  python3 live-board-leak-scanner-v2.py --cookie-file /tmp/idtok.txt --game-id <uuid> --rows-to-play 2
  python3 live-board-leak-scanner-v2.py --cookie-file /tmp/idtok.txt --create --cash-out   # SPENDS the bet
"""
import argparse, json, subprocess, sys, time

# ---------------------------------------------------------------- pure detection


def _active(rec):
    return isinstance(rec, dict) and rec.get("status") == "active"


def _skulls(rec):
    return [i for i, r in enumerate(rec.get("rows") or [])
            if isinstance(r, dict) and r.get("deathTileIndex") is not None]


def detect_leaks(payload, history_payload, gid, tag=""):
    """Return a list of (tag, reason) leaks. PURE — no network. Gated on status=='active'.

    payload:          parsed body of GET /api/games/active  (may contain currentGame/previousGame)
    history_payload:  parsed body of GET /api/games/history
    """
    out = []
    payload = payload if isinstance(payload, dict) else {}
    games = []
    for slot in ("currentGame", "previousGame"):
        g = payload.get(slot)
        if isinstance(g, dict):
            g = dict(g); g["_slot"] = slot
            games.append(g)

    hbody = history_payload.get("json") if isinstance(history_payload, dict) else None
    hbody = hbody if isinstance(hbody, dict) else {}
    for g in (hbody.get("games") or []):
        if isinstance(g, dict) and (gid is None or g.get("id") == gid):
            g = dict(g); g["_slot"] = "history"
            games.append(g)

    for g in games:
        slot = g.get("_slot")
        if not _active(g):
            continue                       # completed disclosure is correct, not a leak
        if g.get("gameSeed"):
            out.append((tag, f"SEED EXPOSED via {slot}"))
        played = g.get("currentRowIndex")
        if played is None:
            played = sum(1 for r in (g.get("rows") or [])
                         if isinstance(r, dict) and r.get("deathTileIndex") is not None)
        future = [i for i in _skulls(g) if i >= played]
        if future:
            out.append((tag, f"UNPLAYED ROW REVEALED via {slot} (rows {future[:5]})"))
    return out


def describe(payload, history_payload, gid):
    lines = []
    payload = payload if isinstance(payload, dict) else {}
    for slot in ("currentGame", "previousGame"):
        g = payload.get(slot)
        if isinstance(g, dict):
            lines.append(f"{slot}: status={g.get('status')!r} rowIdx={g.get('currentRowIndex')} "
                         f"skulls={_skulls(g) or 'none'} seed={'SET' if g.get('gameSeed') else 'None'}")
        else:
            lines.append(f"{slot}: {g!r}")
    return " | ".join(lines)


# ---------------------------------------------------------------- network driver

def http(method, url, cookie, body=None, timeout=25):
    cmd = ["curl", "-s", "-m", str(timeout), "-X", method, url,
           "-H", "Content-Type: application/json", "-H", f"Cookie: privy-id-token={cookie}"]
    if body is not None:
        cmd += ["-d", json.dumps(body)]
    out = subprocess.run(cmd, capture_output=True, text=True).stdout
    try:
        return json.loads(out)
    except Exception:
        return {"_raw": out[:400]}


def superjson(obj, bigint_keys=("betAmount",)):
    return {"json": obj, "meta": {"values": {k: ["bigint"] for k in bigint_keys if k in obj}}}


def parse_row_config(spec, default_rows=25):
    if "x" in spec:
        t, n = spec.split("x"); return [int(t)] * int(n)
    return [int(x) for x in spec.split(",")]


def scan(tag, gid, B, G, cookie):
    payload = http("GET", f"{B}/api/games/active?gameType={G}", cookie)
    hist = http("GET", f"{B}/api/games/history", cookie)
    leaks = detect_leaks(payload, hist, gid, tag)
    print(f"  [{tag}] {describe(payload, hist, gid)}")
    print(f"         leaks: {leaks or 'none'}")
    return payload, leaks


# ---------------------------------------------------------------- self-test

FIXTURES = {
    "secure": (
        {"currentGame": {"status": "active", "currentRowIndex": 1, "gameSeed": None,
                         "rows": [{"deathTileIndex": 0}, {"deathTileIndex": None}]},
         "previousGame": {"status": "won", "currentRowIndex": 2, "gameSeed": "0xdead",
                          "rows": [{"deathTileIndex": 1}, {"deathTileIndex": 0}]}},
        {"json": {"games": [{"id": "g", "status": "active", "gameSeed": None,
                             "rows": [{"deathTileIndex": 0}, {"deathTileIndex": None}]}]}},
      0, False),
    "leak-current": (
        {"currentGame": {"status": "active", "currentRowIndex": 1, "gameSeed": "0xabc",
                         "rows": [{"deathTileIndex": 0}, {"deathTileIndex": 1}]}},
        {"json": {"games": []}},
      2, True),
    "leak-previous": (
        {"currentGame": {"status": "active", "currentRowIndex": 1, "gameSeed": None,
                         "rows": [{"deathTileIndex": 0}, {"deathTileIndex": None}]},
         "previousGame": {"status": "active", "currentRowIndex": 1, "gameSeed": "0xabc",
                          "rows": [{"deathTileIndex": 0}, {"deathTileIndex": 1}]}},
        {"json": {"games": []}},
      2, True),
}


def self_test():
    ok = True
    for name, (payload, hist, gid, should_fire) in FIXTURES.items():
        leaks = detect_leaks(payload, hist, gid, name)
        fired = bool(leaks)
        good = fired == should_fire
        ok &= good
        print(f"  [{'PASS' if good else 'FAIL'}] {name:14} expected_fire={should_fire} "
              f"fired={fired} -> {leaks}")
    print(f"\nSELF-TEST: {'ALL PASS' if ok else 'FAILURES PRESENT'}")
    return 0 if ok else 1


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--self-test", action="store_true")
    ap.add_argument("--cookie-file")
    ap.add_argument("--base", default="https://death.fun")
    ap.add_argument("--game-type", default="death_race")
    ap.add_argument("--row-config", default="7x25")
    ap.add_argument("--bet-wei", default="1000000000000000")
    ap.add_argument("--rows-to-play", type=int, default=2)
    ap.add_argument("--tile", type=int, default=0)
    ap.add_argument("--cash-out", action="store_true")
    ap.add_argument("--create", action="store_true", help="actually create a game (SPENDS the bet)")
    ap.add_argument("--game-id")
    a = ap.parse_args()

    if a.self_test:
        sys.exit(self_test())
    if not a.cookie_file:
        sys.exit("need --cookie-file (or --self-test)")

    cookie = open(a.cookie_file).read().strip()
    B, G = a.base, a.game_type
    all_leaks = []
    gid = a.game_id
    if not gid:
        if not a.create:
            sys.exit("refusing to spend funds without --create (or pass --game-id)")
        r = http("POST", f"{B}/api/abstract/games/create?gameType={G}", cookie,
                 superjson({"betAmount": a.bet_wei, "rowConfig": parse_row_config(a.row_config)}))
        print("create ->", json.dumps(r)[:200])
        gid = r.get("preliminaryGameId")
        if not gid:
            sys.exit("no game created")
        time.sleep(3)

    print(f"\n=== scanning game {gid} (current + previous + history) ===")
    cg, lk = scan("pre-pick", gid, B, G, cookie); all_leaks += lk
    ver = (cg.get("currentGame") or {}).get("version")
    for step in range(a.rows_to_play):
        r = http("POST", f"{B}/api/games/{gid}/select-tile", cookie,
                 {"game_type": G, "tileIndex": a.tile, "version": ver})
        print(f"\n  PICK row{step} tile{a.tile} ver={ver} -> {json.dumps(r)[:180]}")
        if "error" in r or r.get("status") != "active":
            break
        ver = r.get("version")
        _, lk = scan(f"after row{step}", gid, B, G, cookie); all_leaks += lk
        time.sleep(1)
    if a.cash_out and ver:
        print("\ncash-out ->", json.dumps(http("POST", f"{B}/api/games/{gid}/cash-out", cookie,
                                               {"version": ver}))[:260])

    print("\n=== VERDICT ===")
    print("  leaks:", all_leaks if all_leaks else "NONE on current/previous/history at every turn")
    sys.exit(1 if all_leaks else 0)


if __name__ == "__main__":
    main()
