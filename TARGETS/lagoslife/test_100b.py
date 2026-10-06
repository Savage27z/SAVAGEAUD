#!/usr/bin/env python3
"""
Lagos Life - can the balance be pushed to N100bn?

N100bn = 100,000,000,000, 20x the apparent N5bn leaderboard ceiling.

The known gate is a TIME-BASED ALLOWANCE: a save may raise `money` only by
allowance(elapsed since the last successful save). So a single 100bn jump should
be rejected. The real question this script answers:

  1. Is the allowance a CONSTANT rate, or PROPORTIONAL to the current balance?
     - constant  -> 100bn needs ~2 years of ticking = infeasible
     - proportional -> geometric climb, 100bn reachable in a dozen saves
  2. Does any OTHER route bypass the allowance? (fresh / replace / base variants)
  3. Is there an absolute ceiling, or only a rate limit?
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
    return s["game"], s["updatedAt"]


def put(game, at, extra=None):
    body = {"game": game, "base": at}
    if extra:
        body.update(extra)
    st, r = api("/api/save", "PUT", body)
    return st, r


def money_now():
    g, _ = cur()
    return g["money"]


def attempt_value(target):
    """Try to set money=target with a correct base. Returns (accepted, new_money)."""
    g, at = cur()
    g2 = copy.deepcopy(g); g2["money"] = target
    st, r = put(g2, at)
    return st in (200, 204), money_now()


print("=" * 92)
print("STEP 0 - current state")
print("=" * 92)
M0 = money_now()
print(f"  money = {M0:,}")

print("\n" + "=" * 92)
print(f"STEP 1 - straight attempt at N100bn ({100_000_000_000:,})")
print("=" * 92)
ok, after = attempt_value(100_000_000_000)
print(f"  PUT money=100,000,000,000 -> accepted={ok}  server money={after:,}")

print("\n" + "=" * 92)
print("STEP 2 - do the `fresh` / `replace` / base routes bypass the allowance?")
print("=" * 92)
routes = [
    ("money=100bn, base=updatedAt",            {"fresh": None,  "replace": None}),
    ("money=100bn, fresh=true",                {"fresh": True,  "replace": 0}),
    ("money=100bn, fresh=true, replace=at",    {"fresh": True,  "replace": True}),
    ("money=100bn, replace=at",                {"fresh": None,  "replace": True}),
    ("money=100bn, base=0",                    {"base0": True}),
    ("money=100bn, no base",                   {"nobase": True}),
]
for label, mode in routes:
    g, at = cur()
    g2 = copy.deepcopy(g); g2["money"] = 100_000_000_000
    extra = {}
    base = at
    if mode.get("fresh") is not None:   extra["fresh"] = mode["fresh"]
    if mode.get("replace") is True:     extra["replace"] = at
    elif mode.get("replace") is not None: extra["replace"] = mode["replace"]
    if mode.get("base0"):               base = 0
    if mode.get("nobase"):              base = None
    body = {"game": g2}
    if base is not None: body["base"] = base
    body.update(extra)
    st, r = api("/api/save", "PUT", body)
    now = money_now()
    print(f"  {label:<40} HTTP {st:<4} server money={now:,}")

print("\n" + "=" * 92)
print("STEP 3 - measure the allowance: constant rate, or proportional to balance?")
print("=" * 92)


def max_jump_after(wait_s):
    """Wait, then descending-probe so only ONE save happens (the final accept)."""
    t0 = time.time()
    time.sleep(wait_s)
    g, _ = cur(); m = g["money"]
    # descending probe: high guesses rejected are free; the first accept is the max
    lo_accepted = 0
    for frac in (1.0, 0.5, 0.25, 0.12, 0.06, 0.03, 0.015, 0.007, 0.003, 0.0015, 0.0007):
        d = max(1, int(m * frac))
        g2, at = cur()
        g3 = copy.deepcopy(g2); g3["money"] = m + d
        st, _ = put(g3, at)
        if st in (200, 204):
            lo_accepted = d
            break
    return lo_accepted, time.time() - t0, m


print("  level 1 (low balance):")
d1, t1, m1 = max_jump_after(45)
print(f"    balance {m1:>16,}  max jump +{d1:>12,}  after ~{t1:.0f}s  ratio={d1/m1:.4f}")

# climb a few times to raise the balance, then re-measure
print("  climbing...")
for i in range(6):
    g, at = cur(); m = g["money"]
    g2 = copy.deepcopy(g); g2["money"] = m + max(1, int(d1 * 0.9))
    st, _ = put(g2, at)
    time.sleep(3)
print(f"    balance now {money_now():,}")

print("  level 2 (higher balance, same wait):")
d2, t2, m2 = max_jump_after(45)
print(f"    balance {m2:>16,}  max jump +{d2:>12,}  after ~{t2:.0f}s  ratio={d2/m2:.4f}")

print("\n" + "=" * 92)
print("STEP 4 - feasibility of 100bn")
print("=" * 92)
r1, r2 = d1 / max(1, t1), d2 / max(1, t2)
print(f"  allowance rate at level 1: {r1:,.0f}/s")
print(f"  allowance rate at level 2: {r2:,.0f}/s")
need = 100_000_000_000 - money_now()
print(f"  shortfall to 100bn: {need:,}")
print(f"  at {max(r1, r2):,.0f}/s that is {need / max(r1, r2):,.0f} s "
      f"= {need / max(r1, r2) / 3600:,.1f} hours = {need / max(r1, r2) / 86400:,.1f} days")
print(f"  proportional? ratio grew {(d2/m2)/(d1/m1) if d1 and m1 else 0:.2f}x for a "
      f"{m2/m1 if m1 else 0:.2f}x balance increase")
json.dump({"d1": d1, "t1": t1, "m1": m1, "d2": d2, "t2": t2, "m2": m2,
           "final": money_now()}, open("/tmp/ll_100b.json", "w"), indent=2)
print(f"\nFINAL balance = {money_now():,}")
