#!/usr/bin/env python3
"""
Lagos Life - measure the allowance CURVE (does it scale with elapsed time? is it capped?)

Hypothesis to test: allowance = rate * (now - lastSaveAt), UNCAPPED.
If true, "little by little" is not a loop - an attacker simply does NOT save for a
long time (offline), accumulating a window, then collects one large jump.

Protocol (clean, one save per measurement):
  1. anchor()  - save with money UNCHANGED, which re-anchors updatedAt = now
  2. sleep(dt)
  3. descending-probe for the largest accepted jump: every REJECT is free (no state
     change), so exactly ONE successful save happens - the final accept.
  4. record (actual elapsed, max accepted jump) and fit.
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


def cur():
    st, s = api("/api/save")
    g = s.get("game") or {}
    return g, s.get("updatedAt")


def anchor():
    """save with money unchanged -> re-anchors updatedAt to the server's now"""
    g, at = cur()
    return api("/api/save", "PUT", {"game": g, "base": at})[0]


def try_set(target):
    g, at = cur()
    g2 = copy.deepcopy(g); g2["money"] = target
    st, _ = api("/api/save", "PUT", {"game": g2, "base": at})
    return st in (200, 204)


def money():
    return cur()[0].get("money")


def measure(dt):
    anchor()
    m0 = money()
    t0 = time.time()
    time.sleep(dt)
    # descending probe: big guesses first (free to reject), stop at first accept
    ladder = [10**12, 3 * 10**11, 10**11, 3 * 10**10, 10**10, 3 * 10**9, 10**9,
              3 * 10**8, 10**8, 3 * 10**7, 10**7, 3 * 10**6, 10**6, 3 * 10**5,
              10**5, 3 * 10**4, 10**4, 3 * 10**3, 10**3, 100, 10, 1]
    best = 0
    for d in ladder:
        if try_set(m0 + d):
            best = d
            break
    elapsed = time.time() - t0
    return m0, best, elapsed


print("=" * 94)
print("ALLOWANCE CURVE - is it linear in elapsed time, and is it capped?")
print("=" * 94)
print(f"start money = {money()}\n")
rows = []
for dt in (120, 300, 600, 1200):
    m0, best, el = measure(dt)
    rate = best / el if el else 0
    rows.append({"dt": dt, "elapsed": el, "jump": best, "from": m0, "rate": rate})
    print(f"  waited {el:7.1f}s  from money {m0:>16,}  ->  max jump +{best:>16,}   "
          f"(rate {rate:>10,.0f}/s)")
    print(f"      now money = {money():,}")

print("\n" + "=" * 94)
print("FIT")
print("=" * 94)
for r in rows:
    print(f"  elapsed {r['elapsed']:7.1f}s -> jump {r['jump']:>16,}  rate {r['rate']:>12,.0f}/s")
# linearity check
if len(rows) >= 2:
    a, b = rows[0], rows[-1]
    if a["elapsed"] and b["elapsed"]:
        slope = (b["jump"] - a["jump"]) / (b["elapsed"] - a["elapsed"])
        print(f"\n  implied marginal rate between first and last point: {slope:,.0f}/s")
        print(f"  (linear & uncapped => the two rates above should agree)")
        best_rate = max(r["rate"] for r in rows)
        for name, target in [("N1bn", 10**9), ("N10bn", 10**10), ("N100bn", 10**11)]:
            need = target - money()
            secs = need / best_rate if best_rate else float("inf")
            print(f"  to {name}: {secs:,.0f}s = {secs/3600:,.1f}h = {secs/86400:,.1f} days "
                  f"(at {best_rate:,.0f}/s)")
json.dump(rows, open("/tmp/ll_curve.json", "w"), indent=2)
print(f"\nFINAL money = {money():,}")
