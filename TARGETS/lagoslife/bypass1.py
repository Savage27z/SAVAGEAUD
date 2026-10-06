#!/usr/bin/env python3
"""
Lagos Life - bypass hunt, round 1: endpoints that might credit money server-side.

The /api/save allowance is a wall. So look for OTHER writers:
  /api/wallet/verify?checkout_id=  and /api/ads/verify?checkout_id=  -> purchase credit
  /api/invite                      -> referral bonus
  /api/daily                       -> daily reward (replayable?)
  /api/spray, /api/spray/pick      -> server-credited cash with limit/gone logic
  /api/jobs (pay/done)             -> job payout
  /api/gov/*, /api/politics/*      -> governor allowance
  /api/family                      -> transfers between players
  /api/casino, /api/bet/instant    -> server-side settlement
Plus: does the server cross-check `stats.earnedTotal` / `game.version` at all?
"""
import json, urllib.request, urllib.error, http.cookiejar, copy

BASE = "https://lagoslife.eliysites.com"
UA = ("Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/125.0 Safari/537.36")
creds = json.load(open("/tmp/ll_probe_creds.json"))
jar = http.cookiejar.CookieJar()
op = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(jar))


def api(p, m="GET", b=None, raw=False):
    h = {"User-Agent": UA, "Accept": "application/json", "Origin": BASE, "Referer": BASE + "/"}
    d = None
    if b is not None:
        d = json.dumps(b).encode(); h["Content-Type"] = "application/json"
    r = urllib.request.Request(BASE + p, method=m, data=d, headers=h)
    try:
        with op.open(r, timeout=40) as resp:
            body = resp.read()
            return resp.status, (body[:400].decode("utf-8", "replace") if raw else json.loads(body or b"{}"))
    except urllib.error.HTTPError as e:
        body = e.read()
        try:
            return e.code, (body[:400].decode("utf-8", "replace") if raw else json.loads(body or b"{}"))
        except Exception:
            return e.code, body[:200].decode("utf-8", "replace")
    except Exception as e:
        return None, str(e)


api("/api/auth/login", "POST", {"username": creds["username"], "password": creds["password"]})


def money():
    st, s = api("/api/save")
    return s["game"]["money"]


print("=" * 94)
print(f"baseline money = {money():,}")
print("=" * 94)

print("\n--- read-only probes of money-adjacent endpoints ---")
for path in ["/api/daily", "/api/invite", "/api/wallet/pending", "/api/spray",
             "/api/squads", "/api/gov", "/api/politics/manager", "/api/jobs",
             "/api/casino", "/api/bet/instant", "/api/forbes", "/api/world",
             "/api/ads", "/api/players?q=", "/api/family"]:
    st, r = api(path, raw=True)
    print(f"  GET {path:<28} HTTP {st:<5} {str(r)[:150]}")

print("\n--- purchase verification by client-supplied checkout_id ---")
for path, cid in [("/api/wallet/verify?checkout_id=", "TEST"), ("/api/ads/verify?checkout_id=", "TEST")]:
    st, r = api(path + cid, raw=True)
    print(f"  {path}TEST -> HTTP {st}  {str(r)[:180]}")

print("\n--- does the server check game.version / stats at all? ---")
def try_money(label, mutate):
    st, s = api("/api/save")
    g = copy.deepcopy(s["game"]); at = s["updatedAt"]
    m0 = g["money"]
    mutate(g)
    st2, r = api("/api/save", "PUT", {"game": g, "base": at})
    st3, s3 = api("/api/save")
    print(f"  {label:<52} HTTP {st2:<5} money {s3['game']['money']:,}")
    return st2

try_money("money=100bn, version=999", lambda g: (g.__setitem__("money", 100_000_000_000), g.__setitem__("version", 999)))
try_money("money=100bn, version='1'", lambda g: (g.__setitem__("money", 100_000_000_000), g.__setitem__("version", "1")))
try_money("money=100bn + earnedTotal=100bn", lambda g: (g.__setitem__("money", 100_000_000_000), g["stats"].__setitem__("earnedTotal", 100_000_000_000)))
try_money("money=100bn + earnedToday=100bn", lambda g: (g.__setitem__("money", 100_000_000_000), g["stats"].__setitem__("earnedToday", 100_000_000_000)))
try_money("money as string '100000000000'", lambda g: g.__setitem__("money", "100000000000"))
try_money("money as float 1e11", lambda g: g.__setitem__("money", 1e11))
try_money("money = 2**53 (max safe int)", lambda g: g.__setitem__("money", 2**53))
try_money("money = 0 (then +1)", lambda g: g.__setitem__("money", 0))

print(f"\nfinal money = {money():,}")
