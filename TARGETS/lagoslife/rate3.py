#!/usr/bin/env python3
"""
Lagos Life - MEASURE THE ACCUMULATION RATE, then keep pushing.

Model: the balance may rise by an amount that ACCUMULATES continuously while the
account is idle. One accepted save resets the accumulator. push.py: 844s of idle
funded exactly one N2,990,211 save -> rate in [3,544, 7,087]/s.

Method (non-destructive to the measurement): idle exactly T seconds, then probe
descending jump sizes. The first accepted jump IS the accumulated allowance for T.
rate = accepted / T. Each accepted save spends it and doubles as a balance increase.

Then Phase B pushes continuously at the best available step.
"""
import json, time, urllib.request, urllib.error, http.cookiejar, copy

GAME = "https://lagoslife.eliysites.com"
UA = ("Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/125.0 Safari/537.36")
CREDS = json.load(open("/tmp/ll_probe_creds.json"))
T_IDLE = 60
PROBES = [10_000_000, 5_000_000, 2_000_000, 1_000_000, 500_000, 300_000, 200_000,
          150_000, 100_000, 75_000, 50_000, 25_000, 10_000, 5_000, 1_000]
FLOOR = 1_000

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


def save_delta(delta):
    g, at, bal = get()
    gg = copy.deepcopy(g); gg["money"] = bal + delta
    st, r = call("/api/save", "PUT", {"game": gg, "base": at})
    return st, bal, r


def spend():
    """Drain whatever is accumulated, so the next measurement starts from ~0."""
    for d in PROBES:
        st, bal, _ = save_delta(d)
        if st != 200:
            return bal
    return bal


def probe():
    """First accepted jump from the descending list == accumulated allowance."""
    for d in PROBES:
        st, bal, _ = save_delta(d)
        if st == 200:
            return d, bal
        if d <= FLOOR:
            break
    return None, None


call("/api/auth/login", "POST", {"username": CREDS["username"], "password": CREDS["password"]})
_, _, bal = get()
print(f"start balance N{bal:,}", flush=True)

print("\nPHASE A - measure the accumulation rate (idle %ds, then probe)" % T_IDLE, flush=True)
rates = []
for i in range(4):
    spend()
    time.sleep(T_IDLE)
    got, before = probe()
    if got is None:
        print(f"  round {i+1}: no jump accepted even at N{FLOOR:,}", flush=True)
        continue
    rate = got / T_IDLE
    rates.append(rate)
    print(f"  round {i+1}: idle {T_IDLE}s -> accepted +N{got:,}  "
          f"=> N{rate:,.0f}/s   (balance N{before:,} -> N{before+got:,})", flush=True)

if rates:
    lo, hi = min(rates), max(rates)
    print(f"\nRATE: {lo:,.0f} - {hi:,.0f}/s   (mid {sum(rates)/len(rates):,.0f}/s)", flush=True)
    for label, target in (("N1bn", 1e9), ("N5bn", 5e9), ("N100bn", 1e11)):
        print(f"   {label:>7} at {sum(rates)/len(rates):,.0f}/s: "
              f"{target/(sum(rates)/len(rates))/86400:8.2f} days", flush=True)

print("\nPHASE B - push: idle %ds, then take the largest accepted jump, repeat" % T_IDLE, flush=True)
start = get()[2]
t0 = time.time()
cycle = 0
while time.time() - t0 < 1500:      # ~25 min of pushing
    cycle += 1
    time.sleep(T_IDLE)
    got, before = probe()
    if got is None:
        print(f"  cycle {cycle}: nothing accepted", flush=True)
        continue
    bal = get()[2]
    print(f"  cycle {cycle:3d}  +N{got:,}  balance N{bal:,}   "
          f"(avg N{(bal-start)/(time.time()-t0):,.0f}/s over the run)", flush=True)

_, _, final = get()
el = time.time() - t0
print("=" * 88, flush=True)
print(f"PHASE A rates (N/s): {[round(r) for r in rates]}", flush=True)
print(f"PHASE B: N{start:,} -> N{final:,}  (+N{final-start:,}) in {el/60:.1f} min "
      f"= N{(final-start)/el:,.0f}/s", flush=True)
json.dump({"rates": rates, "start": start, "final": final, "elapsed": el},
          open("/tmp/ll_rate3.json", "w"), indent=2)
print("-> /tmp/ll_rate3.json", flush=True)
