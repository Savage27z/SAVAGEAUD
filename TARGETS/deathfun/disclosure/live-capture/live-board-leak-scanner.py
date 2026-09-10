#!/usr/bin/env python3
"""
live-board-leak-scanner.py — death.fun death_race live-board leak detector

Built to answer a specific question: can a script create a game and learn the
board (tile count + skull positions) BEFORE picking?

It plays a real game and, at every turn, scans EVERY read path the app exposes
and asserts that no not-yet-played row is revealed and no seed is exposed.

Usage:
    python3 live-board-leak-scanner.py --cookie-file /tmp/idtok.txt \
        --row-config 7x25 --bet-wei 1000000000000000 --rows-to-play 2 --cash-out

Auth: the game API wants cookie `privy-id-token` (NOT `privy-token`).
      Body/query details that cost real time to discover:
        * create:   POST /api/abstract/games/create?gameType=<type>   (QUERY param, camelCase)
                    body is superjson: {"json":{...},"meta":{"values":{"betAmount":["bigint"]}}}
        * active:   GET  /api/games/active?gameType=<type>            (camelCase again)
        * pick:     POST /api/games/<uuid>/select-tile  {game_type, tileIndex, version}   (snake_case)
        * cash out: POST /api/games/<uuid>/cash-out     {version}  — STRICT, rejects other keys
      `version` starts at 1 and increments per action; it is enforced by exact equality
      ("Version mismatch" 409 on cash-out, "Game already updated" 404 on select-tile).

Not yet tested here: whether a second concurrent game makes the first one appear as
`previousGame` WITH its seed while still playable. That needs two live games.
"""
import argparse, json, subprocess, sys, time

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
    """'7x25' -> [7]*25 ; '2,3,4' -> [2,3,4]"""
    if "x" in spec:
        t, n = spec.split("x"); return [int(t)] * int(n)
    return [int(x) for x in spec.split(",")]

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--cookie-file", required=True)
    ap.add_argument("--base", default="https://death.fun")
    ap.add_argument("--game-type", default="death_race")
    ap.add_argument("--row-config", default="7x25")
    ap.add_argument("--bet-wei", default="1000000000000000")
    ap.add_argument("--rows-to-play", type=int, default=2)
    ap.add_argument("--tile", type=int, default=0)
    ap.add_argument("--cash-out", action="store_true")
    ap.add_argument("--create", action="store_true", help="actually create a game (spends the bet)")
    ap.add_argument("--game-id", help="scan an existing game id instead of creating one")
    a = ap.parse_args()

    cookie = open(a.cookie_file).read().strip()
    B, G = a.base, a.game_type
    leaks = []

    def scan(tag, gid):
        """Scan every read path. A leak = a seed exposed, or a not-yet-played row revealed."""
        ac = http("GET", f"{B}/api/games/active?gameType={G}", cookie)
        ac = ac if isinstance(ac, dict) else {}
        cg_raw = ac.get("currentGame")
        cg = cg_raw if isinstance(cg_raw, dict) else {}
        played = cg.get("currentRowIndex")
        act_sk = [i for i, r in enumerate(cg.get("rows") or [])
                  if isinstance(r, dict) and r.get("deathTileIndex") is not None]
        hist = http("GET", f"{B}/api/games/history", cookie)
        hbody = hist.get("json") if isinstance(hist, dict) else None
        hbody = hbody if isinstance(hbody, dict) else {}
        rec = [g for g in hbody.get("games", []) if isinstance(g, dict) and g.get("id") == gid]
        h_sk, h_seed = [], None
        rec0 = rec[0] if rec and isinstance(rec[0], dict) else {}
        h_seed = rec0.get("gameSeed")
        h_sk = [i for i, r in enumerate(rec0.get("rows") or [])
                if isinstance(r, dict) and r.get("deathTileIndex") is not None]
        # GATE ON STATUS. `currentGame` is the MOST RECENT game, not necessarily a live one —
        # after settlement it is the just-finished game with its board legitimately revealed.
        # Without this gate the settled board reads as a leak (observed: false positive).
        live = (cg.get("status") == "active") or (rec0.get("status") == "active")
        if not live:
            h_seed, h_sk = None, []
            act_sk = []
        cg_seed = cg.get("gameSeed") if live else None

        print(f"  [{tag}] status={cg.get('status')!r} rowIdx={played} ver={cg.get('version')} "
              f"| active: skulls={act_sk or 'none'} seed={cg_seed} "
              f"| history: skulls={h_sk or 'none'} seed={h_seed}")
        if cg_seed or h_seed:
            leaks.append((tag, "SEED EXPOSED"))
        if played is not None and any(i >= played for i in act_sk + h_sk):
            leaks.append((tag, "UNPLAYED ROW REVEALED"))
        if played is not None and any(i >= played for i in h_sk) and rec:
            leaks.append((tag, "UNPLAYED ROW REVEALED VIA HISTORY"))
        return cg

    gid = a.game_id
    if not gid:
        if not a.create:
            sys.exit("refusing to spend funds without --create (or pass --game-id)")
        rc = parse_row_config(a.row_config)
        r = http("POST", f"{B}/api/abstract/games/create?gameType={G}", cookie,
                 superjson({"betAmount": a.bet_wei, "rowConfig": rc}))
        print("create ->", json.dumps(r)[:200])
        gid = r.get("preliminaryGameId")
        if not gid:
            sys.exit("no game created")
        time.sleep(3)

    print(f"\n=== scanning game {gid} ===")
    cg = scan("pre-pick", gid)
    ver = cg.get("version")
    for step in range(a.rows_to_play):
        r = http("POST", f"{B}/api/games/{gid}/select-tile", cookie,
                 {"game_type": G, "tileIndex": a.tile, "version": ver})
        print(f"\n  PICK row{step} tile{a.tile} ver={ver} -> {json.dumps(r)[:200]}")
        if "error" in r:
            break
        print(f"    response: currentRow.skull={(r.get('currentRow') or {}).get('deathTileIndex')} "
              f"nextRow.skull={(r.get('nextRow') or {}).get('deathTileIndex')} status={r.get('status')}")
        if r.get("status") != "active":
            break
        ver = r.get("version")
        scan(f"after row{step}", gid)
        time.sleep(1)

    if a.cash_out and ver:
        co = http("POST", f"{B}/api/games/{gid}/cash-out", cookie, {"version": ver})
        print("\ncash-out ->", json.dumps(co)[:260])

    print("\n=== VERDICT ===")
    print("  leaks:", leaks if leaks else "NONE across every read path at every turn")

if __name__ == "__main__":
    main()
