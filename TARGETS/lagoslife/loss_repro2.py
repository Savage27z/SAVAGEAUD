#!/usr/bin/env python3
"""
Lagos Life - destructive claim, AIRTIGHT version.

The client always saves with the base it just fetched, so the rejection can't be
blamed on a stale base. This run uses the CORRECT base (re-fetched after the
anchor) and varies only the transferred amount, to show:
  - the rejection is the per-save ALLOWANCE, not a stale version token
  - large transfers are destroyed; small ones survive  -> the threshold
"""
import json, urllib.request, urllib.error, http.cookiejar, copy, random, string

BASE = "https://lagoslife.eliysites.com"
UA = ("Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/125.0 Safari/537.36")
GEN = json.load(open("/tmp/ll_genuine_save.json"))


class Acct:
    def __init__(self):
        self.jar = http.cookiejar.CookieJar()
        self.op = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(self.jar))
        self.user = self.uid = None

    def raw(self, p, m="GET", b=None):
        h = {"User-Agent": UA, "Accept": "application/json", "Origin": BASE, "Referer": BASE + "/"}
        d = None
        if b is not None:
            d = json.dumps(b).encode(); h["Content-Type"] = "application/json"
        r = urllib.request.Request(BASE + p, method=m, data=d, headers=h)
        try:
            with self.op.open(r, timeout=40) as resp:
                body = resp.read(); return resp.status, (json.loads(body) if body else {}), body
        except urllib.error.HTTPError as e:
            body = e.read()
            try:
                return e.code, json.loads(body or b"{}"), body
            except Exception:
                return e.code, {}, body
        except Exception as e:
            return None, {"err": str(e)}, b""

    def api(self, p, m="GET", b=None):
        s, j, _ = self.raw(p, m, b); return s, j

    def create(self, money):
        self.user = "zzq" + "".join(random.choices(string.ascii_lowercase + string.digits, k=7))
        pw = "Probe!" + "".join(random.choices(string.ascii_letters + string.digits, k=14))
        self.api("/api/auth/register", "POST",
                 {"username": self.user, "password": pw, "name": "probe", "email": None, "adult": True})
        _, me = self.api("/api/auth/me")
        self.uid = (me.get("user") or {}).get("id")
        g = copy.deepcopy(GEN["game"]); g["sim"] = dict(g.get("sim") or {}); g["sim"]["name"] = self.user
        g["money"] = money
        self.api("/api/save", "PUT", {"game": g, "base": 0, "fresh": True})

    def get(self):
        _, s = self.api("/api/save")
        g = s.get("game") or {}
        return g, s.get("updatedAt"), (g.get("money") or 0)


def case(amount, seed=2_000_000):
    S = Acct(); R = Acct()
    S.create(seed); R.create(500_000)
    s0 = S.get()[2]; r0 = R.get()[2]

    st, r = S.api("/api/send", "POST", {"to": R.uid, "amount": amount, "note": "airtight"})
    s1 = S.get()[2]

    # recipient anchors, then re-reads -> the base the real client would use
    g, at, _ = R.get()
    R.api("/api/save", "PUT", {"game": g, "base": at})
    g, at, rm = R.get()                      # <-- fresh, CORRECT base
    st_a, _ = R.api("/api/save", "PUT", {"game": g, "base": at})   # 2nd anchor -> base now stale by 1

    g, at, rm = R.get()                      # fetch the post-anchor base again
    st_c, r_c = R.api("/api/family", "POST", {"action": "claim"})
    got = sum(int(x.get("amount") or 0) for x in (r_c.get("received") or []))

    gg = copy.deepcopy(g); gg["money"] = (g.get("money") or 0) + got
    st_p, r_p, _ = R.raw("/api/save", "PUT", {"game": gg, "base": at})
    r1 = R.get()[2]
    st_c2, r_c2 = R.api("/api/family", "POST", {"action": "claim"})
    reclaim = bool((r_c2 or {}).get("received"))

    destroyed = (s0 - s1) - (r1 - r0)
    print(f"  transfer N{amount:>12,}   claim -> N{got:>12,}   credit save -> HTTP {st_p}"
          f"   {('REJECTED: ' + str(r_p.get('error')) + ' (' + str(r_p.get('code')) + ')') if st_p != 200 else 'accepted'}")
    print(f"      sender N{s0:,} -> N{s1:,} | recipient N{r0:,} -> N{r1:,} | "
          f"DESTROYED N{destroyed:,} | re-claim recovers: {reclaim}")
    return {"amount": amount, "claim_returned": got, "credit_save_http": st_p,
            "credit_save_body": r_p if st_p != 200 else None,
            "sender_before": s0, "sender_after": s1,
            "recipient_before": r0, "recipient_after": r1,
            "destroyed": destroyed, "reclaim_recovers": reclaim,
            "recipient": R.user, "sender": S.user}


print("=" * 100)
print("DESTRUCTIVE CLAIM - correct base, only the amount varies")
print("=" * 100)
out = []
for amt in (1_500_000, 200_000, 50_000):
    out.append(case(amt))
print("=" * 100)
json.dump(out, open("/tmp/ll_loss_airtight.json", "w"), indent=2)
print("-> /tmp/ll_loss_airtight.json")
