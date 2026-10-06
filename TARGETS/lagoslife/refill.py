#!/usr/bin/env python3
"""
Lagos Life - THE REFILL CURVE.

why409 showed a +N2,000,000 credit ACCEPTED on a fresh window, and every attempt
after it rejected. So the per-save limit is a budget that (a) a save consumes and
(b) refills with time. Measure the refill: how long until a big save is accepted again.

If a N2.99M credit lands after ~T seconds, the farm rate is N2.99M/T per burner,
which we compare with the N1,094/s grind.
"""
import json, re, time, random, string, urllib.request, urllib.error, http.cookiejar, copy

GAME = "https://lagoslife.eliysites.com"
UA = ("Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/125.0 Safari/537.36")
GEN = json.load(open("/tmp/ll_genuine_save.json"))
TARGET = 2_990_211
GRIND = 1_094


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
            return e.code, {"_raw": raw[:120].decode("utf8", "replace")}
    except Exception as e:
        return None, {"err": str(e)}


class Mail:
    def __init__(self):
        self.op = urllib.request.build_opener(); self.addr = self.jwt = None

    def make(self):
        for _ in range(4):
            st, doms = req("https://api.mail.tm/domains")
            dl = doms.get("hydra:member") if isinstance(doms, dict) else doms
            dl = dl or [{}]
            dom = dl[0].get("domain")
            if not dom:
                time.sleep(3); continue
            self.addr = "ll" + "".join(random.choices(string.ascii_lowercase + string.digits, k=10)) + "@" + dom
            pw = "Probe!" + "".join(random.choices(string.ascii_letters + string.digits, k=12))
            req("https://api.mail.tm/accounts", "POST", {"address": self.addr, "password": pw})
            st2, tok = req("https://api.mail.tm/token", "POST", {"address": self.addr, "password": pw})
            if tok.get("token"):
                self.jwt = tok["token"]; return True
            time.sleep(3)
        return False

    def wait_code(self, timeout=90):
        end = time.time() + timeout
        hdr = {"Authorization": "Bearer " + str(self.jwt)}
        while time.time() < end:
            time.sleep(2.5)
            st, m = req("https://api.mail.tm/messages", headers=hdr, opener=self.op)
            for msg in ((m.get("hydra:member") if isinstance(m, dict) else m) or []):
                st2, full = req(f"https://api.mail.tm/messages/{msg['id']}", headers=hdr, opener=self.op)
                hit = re.search(r"\b(\d{6})\b", full.get("subject") or "")
                if hit:
                    return hit.group(1)
        return None


class Player:
    def __init__(self):
        self.jar = http.cookiejar.CookieJar()
        self.op = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(self.jar))
        self.user = self.uid = None

    def call(self, p, m="GET", b=None):
        return req(GAME + p, m, b, {"Origin": GAME, "Referer": GAME + "/"}, self.op)

    def signup(self, money):
        m = Mail()
        if not m.make():
            return False, "no inbox"
        self.user = "zzv" + "".join(random.choices(string.ascii_lowercase + string.digits, k=9))
        r = {}
        for _ in range(6):
            st, r = self.call("/api/auth/code", "POST",
                              {"mode": "signup", "name": "Probe", "username": self.user,
                               "email": m.addr, "adult": True})
            if st == 200 and r.get("ticket"):
                break
            print(f"    code HTTP {st} - wait 45s"); time.sleep(45)
        if not r.get("ticket"):
            return False, "no ticket"
        code = m.wait_code()
        if not code:
            return False, "no code"
        st, r = self.call("/api/auth/verify", "POST",
                          {"ticket": r["ticket"], "code": code, "username": self.user})
        if st != 200:
            return False, f"verify {st}"
        self.uid = (r.get("user") or {}).get("id")
        g = copy.deepcopy(GEN["game"]); g["sim"] = dict(g.get("sim") or {}); g["sim"]["name"] = self.user
        g["money"] = money
        st, _ = self.call("/api/save", "PUT", {"game": g, "base": 0, "fresh": True})
        return (st == 200), f"first save {st}"

    def get(self):
        _, s = self.call("/api/save")
        g = s.get("game") or {}
        return g, s.get("updatedAt"), (g.get("money") or 0)


print("=" * 96)
T = Player(); ok, why = T.signup(1_000_000)
print(f"target @{T.user} created={ok} ({why})")
if not ok:
    raise SystemExit(1)
g, at, bal = T.get()
print(f"start balance N{bal:,}  (the seeding save just consumed the window)\n")

print("attempt +N%d with a fresh base, once every 15s, until accepted" % TARGET)
print("-" * 96)
t_last_accepted = time.time()
rows = []
for i in range(12):
    if i:
        time.sleep(15)
    elapsed = time.time() - t_last_accepted
    g, at, bal = T.get()
    gg = copy.deepcopy(g); gg["money"] = bal + TARGET
    st, r = T.call("/api/save", "PUT", {"game": gg, "base": at})
    outcome = "ACCEPTED" if st == 200 else f"rejected ({r.get('code') or r.get('error')})"
    print(f"  attempt {i+1:2d}  {elapsed:5.1f}s since last accepted save   "
          f"+N{TARGET:,}   HTTP {st}  {outcome}")
    rows.append({"attempt": i + 1, "since": round(elapsed, 1), "http": st})
    if st == 200:
        _, _, bal2 = T.get()
        print(f"      -> balance N{bal:,} -> N{bal2:,}")
        rate = TARGET / elapsed if elapsed else 0
        print(f"      -> N{TARGET:,} per {elapsed:.1f}s = N{rate:,.0f}/s "
              f"({rate/GRIND:.1f}x the N{GRIND:,}/s grind)")
        t_last_accepted = time.time()
        if i >= 3:
            break

json.dump(rows, open("/tmp/ll_refill.json", "w"), indent=2)
print("\n-> /tmp/ll_refill.json")
