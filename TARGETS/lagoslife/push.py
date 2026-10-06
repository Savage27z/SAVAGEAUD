#!/usr/bin/env python3
"""
Lagos Life - SUSTAINED PUSHER. Keep adding balance for as long as it keeps working.

The limit is a burst pot (~N15M measured), not a rate, and it refills on a period
longer than 175s. This pushes indefinitely: burst while accepted, back off and retry
while refused, and log the trajectory + every refill time it observes.

Also probes whether the pot SCALES as the balance grows (tries 5x steps periodically).
Writes progress lines to /tmp/ll_push.log and a final JSON.
"""
import json, time, urllib.request, urllib.error, http.cookiejar, copy, sys

GAME = "https://lagoslife.eliysites.com"
UA = ("Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/125.0 Safari/537.36")
CREDS = json.load(open("/tmp/ll_probe_creds.json"))
STEP = 2_990_211
RUN_SECONDS = 3600
TARGET_BALANCE = 1_000_000_000

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
    """GET a fresh base, then PUT balance+delta. Returns (http, balance_before)."""
    g, at, bal = get()
    gg = copy.deepcopy(g); gg["money"] = bal + delta
    st, r = call("/api/save", "PUT", {"game": gg, "base": at})
    return st, bal, r


def log(msg):
    print(msg, flush=True)


st, _ = call("/api/auth/login", "POST", {"username": CREDS["username"], "password": CREDS["password"]})
g, at, start_bal = get()
log(f"login HTTP {st}   start balance N{start_bal:,}")
log(f"step N{STEP:,}   run {RUN_SECONDS}s   target N{TARGET_BALANCE:,}   {time.strftime('%H:%M:%S')}")

t0 = time.time()
accepts = rejects = 0
last_accept_t = None
refills = []            # (seconds_spent_rejecting_before_it_opened)
wait = 15               # backoff while the window is closed
big_probe_every = 5     # after this many consecutive accepts, probe a 5x step
consec = 0
big_step_works = None

while time.time() - t0 < RUN_SECONDS:
    _, _, bal = get()
    if bal >= TARGET_BALANCE:
        log(f"*** TARGET REACHED N{bal:,} ***"); break

    step = STEP
    if consec > 0 and consec % big_probe_every == 0 and big_step_works is None:
        step = STEP * 5          # one-off probe: does the pot scale?

    st, before, r = save_delta(step)
    if st == 200:
        accepts += 1; consec += 1
        if last_accept_t is not None:
            pass
        last_accept_t = time.time()
        if step != STEP and big_step_works is None:
            big_step_works = True
            log(f"  BIG STEP ACCEPTED: +N{step:,}  (5x steps work)")
        wait = 15
        if accepts % 5 == 0 or accepts <= 3:
            el = time.time() - t0
            log(f"  [{time.strftime('%H:%M:%S')}] accept #{accepts:4d}  +N{step:,}  "
                f"balance N{before + step:,}   ({el/60:.1f} min in, {accepts} accepts / {rejects} rejects)")
    else:
        rejects += 1; consec = 0
        if step != STEP and big_step_works is None:
            big_step_works = False
            log(f"  big step (+N{step:,}) refused -> the pot does NOT scale with balance")
        # measure how long the window stays shut
        shut_from = time.time()
        while time.time() - shut_from < 900:
            time.sleep(wait)
            st2, before2, r2 = save_delta(STEP)
            if st2 == 200:
                rt = time.time() - shut_from
                refills.append(round(rt, 1))
                accepts += 1; consec += 1; last_accept_t = time.time()
                log(f"  [{time.strftime('%H:%M:%S')}] window REOPENED after {rt:.0f}s  "
                    f"+N{STEP:,}  balance N{before2 + STEP:,}   (refills seen: {refills})")
                break
            wait = min(wait * 1.5, 90)
        else:
            log("  window shut >900s - stopping"); break

_, _, final = get()
el = time.time() - t0
gain = final - start_bal
log("=" * 90)
log(f"start N{start_bal:,}  ->  final N{final:,}")
log(f"gained N{gain:,} in {el/60:.2f} min   accepts {accepts}  rejects {rejects}")
log(f"average N{gain/el:,.0f}/s" if el else "no time")
log(f"refill times observed: {refills}")
json.dump({"start": start_bal, "final": final, "gain": gain, "elapsed_s": el,
           "accepts": accepts, "rejects": rejects, "refills": refills,
           "big_step_works": big_step_works}, open("/tmp/ll_push.json", "w"), indent=2)
log("-> /tmp/ll_push.json")
