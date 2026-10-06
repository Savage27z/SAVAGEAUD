#!/usr/bin/env python3
"""
Lagos Life - bypass round 3: find ANOTHER money writer.

The /api/save allowance caps the gain rate. So the only real bypass is a
different endpoint that writes money with its own (or no) validation:
  /api/bank      -> deposit / withdraw  (classic duplication vector)
  /api/music     -> slots / gambling
  /api/casino    -> chips buy/cash-out (server-side)
  /api/gov       -> governor allowance (server-paid)
  /api/bail, /api/court, /api/crime, /api/party, /api/venue, /api/hunt
  /api/food-gift, /api/squads, /api/invite, /api/daily

Method: GET each for its shape, then POST a deliberately-minimal body and read
the RULE out of the error (schema oracle).
"""
import json, urllib.request, urllib.error, http.cookiejar

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
            return resp.status, (body[:700].decode("utf-8", "replace") if raw else json.loads(body or b"{}"))
    except urllib.error.HTTPError as e:
        body = e.read()
        try:
            return e.code, (body[:700].decode("utf-8", "replace") if raw else json.loads(body or b"{}"))
        except Exception:
            return e.code, body[:300].decode("utf-8", "replace")
    except Exception as e:
        return None, str(e)


api("/api/auth/login", "POST", {"username": creds["username"], "password": creds["password"]})


def money():
    st, s = api("/api/save")
    g = s.get("game") or {}
    return g.get("money")


print("=" * 96)
print(f"baseline money = {money()}")
print("=" * 96)

GETS = ["/api/bank", "/api/music", "/api/music/slots", "/api/gov", "/api/court",
        "/api/crime", "/api/party", "/api/venue", "/api/hunt", "/api/knock",
        "/api/food-gift", "/api/squads", "/api/room", "/api/live", "/api/radio",
        "/api/gist", "/api/origin", "/api/sea", "/api/social", "/api/report"]
print("\n--- GET shapes ---")
for p in GETS:
    st, r = api(p, raw=True)
    print(f"  {p:<22} {st:<5} {str(r)[:170]}")

print("\n--- POST with minimal/empty body (read the RULE) ---")
POSTS = ["/api/bank", "/api/music/slots", "/api/music", "/api/party", "/api/venue",
         "/api/hunt", "/api/knock", "/api/crime", "/api/court", "/api/bail",
         "/api/daily", "/api/invite", "/api/spray", "/api/squads", "/api/food-gift",
         "/api/gov/run", "/api/gov/vote", "/api/politics/run", "/api/casino"]
for p in POSTS:
    st, r = api(p, "POST", {})
    print(f"  POST {p:<22} {st:<5} {json.dumps(r)[:170] if isinstance(r, dict) else str(r)[:170]}")

print(f"\nmoney after probes = {money()}")
