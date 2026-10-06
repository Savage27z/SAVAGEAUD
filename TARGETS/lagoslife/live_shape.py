#!/usr/bin/env python3
"""
Lagos Life - first-save shape discovery (schema oracle) + the money test.

A new account has no server save (updatedAt=0). The client builds the game
locally and PUTs it with fresh:true. So the question becomes: how much of the
game object does the server actually validate? Its error messages will say.

Each attempt: PUT a candidate body, read the RULE in the error, add one field,
repeat. Then, once a save is accepted, set money and read it back.
"""
import json, random, string, urllib.request, urllib.error, http.cookiejar

BASE = "https://lagoslife.eliysites.com"
UA = ("Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/125.0 Safari/537.36")
CREDS = "/tmp/ll_probe_creds.json"
creds = json.load(open(CREDS))

jar = http.cookiejar.CookieJar()
opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(jar))


def api(path, method="GET", body=None):
    headers = {"User-Agent": UA, "Accept": "application/json, text/plain, */*",
               "Origin": BASE, "Referer": BASE + "/"}
    data = None
    if body is not None:
        data = json.dumps(body).encode()
        headers["Content-Type"] = "application/json"
    r = urllib.request.Request(BASE + path, method=method, data=data, headers=headers)
    try:
        with opener.open(r, timeout=40) as resp:
            return resp.status, json.loads(resp.read() or b"{}")
    except urllib.error.HTTPError as e:
        raw = e.read()
        try:
            return e.code, json.loads(raw or b"{}")
        except Exception:
            return e.code, {"raw": raw[:400].decode("utf-8", "replace")}
    except Exception as e:
        return None, {"err": str(e)}


st, j = api("/api/auth/login", "POST",
            {"username": creds["username"], "password": creds["password"]})
print(f"login -> HTTP {st} {json.dumps(j)[:200]}\n")

print("=" * 92)
print("SCHEMA ORACLE - what does the server require in `game`?")
print("=" * 92)
candidates = [
    ("empty game, fresh",        {"game": {}, "fresh": True}),
    ("money only, fresh",        {"game": {"money": 987654321}, "fresh": True}),
    ("money+phase+time, fresh",  {"game": {"money": 987654321, "phase": "play", "time": 2100},
                                  "fresh": True}),
    ("+sim",                     {"game": {"money": 987654321, "phase": "play", "time": 2100,
                                           "sim": {"name": "Probe"}, "needs": {},
                                           "events": [], "queue": [], "path": []},
                                  "fresh": True}),
    ("no fresh flag",            {"game": {"money": 987654321, "phase": "play", "time": 2100}}),
]
for label, body in candidates:
    st, j = api("/api/save", "PUT", body)
    print(f"\n--- {label}  -> HTTP {st}")
    print(f"    {json.dumps(j)[:500]}")

print("\n" + "=" * 92)
print("READBACK after those attempts")
print("=" * 92)
st, save = api("/api/save")
print(f"  GET /api/save -> HTTP {st}  updatedAt={save.get('updatedAt')}")
g = save.get("game")
if isinstance(g, dict):
    print(f"  game.money = {g.get('money')}")
    print(f"  game keys  = {sorted(g.keys())}")
else:
    print(f"  game = {json.dumps(save)[:300]}")
