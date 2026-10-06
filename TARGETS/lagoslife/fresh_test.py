#!/usr/bin/env python3
"""
Does `fresh:true` (or account shape) reset the money allowance?

New data: a fresh account seeded via PUT {game, fresh:true} accepted a direct
+400,000 jump immediately (from 1,000,000). Earlier, on the onboarded account
(money ~4.5M) an immediate +1,000 was accepted but +100,000 was NOT.

So the allowance is not a simple global rate. Prime suspect: the `fresh:true`
save path, which is the "start a new life" overwrite, may not apply the
allowance at all (or resets its baseline).

Test on one account, step by step:
  1. probe the max IMMEDIATE jump as-is
  2. issue a fresh:true save (money unchanged)
  3. probe again  -> did the ceiling move?
  4. try fresh:true WITH a huge money value
  5. try fresh:true with replace variants
"""
import json, urllib.request, urllib.error, http.cookiejar, copy, random, string

BASE = "https://lagoslife.eliysites.com"
UA = ("Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/125.0 Safari/537.36")
GEN = json.load(open("/tmp/ll_genuine_save.json"))
jar = http.cookiejar.CookieJar()
op = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(jar))
pw = "Probe!" + "".join(random.choices(string.ascii_letters + string.digits, k=14))


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


user = "zzf" + "".join(random.choices(string.ascii_lowercase + string.digits, k=6))
api("/api/auth/register", "POST", {"username": user, "password": pw, "name": "fresh probe",
                                   "email": None, "adult": True})


def load():
    st, s = api("/api/save")
    return s.get("game") or {}, s.get("updatedAt")


g = copy.deepcopy(GEN["game"]); g["sim"] = dict(g.get("sim") or {}); g["sim"]["name"] = user
g["money"] = 1_000_000
st, _ = api("/api/save", "PUT", {"game": g, "base": 0, "fresh": True})
print(f"account @{user} seeded -> HTTP {st}, money = {load()[0].get('money'):,}\n")

LADDER = [10**12, 10**11, 10**10, 10**9, 3 * 10**8, 10**8, 3 * 10**7, 10**7,
          3 * 10**6, 10**6, 3 * 10**5, 10**5, 3 * 10**4, 10**4, 10**3, 100]


def max_jump(label):
    g0, at = load(); m0 = g0.get("money")
    best = 0
    for d in LADDER:
        gg = copy.deepcopy(g0); gg["money"] = m0 + d
        st, _ = api("/api/save", "PUT", {"game": gg, "base": at})
        if st in (200, 204):
            best = d
            break
    print(f"  {label}: balance {m0:>16,} -> max immediate jump +{best:>16,} "
          f"({best/max(1,m0)*100:>7.2f}% of balance)")
    return best


print("=== 1. baseline ceiling ===")
b1 = max_jump("as-is            ")

print("\n=== 2. issue a fresh:true save (money unchanged), then re-probe ===")
g0, at = load()
st, r = api("/api/save", "PUT", {"game": g0, "base": at, "fresh": True})
print(f"  fresh:true -> HTTP {st} {(r or {}).get('error','')}")
b2 = max_jump("after fresh:true ")

print("\n=== 3. fresh:true WITH a huge money value ===")
for extra in ({"fresh": True}, {"fresh": True, "replace": 0}, {"fresh": True, "replace": at}):
    g0, at = load()
    gg = copy.deepcopy(g0); gg["money"] = 100_000_000_000
    body = {"game": gg, "base": at}
    body.update(extra)
    st, r = api("/api/save", "PUT", body)
    print(f"  fresh+{json.dumps({k: v for k, v in extra.items() if k != 'fresh'}):<20} -> HTTP {st}  "
          f"money now {load()[0].get('money'):,}  {(r or {}).get('error','')}")

print("\n=== 4. try fresh:true with NO base at all, huge money ===")
g0, _ = load()
gg = copy.deepcopy(g0); gg["money"] = 100_000_000_000
st, r = api("/api/save", "PUT", {"game": gg, "fresh": True})
print(f"  -> HTTP {st}  money now {load()[0].get('money'):,}  {(r or {}).get('error','')}")

print("\n=== 5. after a fresh:true, can we then normal-save a big jump? ===")
g0, at = load()
api("/api/save", "PUT", {"game": g0, "base": at, "fresh": True})   # reset
b3 = max_jump("post-fresh probe ")
print(f"\nsummary: baseline={b1:,}  after-fresh={b2:,}  post-fresh={b3:,}")
print(f"FINAL money = {load()[0].get('money'):,}")
