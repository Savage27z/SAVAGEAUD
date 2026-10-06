#!/usr/bin/env python3
"""
Lagos Life - THE FARM, on the new email-code sign-up flow.

Each burner costs exactly one disposable inbox (mail.tm, free, scripted), and each
burner's FIRST SAVE accepts up to N2,990,211 instantly. If the recipient's credit
save tolerates a large jump with a correct base, then the wall is no longer the
N1,094/s grind - it is registration + send throughput.

Measures the effective N/second and compares it with the grind baseline.
"""
import json, re, time, random, string, urllib.request, urllib.error, http.cookiejar, copy

GAME = "https://lagoslife.eliysites.com"
UA = ("Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/125.0 Safari/537.36")
GEN = json.load(open("/tmp/ll_genuine_save.json"))
CEILING = 2_990_211
GRIND = 1_094          # N/s baseline measured by accum.py


def req(url, method="GET", body=None, headers=None, opener=None):
    h = {"User-Agent": UA, "Accept": "application/json"}
    if headers:
        h.update(headers)
    d = None
    if body is not None:
        d = json.dumps(body).encode(); h["Content-Type"] = "application/json"
    r = urllib.request.Request(url, method=method, data=d, headers=h)
    op = opener or urllib.request.build_opener()
    try:
        with op.open(r, timeout=45) as resp:
            raw = resp.read(); return resp.status, (json.loads(raw) if raw else {})
    except urllib.error.HTTPError as e:
        raw = e.read()
        try:
            return e.code, json.loads(raw or b"{}")
        except Exception:
            return e.code, {"_raw": raw[:160].decode("utf8", "replace")}
    except Exception as e:
        return None, {"err": str(e)}


class Mail:
    """One disposable inbox. Registers lazily and can be reused for a retry."""

    def __init__(self):
        self.op = urllib.request.build_opener()
        self.addr = self.jwt = None

    def make(self):
        for _ in range(3):
            st, doms = req("https://api.mail.tm/domains")
            dl = doms.get("hydra:member") if isinstance(doms, dict) else doms
            dom = (_dl[0].get("domain") if (_dl := dl or [{}]) else None)
            if not dom:
                time.sleep(3); continue
            self.addr = "ll" + "".join(random.choices(string.ascii_lowercase + string.digits, k=10)) + "@" + dom
            pw = "Probe!" + "".join(random.choices(string.ascii_letters + string.digits, k=12))
            st, _ = req("https://api.mail.tm/accounts", "POST", {"address": self.addr, "password": pw})
            st2, tok = req("https://api.mail.tm/token", "POST", {"address": self.addr, "password": pw})
            if tok.get("token"):
                self.jwt = tok["token"]; return True
            time.sleep(3)
        return False

    def wait_code(self, timeout=90):
        end = time.time() + timeout
        hdr = {"Authorization": "Bearer " + self.jwt}
        while time.time() < end:
            time.sleep(2.5)
            st, m = req("https://api.mail.tm/messages", headers=hdr, opener=self.op)
            msgs = (m.get("hydra:member") if isinstance(m, dict) else m) or []
            for msg in msgs:
                st2, full = req(f"https://api.mail.tm/messages/{msg['id']}", headers=hdr, opener=self.op)
                subj = full.get("subject") or ""
                hit = re.search(r"\b(\d{6})\b", subj)
                if hit:
                    return hit.group(1)
        return None


class Player:
    def __init__(self):
        self.jar = http.cookiejar.CookieJar()
        self.op = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(self.jar))
        self.user = self.uid = self.mail = None

    def call(self, p, m="GET", b=None):
        return req(GAME + p, m, b, {"Origin": GAME, "Referer": GAME + "/"}, self.op)

    def signup(self, money):
        """Full new flow: inbox -> /api/auth/code -> /api/auth/verify -> first save."""
        self.mail = Mail()
        if not self.mail.make():
            return False, "no inbox"
        self.user = "zzf" + "".join(random.choices(string.ascii_lowercase + string.digits, k=9))
        st, r = self.call("/api/auth/code", "POST",
                          {"mode": "signup", "name": "Probe", "username": self.user,
                           "email": self.mail.addr, "adult": True})
        if st != 200 or not r.get("ticket"):
            return False, f"code HTTP {st} {json.dumps(r)[:110]}"
        code = self.mail.wait_code()
        if not code:
            return False, "no code arrived"
        st, r = self.call("/api/auth/verify", "POST",
                          {"ticket": r["ticket"], "code": code, "username": self.user})
        if st != 200:
            return False, f"verify HTTP {st} {json.dumps(r)[:110]}"
        self.uid = (r.get("user") or {}).get("id")
        g = copy.deepcopy(GEN["game"]); g["sim"] = dict(g.get("sim") or {}); g["sim"]["name"] = self.user
        g["money"] = money
        st, r = self.call("/api/save", "PUT", {"game": g, "base": 0, "fresh": True})
        if st != 200:
            return False, f"first save HTTP {st} {r.get('error')}"
        return True, "ok"

    def get(self):
        _, s = self.call("/api/save")
        g = s.get("game") or {}
        return g, s.get("updatedAt"), (g.get("money") or 0)

    def send(self, to_uid, amount, tries=10):
        for i in range(tries):
            st, r = self.call("/api/send", "POST", {"to": to_uid, "amount": amount, "note": "farm"})
            if st == 200:
                return st, r, i
            if st == 429:
                time.sleep(7); continue
            return st, r, i
        return st, r, tries


print("=" * 100)
print("THE FARM - new email-code sign-up, burners seeded at the ceiling")
print("=" * 100)

T = Player()
ok, why = T.signup(1_000_000)
print(f"target @{T.user}  created={ok} ({why})")
if not ok:
    raise SystemExit(1)
_, _, t0 = T.get()
print(f"  target starts at N{t0:,}\n")

N = 3
rows, t_start = [], time.time()
for i in range(1, N + 1):
    S = Player()
    ts = time.time()
    ok, why = S.signup(CEILING)
    if not ok:
        print(f"[{i}] burner FAILED: {why}"); rows.append({"i": i, "error": why}); continue
    _, _, sm = S.get()
    print(f"[{i}] burner @{S.user}  seeded N{sm:,}  (signup took {time.time()-ts:.1f}s)")

    AMT = sm - 100
    st, r, tries = S.send(T.uid, AMT)
    _, _, sm2 = S.get()
    print(f"    send N{AMT:,} -> HTTP {st}{'' if st == 200 else ' ' + json.dumps(r)[:70]}  (retries={tries})"
          f"   burner N{sm:,} -> N{sm2:,}")

    stc, rc = T.call("/api/family", "POST", {"action": "claim"})
    got = sum(int(x.get("amount") or 0) for x in (rc.get("received") or []))
    gt, at, before = T.get()
    gg = copy.deepcopy(gt); gg["money"] = (gt.get("money") or 0) + got
    stp, rp = T.call("/api/save", "PUT", {"game": gg, "base": at})
    _, _, after = T.get()
    print(f"    target: claim N{got:,} | credit save HTTP {stp}{'' if stp == 200 else ' ' + json.dumps(rp)[:70]}"
          f" | N{before:,} -> N{after:,}")
    rows.append({"burner": S.user, "seeded": sm, "sent": AMT, "send_http": st,
                 "claim": got, "credit_http": stp, "balance": after})

elapsed = time.time() - t_start
_, _, final = T.get()
gain = final - t0
print("=" * 100)
print(f"target  N{t0:,}  ->  N{final:,}      GAINED N{gain:,} in {elapsed:.1f}s   ({N} burners)")
print(f"per burner: N{gain / max(N,1):,.0f}")
if elapsed:
    print(f"EFFECTIVE RATE: N{gain/elapsed:,.0f}/s   vs the grind baseline N{GRIND:,}/s"
          f"   ->  {gain/elapsed/GRIND:.1f}x" if elapsed else "")
print(f"extrapolated at this rate: N{gain/elapsed*86400:,.0f}/day" if elapsed else "")
json.dump({"rows": rows, "target": T.user, "start": t0, "final": final, "gain": gain,
           "elapsed_s": elapsed, "n": N}, open("/tmp/ll_farm2.json", "w"), indent=2)
print("-> /tmp/ll_farm2.json")
