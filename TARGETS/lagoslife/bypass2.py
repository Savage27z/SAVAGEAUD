#!/usr/bin/env python3
"""
Lagos Life - bypass round 2: the backup/restore path.

Hypothesis: the money allowance is RATE * (now - save.updatedAt). If
POST /api/save/backup {src, at} RESTORES a save and sets its `updatedAt` back to
the backup's (older) timestamp, then the next save sees a huge elapsed window and
allows a huge jump. That would bypass the allowance completely.

A backup only exists after a save is REPLACED, so first trigger a fresh save.
"""
import json, urllib.request, urllib.error, http.cookiejar, copy, time

BASE = "https://lagoslife.eliysites.com"
UA = ("Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/125.0 Safari/537.36")
creds = json.load(open("/tmp/ll_probe_creds.json"))
jar = http.cookiejar.CookieJar()
op = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(jar))


def api(p, m="GET", b=None):
    h = {"User-Agent": UA, "Accept": "application/json", "Origin": BASE, "Referer": BASE + "/"}
    d = None
    if b is not None:
        d = json.dumps(b).encode(); h["Content-Type"] = "application/json"
    r = urllib.request.Request(BASE + p, method=m, data=d, headers=h)
    try:
        with op.open(r, timeout=40) as resp:
            return resp.status, json.loads(resp.read() or b"{}")
    except urllib.error.HTTPError as e:
        try:
            return e.code, json.loads(e.read() or b"{}")
        except Exception:
            return e.code, {}
    except Exception as e:
        return None, {"err": str(e)}


api("/api/auth/login", "POST", {"username": creds["username"], "password": creds["password"]})


def state():
    st, s = api("/api/save")
    g = s.get("game") or {}
    return g, s.get("updatedAt")


g0, at0 = state()
print(f"before: money={g0.get('money')}  updatedAt={at0}  home={g0.get('home')}")

# --- trigger a FRESH save (the "start over" path) so the server keeps a backup ---
print("\n=== trigger a fresh save (should create a backup of the current life) ===")
variants = []
gA = copy.deepcopy(g0); gA["money"] = 0
variants.append(("same game, fresh:true", gA, {"fresh": True, "replace": at0}))
variants.append(("same game, fresh:true, replace:0", copy.deepcopy(gA), {"fresh": True, "replace": 0}))

for label, g, extra in variants:
    st, r = api("/api/save", "PUT", {"game": g, "base": at0, **extra})
    print(f"  {label:<38} HTTP {st}  {json.dumps(r)[:110]}")

print("\n=== is there a backup now? ===")
st, sb = api("/api/save/backup")
print(f"  GET /api/save/backup -> {st}  {json.dumps(sb)[:300]}")
bk = (sb or {}).get("backup")
if not bk:
    print("\n  still no backup. Trying an explicit replace-with-new-game shape...")
    # build a fresh-looking game from the template the bundle's newGame() produces
    fresh = copy.deepcopy(g0)
    fresh.update({"money": 1096000, "phase": "play", "queue": [], "path": [],
                  "location": "home", "work": None, "job": None, "travel": None})
    st, r = api("/api/save", "PUT", {"game": fresh, "base": at0, "fresh": True, "replace": at0})
    print(f"  PUT fresh+replace -> HTTP {st}  {json.dumps(r)[:140]}")
    st, sb = api("/api/save/backup")
    print(f"  GET /api/save/backup -> {st}  {json.dumps(sb)[:300]}")
    bk = (sb or {}).get("backup")

g1, at1 = state()
print(f"\nafter fresh attempt: money={g1.get('money')}  updatedAt={at1}")

if bk:
    print("\n=== BACKUP FOUND - testing restore ===")
    print(f"  backup = {{src: {bk.get('src')!r}, at: {bk.get('at')}, money: {bk.get('money')}, name: {bk.get('name')!r}}}")
    before_at = at1
    st, r = api("/api/save/backup", "POST", {"src": bk.get("src"), "at": bk.get("at")})
    print(f"  POST restore (real values) -> HTTP {st}  {json.dumps(r)[:140]}")
    g2, at2 = state()
    print(f"  after restore: money={g2.get('money')}  updatedAt={at2}  (was {before_at})")
    print(f"  >>> did updatedAt get BACKDATED? {'YES' if at2 and before_at and at2 < before_at else 'no'}")

    # now the payoff test: does a backdated timer allow a huge money jump?
    for target in (100_000_000_000, 5_000_000_000, 1_000_000_000):
        g3, at3 = state(); m3 = g3.get("money") or 0
        g4 = copy.deepcopy(g3); g4["money"] = target
        st, r = api("/api/save", "PUT", {"game": g4, "base": at3})
        g5, _ = state()
        print(f"  jump {m3:,} -> {target:,}  HTTP {st}  server money={g5.get('money')}")
        if st in (200, 204):
            print("     *** BYPASS ***"); break

    # and: can `at` be forged to an old timestamp, then restore again?
    print("\n=== forge a BACKDATED `at` and restore ===")
    for forged in [1, 1000, (bk.get("at") or 0) - 86_400_000]:
        st, r = api("/api/save/backup", "POST", {"src": bk.get("src"), "at": forged})
        g6, at6 = state()
        print(f"  POST restore at={forged} -> HTTP {st}  money={g6.get('money')} updatedAt={at6}")
        g7, at7 = state(); g8 = copy.deepcopy(g7); g8["money"] = 100_000_000_000
        st2, r2 = api("/api/save", "PUT", {"game": g8, "base": at7})
        print(f"     then jump to 100bn -> HTTP {st2}  money={(state()[0]).get('money')}")
else:
    print("\n  no backup was created - the restore path stays untested")

print(f"\nFINAL money = {(state()[0]).get('money')}")
