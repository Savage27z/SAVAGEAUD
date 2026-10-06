#!/usr/bin/env python3
"""
Lagos Life - THE DECISIVE TEST.

We now hold a GENUINE, server-accepted game object (/tmp/ll_genuine_save.json,
54 keys, money=1,096,000) built by the real client. So the server's structural
validator is satisfied. We change exactly ONE field - `money` - and PUT it back.

Three things to establish:
  1. does a client-authored money value persist?   -> the vulnerability
  2. does the server clamp an absurd value?        -> is there a ceiling?
  3. does the inflated net worth reach the PUBLIC leaderboard?
"""
import json, urllib.request, urllib.error, http.cookiejar, copy

BASE = "https://lagoslife.eliysites.com"
UA = ("Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/125.0 Safari/537.36")
creds = json.load(open("/tmp/ll_probe_creds.json"))

jar = http.cookiejar.CookieJar()
opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(jar))


def api(path, method="GET", body=None):
    h = {"User-Agent": UA, "Accept": "application/json, text/plain, */*",
         "Origin": BASE, "Referer": BASE + "/"}
    data = None
    if body is not None:
        data = json.dumps(body).encode(); h["Content-Type"] = "application/json"
    r = urllib.request.Request(BASE + path, method=method, data=data, headers=h)
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


st, j = api("/api/auth/login", "POST", {"username": creds["username"], "password": creds["password"]})
print(f"login -> {st} {json.dumps(j)[:120]}  (user @{creds['username']})\n")

save = json.load(open("/tmp/ll_genuine_save.json"))
game = save["game"]
base_at = save["updatedAt"]
ORIGINAL = game["money"]
print("=" * 92)
print("GENUINE SAVE (built by the real client, accepted by the server)")
print("=" * 92)
print(f"  updatedAt      = {base_at}")
print(f"  game.money     = {ORIGINAL:,}")
print(f"  game keys ({len(game)})")
print(f"  stats          = {json.dumps(game.get('stats'))}")
print(f"  home={game.get('home')}  sim.name={ (game.get('sim') or {}).get('name') }")


def put_money(value, label):
    g = copy.deepcopy(game)
    g["money"] = value
    body = {"game": {**g, "outbox": {"notices": [], "fx": []}}, "base": base_at}
    st, resp = api("/api/save", "PUT", body)
    print(f"\n--- {label}: PUT money={value:,} -> HTTP {st}")
    print(f"    resp: {json.dumps(resp)[:240]}")
    if st == 409:
        cur = (resp or {}).get("game") or {}
        print(f"    409 conflict. server money={cur.get('money')} updatedAt={(resp or {}).get('updatedAt')}")
    st2, after = api("/api/save")
    got = (after.get("game") or {}).get("money")
    print(f"    READ BACK: money={got if got is None else format(got, ',')}")
    return st, got, after


print("\n" + "=" * 92)
print("TEST 1 - arbitrary client-authored balance")
print("=" * 92)
NEW = 123_456_789
st, got, after = put_money(NEW, "tampered")
verdict1 = (got == NEW)
print(f"\n  money before PUT by us : {ORIGINAL:,}")
print(f"  money we PUT           : {NEW:,}")
print(f"  money server returns   : {got if got is None else format(got, ',')}")
print(f"\n  *** {'CONFIRMED' if verdict1 else 'NOT CONFIRMED'}: "
      f"the server {'persisted' if verdict1 else 'did NOT persist'} a client-authored balance ***")
json.dump(after, open("/tmp/ll_after_tamper.json", "w"), indent=2)

print("\n" + "=" * 92)
print("TEST 2 - is there a ceiling? (does the server clamp or reject?)")
print("=" * 92)
for v in (5_000_000_000, 9_999_999_999, 10**15):
    st, got, _ = put_money(v, "ceiling probe")
    print(f"    => PUT {v:,} gave server value {got if got is None else format(got, ',')}"
          f"  (delta {('n/a' if got is None else format(got - v, '+,'))})")

print("\n" + "=" * 92)
print("TEST 3 - does the inflated net worth publish to the PUBLIC leaderboard?")
print("=" * 92)
st, fb = api("/api/forbes")
print(f"  GET /api/forbes -> HTTP {st}   total ranked={(fb or {}).get('total')}")
print(f"  mine = {json.dumps((fb or {}).get('mine'))}")
print(f"  my username in public top: "
      f"{json.dumps([e for e in ((fb or {}).get('top') or []) if e.get('username') == creds['username']])}")
json.dump(fb, open("/tmp/ll_forbes_after.json", "w"), indent=2)

print("\n" + "=" * 92)
print(f"probe account: @{creds['username']}  (delete this account when done)")
print("=" * 92)
