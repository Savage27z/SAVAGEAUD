#!/usr/bin/env python3
"""F09-d: detector validation — does the F08 leak scanner actually fire on each shape?

Runs the UNMODIFIED scanner (disclosure/live-capture/live-board-leak-scanner.py) against
the local mock in three planted configurations:

  secure        -> expect NONE            (negative control: must not false-positive)
  leak-current  -> expect SEED EXPOSED    (positive control: proves the detector can fire)
  leak-previous -> ???                    <-- the F08-open shape

If leak-previous returns NONE while leak-current fires, the scanner has a parse-coverage
blind spot for `previousGame`, and F08's "leaks: NONE" is not evidence about that shape.
"""
import json, os, subprocess, sys, threading, time
from http.server import HTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from mock_deathfun_server import Handler  # noqa: E402

SCANNER = os.path.join(HERE, "..", "live-capture", "live-board-leak-scanner.py")
PORT = 8899
GID = "1a06e1a5-6583-4737-b681-53c961ba3769"
COOKIE = "/tmp/dummy_cookie.txt"
open(COOKIE, "w").write("dummy")


def run_mode(mode):
    Handler.mode = mode
    srv = HTTPServer(("127.0.0.1", PORT), Handler)
    t = threading.Thread(target=srv.serve_forever, daemon=True)
    t.start()
    time.sleep(0.4)
    try:
        p = subprocess.run(
            [sys.executable, SCANNER, "--cookie-file", COOKIE,
             "--base", f"http://127.0.0.1:{PORT}", "--game-id", GID, "--rows-to-play", "1"],
            capture_output=True, text=True, timeout=90)
        return p.stdout + p.stderr
    finally:
        srv.shutdown()
        srv.server_close()


results = {}
for mode in ("secure", "leak-current", "leak-previous"):
    out = run_mode(mode)
    results[mode] = out
    print(f"\n{'#'*22} MODE = {mode} {'#'*22}")
    print(out.strip()[-1200:])

print("\n\n================ VERDICT SUMMARY ================")
for mode, out in results.items():
    low = out.lower()
    fired = ("seed exposed" in low) or ("unplayed row revealed" in low)
    print(f"  {mode:14} scanner_fired={fired}")

print("\nInterpretation:")
print("  secure  not fired + leak-current fired  => detector works and does not false-positive")
print("  leak-previous not fired                 => BLIND SPOT: previousGame is never parsed,")
print("                                             so 'leaks: NONE' says nothing about it.")
json.dump({k: v for k, v in results.items()}, open(os.path.join(HERE, "f09d-detector-validation.json"), "w"), indent=1)
