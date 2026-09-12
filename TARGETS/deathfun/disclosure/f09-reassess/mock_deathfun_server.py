#!/usr/bin/env python3
"""
mock_deathfun_server.py — LOCAL mock of the death.fun read/write surface, built to
give the live-board-leak scanner a POSITIVE CONTROL.

Why: F08 concluded "no mechanism found to read a board you have not played", but the
scanner that produced "leaks: NONE" parses only `currentGame` and `history`. It never
reads `previousGame` — which is exactly the shape F08 left open. A detector that
cannot fire on the shape you care about returns "NONE" regardless of the truth, so its
silence is not evidence.

This mock lets us plant each leak shape deliberately, locally, with no production
wager and no interference with live games.

Modes:
  secure         - nothing leaked anywhere (negative control: expect NONE)
  leak-current   - an ACTIVE currentGame exposes gameSeed + unplayed-row skulls
                   (positive control for the shape the scanner DOES parse)
  leak-previous  - an ACTIVE previousGame exposes gameSeed + unplayed-row skulls,
                   while currentGame is clean (the F08-open shape)

Run:  python3 mock_deathfun_server.py --mode leak-previous --port 8899
"""
import argparse, json, hashlib
from http.server import BaseHTTPRequestHandler, HTTPServer

GID = "1a06e1a5-6583-4737-b681-53c961ba3769"
SEED = "0x6d679f945aaa59b496d39c6817b899ffc904f7702671eab2cce8485b572caab2"
TILES = 25


def sha256_hex(s):
    return hashlib.sha256(s.encode()).hexdigest()


def dti(seed, i, tiles):
    return int(sha256_hex(f"{seed}-row{i}")[:8], 16) % tiles


def make_rows(played_rows, reveal_all=False):
    """Row objects. deathTileIndex populated for played rows only, unless reveal_all."""
    rows, cur = [], 1.0
    for i in range(TILES):
        tiles = 2
        cur *= 1 / (1 - 1 / tiles)
        if reveal_all or i < played_rows:
            idx = dti(SEED, i, tiles)
        else:
            idx = None
        rows.append({"tiles": tiles, "deathTileIndex": idx, "multiplier": round(cur * 0.96, 8)})
    return rows


def game_rec(status, seed, played, reveal_all=False):
    return {
        "id": GID, "walletAddress": "0x318f5353bab917b5243d78825875a247c90c8646",
        "createdAt": "2026-09-10 16:22:14.300264+00", "updatedAt": "2026-09-10 16:22:16.701943+00",
        "status": status, "betAmount": "1000000000000000", "potBalance": None,
        "usdUnitPrice": 2437.24, "currentRowIndex": played, "version": played + 1,
        "gameSeed": seed, "rows": make_rows(played, reveal_all),
    }


class Handler(BaseHTTPRequestHandler):
    mode = "secure"

    def log_message(self, *a):
        pass

    def _send(self, obj, code=200):
        b = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)

    def do_GET(self):
        p = self.path.split("?")[0]
        if p == "/api/games/active":
            # currentGame: ACTIVE, seed withheld, only played rows revealed
            cg = game_rec("active", None, 1, reveal_all=False)
            body = {"currentGame": cg}
            if self.mode == "leak-previous":
                # an UNFINISHED game occupying previousGame WITH seed and future rows
                body["previousGame"] = game_rec("active", SEED, 1, reveal_all=True)
            elif self.mode == "leak-current":
                body["currentGame"] = game_rec("active", SEED, 1, reveal_all=True)
            else:
                body["previousGame"] = None
            return self._send(body)
        if p == "/api/games/history":
            rec = game_rec("active", None, 1, reveal_all=False)
            return self._send({"json": {"games": [rec]}})
        if p.startswith("/api/games/") and p.endswith("/select-tile"):
            return self._send({})
        return self._send({"error": "not found"}, 404)

    def do_POST(self):
        ln = int(self.headers.get("Content-Length") or 0)
        _ = self.rfile.read(ln)
        p = self.path.split("?")[0]
        if p.endswith("/select-tile"):
            return self._send({"isDeathTile": False, "currentRowIndex": 2, "finalMultiplier": 1.92,
                               "status": "active", "version": 3,
                               "currentRow": {"tiles": 2, "multiplier": 1.92, "deathTileIndex": 0},
                               "nextRow": {"tiles": 2, "multiplier": 3.84, "deathTileIndex": None}})
        if p.endswith("/cash-out"):
            return self._send({"status": "won", "finalMultiplier": 1.92})
        return self._send({"error": "not found"}, 404)


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--mode", default="secure", choices=["secure", "leak-current", "leak-previous"])
    ap.add_argument("--port", type=int, default=8899)
    a = ap.parse_args()
    Handler.mode = a.mode
    print(f"mock death.fun on :{a.port} mode={a.mode}", flush=True)
    HTTPServer(("127.0.0.1", a.port), Handler).serve_forever()
