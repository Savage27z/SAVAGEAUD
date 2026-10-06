#!/usr/bin/env python3
"""
Lagos Life - the ACCUMULATION LOOP ("little by little", measured).

The allowance refused cleanly characterize: it blocked +100bn always, but
permitted +1,000,000 and +1,800,000 jumps on fresh-ish accounts. So stop
theorising and measure the practical climb:

  repeat: try to add the LARGEST accepted jump (descending ladder), sleep briefly
  record balance after every iteration and the wall-clock

Then report the real gain rate and how long 1bn / 10bn / 100bn would take.
"""
import json, urllib.request, urllib.error, http.cookiejar, copy, random, string, time

BASE = "https://lagoslife.eliysites.com"
UA = ("Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/125.0 Safari/537.36")
GEN = json.load(open("/tmp/ll_genuine_save.json"))
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


u = "zza" + "".join(random.choices(string.ascii_lowercase + string.digits, k=6))
api("/api/auth/register", "POST",
    {"username": u, "password": "Probe!" + "".join(random.choices(string.ascii_letters + string.digits, k=14)),
     "name": "accum", "email": None, "adult": True})
g = copy.deepcopy(GEN["game"]); g["sim"] = dict(g.get("sim") or {}); g["sim"]["name"] = u
g["money"] = 2_990_211
st, _ = api("/api/save", "PUT", {"game": g, "base": 0, "fresh": True})


def state():
    st, s = api("/api/save")
    return s.get("game") or {}, s.get("updatedAt")


g0, _ = state()
START = g0.get("money")
print(f"account @{u}  start = {START:,}")
print(f"\n{'iter':>5} {'balance':>18} {'jump added':>16} {'elapsed':>9} {'rate/s':>12}")
t0 = time.time()
rows = []
LADDER = [100_000_000, 30_000_000, 10_000_000, 3_000_000, 1_000_000,
          300_000, 100_000, 30_000, 10_000, 3_000, 1_000]
last = START
for it in range(1, 41):
    g, at = state(); m = g.get("money") or 0
    gained = 0
    for d in LADDER:
        gg = copy.deepcopy(g); gg["money"] = m + d
        st, _ = api("/api/save", "PUT", {"game": gg, "base": at})
        if st in (200, 204):
            gained = d
            break
    g2, _ = state(); now = g2.get("money") or 0
    el = time.time() - t0
    rows.append({"it": it, "balance": now, "gained": gained, "elapsed": el})
    if it <= 6 or it % 5 == 0 or gained == 0:
        print(f"{it:>5} {now:>18,} {gained:>16,} {el:>8.1f}s {now/el if el else 0:>12,.0f}")
    if gained == 0 and now == last:
        print("   (no further progress)")
        break
    last = now
    time.sleep(1.5)

g3, _ = state()
END = g3.get("money") or 0
el = time.time() - t0
print(f"\n=== RESULT ===")
print(f"  start   : {START:,}")
print(f"  end     : {END:,}")
print(f"  gained  : {END - START:,}  in {el:.1f}s")
print(f"  rate    : {(END-START)/el:,.0f}/s   = {(END-START)/el*3600:,.0f}/hour  = {(END-START)/el*86400:,.0f}/day")
rate = (END - START) / el if el else 0
for name, target in [("N1bn", 10**9), ("N10bn", 10**10), ("N100bn", 10**11)]:
    need = target - END
    print(f"  {name:<6}: {need/rate/3600:,.2f} hours at this rate" if rate else f"  {name}: n/a")
json.dump({"start": START, "end": END, "elapsed": el, "rows": rows},
          open("/tmp/ll_accum.json", "w"), indent=2)
