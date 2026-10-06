#!/usr/bin/env python3
"""
Lagos Life - WHY does the recipient's credit save 409?

Two candidates:
  (a) STALE BASE      -> the client's version token was already superseded
  (b) ALLOWANCE       -> the jump is too large for the elapsed time

Distinguish them directly:
  control  : no-op save with the base from a GET issued immediately before -> should be 200
  test     : same fresh base, but money += the real transfer               -> 409 => allowance

Then retry the SAME credit every 20s to see whether the allowance ever opens
(i.e. whether a large incoming transfer is merely delayed or permanently lost).
"""
import json, re, time, random, string, urllib.request, urllib.error, http.cookiejar, copy

GAME = "https://lagoslife.eliysites.com"
UA = ("Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/125.0 Safari/537.36")
GEN = json.load(open("/tmp/ll_genuine_save.json"))
CEILING = 2_990_211


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
        self.user = "zzw" + "".join(random.choices(string.ascii_lowercase + string.digits, k=9))
        r = {}
        for attempt in range(6):
            st, r = self.call("/api/auth/code", "POST",
                              {"mode": "signup", "name": "Probe", "username": self.user,
                               "email": m.addr, "adult": True})
            if st == 200 and r.get("ticket"):
                break
            print(f"    /api/auth/code HTTP {st} {json.dumps(r)[:80]} - waiting 45s")
            time.sleep(45)
        if not r.get("ticket"):
            return False, f"code {st}"
        code = m.wait_code()
        if not code:
            return False, "no code"
        st, r = self.call("/api/auth/verify", "POST",
                          {"ticket": r["ticket"], "code": code, "username": self.user})
        if st != 200:
            return False, f"verify {st} {json.dumps(r)[:80]}"
        self.uid = (r.get("user") or {}).get("id")
        g = copy.deepcopy(GEN["game"]); g["sim"] = dict(g.get("sim") or {}); g["sim"]["name"] = self.user
        g["money"] = money
        st, r = self.call("/api/save", "PUT", {"game": g, "base": 0, "fresh": True})
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
g, at, b0 = T.get()
print(f"target balance N{b0:,}   updatedAt {at}\n")

S = Player(); ok, why = S.signup(CEILING)
print(f"burner @{S.user} created={ok} ({why})")
_, _, _ = S.get()
AMT = 2_000_000
st, r = S.call("/api/send", "POST", {"to": T.uid, "amount": AMT, "note": "why409"})
print(f"burner sends N{AMT:,} -> HTTP {st}\n")

stc, rc = T.call("/api/family", "POST", {"action": "claim"})
got = sum(int(x.get("amount") or 0) for x in (rc.get("received") or []))
print(f"target claims N{got:,} (item now consumed server-side)")

# ---------------- control: is a base read immediately before the PUT valid?
gg, at, before = T.get()
stc1, rc1 = T.call("/api/save", "PUT", {"game": gg, "base": at})
print(f"\nCONTROL  no-op save, base just read : HTTP {stc1} {json.dumps(rc1)[:90]}"
      f"   -> base is {'VALID' if stc1 == 200 else 'NOT valid'}")

# ---------------- test: same fresh base, money += the transfer
gg, at, before = T.get()
gt = copy.deepcopy(gg); gt["money"] = (gt.get("money") or 0) + got
stp, rp = T.call("/api/save", "PUT", {"game": gt, "base": at})
_, _, after = T.get()
print(f"TEST     +N{got:,} on a fresh base     : HTTP {stp} {json.dumps(rp)[:90]}")
print(f"         balance N{before:,} -> N{after:,}   -> "
      f"{'ALLOWANCE rejects it (base was valid)' if stp != 200 else 'ACCEPTED'}")

# ---------------- does the allowance ever open?
print("\nretrying the SAME credit as time passes (does it become bankable?)")
for wait in (20, 20, 30, 30):
    time.sleep(wait)
    gg, at, cur = T.get()
    gt = copy.deepcopy(gg); gt["money"] = (gt.get("money") or 0) + got
    stp, rp = T.call("/api/save", "PUT", {"game": gt, "base": at})
    _, _, cur2 = T.get()
    print(f"  +{wait}s  HTTP {stp} {json.dumps(rp)[:70]}   balance N{cur:,} -> N{cur2:,}")

# ---------------- is a SMALL credit bankable?
print("\nsmall-jump control (can the target accept a modest credit at all?)")
sg, sat, sb = T.get()
for delta in (50_000, 200_000, 500_000):
    gg2 = copy.deepcopy(sg); gg2["money"] = sb + delta
    stx, rx = T.call("/api/save", "PUT", {"game": gg2, "base": sat})
    _, _, nb = T.get()
    print(f"  +N{delta:,}  HTTP {stx} {json.dumps(rx)[:60]}   balance N{sb:,} -> N{nb:,}")
    if stx == 200:
        sg, sat, sb = T.get()

json.dump({"target": T.user, "transfer": got, "control": stc1, "test": stp,
           "final": T.get()[2]}, open("/tmp/ll_why409.json", "w"), indent=2)
print("\n-> /tmp/ll_why409.json")
