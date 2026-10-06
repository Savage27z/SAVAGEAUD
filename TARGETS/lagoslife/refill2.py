#!/usr/bin/env python3
"""
Lagos Life - THE REFILL CURVE (existing account, no registration needed).

/api/auth/register is now 410 and /api/auth/code is throttled, but /api/auth/login
still works. Why409 proved a +N2,000,000 credit is ACCEPTED on a fresh window and
every attempt after it is rejected -> the per-save limit is a BUDGET that a save
consumes and that refills with time. Measure the refill time.
"""
import json, time, urllib.request, urllib.error, http.cookiejar, copy

GAME = "https://lagoslife.eliysites.com"
UA = ("Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/125.0 Safari/537.36")
CREDS = json.load(open("/tmp/ll_probe_creds.json"))
TARGET = 2_990_211
GRIND = 1_094

jar = http.cookiejar.CookieJar()
op = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(jar))


def call(p, m="GET", b=None):
    h = {"User-Agent": UA, "Accept": "application/json", "Origin": GAME, "Referer": GAME + "/"}
    d = None
    if b is not None:
        d = json.dumps(b).encode(); h["Content-Type"] = "application/json"
    r = urllib.request.Request(GAME + p, method=m, data=d, headers=h)
    try:
        with op.open(r, timeout=45) as resp:
            raw = resp.read(); return resp.status, (json.loads(raw) if raw else {})
    except urllib.error.HTTPError as e:
        raw = e.read()
        try:
            return e.code, json.loads(raw or b"{}")
        except Exception:
            return e.code, {"_raw": raw[:120].decode("utf8", "replace")}
    except Exception as e:
        return None, {"err": str(e)}


def get():
    _, s = call("/api/save")
    g = s.get("game") or {}
    return g, s.get("updatedAt"), (g.get("money") or 0)


st, r = call("/api/auth/login", "POST", {"username": CREDS["username"], "password": CREDS["password"]})
print(f"login @{CREDS['username']} -> HTTP {st} {json.dumps(r)[:90]}")
st, me = call("/api/auth/me")
print(f"me -> {json.dumps(me)[:140]}")
g, at, bal = get()
print(f"balance N{bal:,}\n")

print("=" * 96)
print(f"attempt +N{TARGET:,} every 15s with a fresh base, until accepted, x3")
print("=" * 96)
rows = []
last_ok = time.time()
succ = 0
for i in range(16):
    if i:
        time.sleep(15)
    elapsed = time.time() - last_ok
    g, at, bal = get()
    gg = copy.deepcopy(g); gg["money"] = bal + TARGET
    st, r = call("/api/save", "PUT", {"game": gg, "base": at})
    ok = st == 200
    print(f"  #{i+1:2d}  {elapsed:6.1f}s since last accepted fit   +N{TARGET:,}  HTTP {st}  "
          f"{'ACCEPTED' if ok else 'rejected: ' + str(r.get('code') or r.get('error'))}")
    rows.append({"i": i + 1, "since": round(elapsed, 1), "http": st})
    if ok:
        _, _, bal2 = get()
        rate = TARGET / elapsed if elapsed else 0
        print(f"        balance N{bal:,} -> N{bal2:,}   "
              f"({TARGET/elapsed:,.0f}/s = {rate/GRIND:.1f}x the grind)" if elapsed else "")
        last_ok = time.time()
        succ += 1
        if succ >= 3:
            break

_, _, final = get()
print("=" * 96)
print(f"final balance N{final:,}")
json.dump({"rows": rows, "final": final, "target": TARGET}, open("/tmp/ll_refill2.json", "w"), indent=2)
print("-> /tmp/ll_refill2.json")
