#!/usr/bin/env python3
"""
Lagos Life - THE REAL CEILING.

refill2 accepted +N2,990,211 three times in a row at 15s intervals with a fresh
base each time. So the earlier "N1,094/s allowance" was an artefact of reusing a
stale base. Hammer it: one save after another, no sleep, fresh base each time.
Measure the achieved N/s and whether it ever starts refusing.
"""
import json, time, urllib.request, urllib.error, http.cookiejar, copy

GAME = "https://lagoslife.eliysites.com"
UA = ("Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/125.0 Safari/537.36")
CREDS = json.load(open("/tmp/ll_probe_creds.json"))
STEP = 2_990_211
N = 25

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


st, _ = call("/api/auth/login", "POST", {"username": CREDS["username"], "password": CREDS["password"]})
print(f"login HTTP {st}")
g, at, start = get()
print(f"start balance N{start:,}")
print(f"hammering +N{STEP:,} per save, no sleep, fresh base each time, x{N}\n")

ok_n = rej_n = 0
t0 = time.time()
for i in range(N):
    g, at, bal = get()
    gg = copy.deepcopy(g); gg["money"] = bal + STEP
    st, r = call("/api/save", "PUT", {"game": gg, "base": at})
    if st == 200:
        ok_n += 1
    else:
        rej_n += 1
        print(f"  #{i+1:2d}  REJECTED HTTP {st} {r.get('code') or r.get('error')}")

el = time.time() - t0
_, _, final = get()
gain = final - start
print(f"\n{'='*90}")
print(f"accepted {ok_n}/{N}   rejected {rej_n}")
print(f"balance N{start:,} -> N{final:,}")
print(f"gained N{gain:,} in {el:.1f}s  =  N{gain/el:,.0f}/s")
if el:
    per_s = gain / el
    for label, target in (("N1bn", 1e9), ("N5bn", 5e9), ("N100bn", 1e11)):
        secs = target / per_s
        print(f"   {label:>7}: {secs/3600:8.2f} hours ({secs/86400:6.2f} days)")
json.dump({"accepted": ok_n, "rejected": rej_n, "start": start, "final": final,
           "gain": gain, "elapsed": el, "step": STEP}, open("/tmp/ll_hammer.json", "w"), indent=2)
print("-> /tmp/ll_hammer.json")
