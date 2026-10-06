#!/usr/bin/env python3
"""Binary search the FIRST-SAVE money ceiling on a brand-new account."""
import json, urllib.request, urllib.error, http.cookiejar, copy, random, string

BASE = "https://lagoslife.eliysites.com"
UA = ("Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/125.0 Safari/537.36")
GEN = json.load(open("/tmp/ll_genuine_save.json"))


def newacct():
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

    u = "zzx" + "".join(random.choices(string.ascii_lowercase + string.digits, k=6))
    pw = "Probe!" + "".join(random.choices(string.ascii_letters + string.digits, k=14))
    api("/api/auth/register", "POST",
        {"username": u, "password": pw, "name": "x", "email": None, "adult": True})
    return u, api


def seed_ok(amount):
    u, api = newacct()
    g = copy.deepcopy(GEN["game"]); g["sim"] = dict(g.get("sim") or {}); g["sim"]["name"] = u
    g["money"] = amount
    st, r = api("/api/save", "PUT", {"game": g, "base": 0, "fresh": True})
    st2, s = api("/api/save")
    return st, (s.get("game") or {}).get("money"), (r or {}).get("error", "")


print("=== binary search the FIRST-SAVE money ceiling ===")
print("  known: 1,000,000 accepted ; 10,000,000 rejected\n")
lo, hi = 1_000_000, 10_000_000
while lo + 1 < hi:
    mid = (lo + hi) // 2
    st, stored, err = seed_ok(mid)
    print(f"  {mid:>12,} -> HTTP {st}  stored={stored}  {err}")
    if st == 200:
        lo = mid
    else:
        hi = mid
print(f"\n  >>> MAX accepted first-save money = {lo:,}    (first rejected = {hi:,})")
