#!/usr/bin/env python3
"""
Lagos Life - BURST SIZE and REFILL TIME.

hammer showed 5 consecutive saves accepted, then every one after refused.
refill2 showed 3 accepted at 15s spacing. So there is a burst budget that refills.
Measure: (a) how long until the budget refills after it is spent, (b) the burst size again.
=> honest SUSTAINED N/s.
"""
import json, time, urllib.request, urllib.error, http.cookiejar, copy

GAME = "https://lagoslife.eliysites.com"
UA = ("Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/125.0 Safari/537.36")
CREDS = json.load(open("/tmp/ll_probe_creds.json"))
STEP = 2_990_211

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


def try_step():
    g, at, bal = get()
    gg = copy.deepcopy(g); gg["money"] = bal + STEP
    st, r = call("/api/save", "PUT", {"game": gg, "base": at})
    return st, bal


call("/api/auth/login", "POST", {"username": CREDS["username"], "password": CREDS["password"]})
_, _, bal = get()
print(f"start balance N{bal:,}\n")

# --- phase 1: we are already post-burst (hammer spent it). find the refill time.
print("PHASE 1 - budget is spent; retry every 10s until one is accepted")
print("-" * 90)
t_wall = time.time()
refill = None
for i in range(18):
    if i:
        time.sleep(10)
    st, b0 = try_step()
    el = time.time() - t_wall
    print(f"  +{el:5.1f}s  HTTP {st}  {'ACCEPTED - budget refilled' if st == 200 else str(st)}")
    if st == 200:
        refill = el
        break

# --- phase 2: immediately burst again to size the budget
print("\nPHASE 2 - immediate burst, count how many land before the wall")
print("-" * 90)
ok = 0
t_burst = time.time()
for i in range(12):
    st, b0 = try_step()
    if st != 200:
        print(f"  burst stopped after {ok} saves (HTTP {st})")
        break
    ok += 1
    print(f"  burst save {ok:2d}  OK   balance now N{b0 + STEP:,}")
burst_el = time.time() - t_burst

_, _, final = get()
print("\n" + "=" * 90)
print(f"refill time      : {refill if refill is not None else 'not observed'} s")
print(f"burst size       : {ok} saves x N{STEP:,} = N{ok*STEP:,} in {burst_el:.1f}s")
if refill:
    sustained = (ok * STEP) / (refill + burst_el)
    print(f"SUSTAINED rate   : N{sustained:,.0f}/s   (burst N{ok*STEP:,} per {refill+burst_el:.0f}s cycle)")
    for label, target in (("N1bn", 1e9), ("N5bn", 5e9), ("N100bn", 1e11)):
        print(f"   {label:>7}: {target/sustained/3600:7.2f} h  ({target/sustained/86400:6.2f} days)")
print(f"final balance    : N{final:,}")
json.dump({"refill_s": refill, "burst": ok, "burst_elapsed": burst_el, "final": final},
          open("/tmp/ll_cooldown.json", "w"), indent=2)
print("-> /tmp/ll_cooldown.json")
