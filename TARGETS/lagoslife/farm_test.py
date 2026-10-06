#!/usr/bin/env python3
"""
Lagos Life - STARTING-GRANT FARMING test.

Established:
  - a new account's first save is capped at ~2,990,211 (the plausible starter
    amount for its home) - so you cannot SEED an account rich.
  - /api/send moves money to another player, and the server debits the sender
    correctly (no free transfer).
  - the recipient claims via /api/family {action:claim} and the credit persists.

So the "little by little" path is: each new account is born with ~2.99M of
legitimate starting money. Pool many accounts into one and the balance adds up.
This measures how much one account accumulates, and how long it takes.
"""
import json, urllib.request, urllib.error, http.cookiejar, copy, random, string, time

BASE = "https://lagoslife.eliysites.com"
UA = ("Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/125.0 Safari/537.36")
GEN = json.load(open("/tmp/ll_genuine_save.json"))
SEED = 2_990_211          # the measured first-save ceiling


class Acct:
    def __init__(self):
        self.jar = http.cookiejar.CookieJar()
        self.op = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(self.jar))
        self.user = None
        self.uid = None

    def api(self, p, m="GET", b=None):
        h = {"User-Agent": UA, "Accept": "application/json", "Origin": BASE, "Referer": BASE + "/"}
        d = None
        if b is not None:
            d = json.dumps(b).encode(); h["Content-Type"] = "application/json"
        r = urllib.request.Request(BASE + p, method=m, data=d, headers=h)
        try:
            with self.op.open(r, timeout=40) as resp:
                return resp.status, json.loads(resp.read() or b"{}")
        except urllib.error.HTTPError as e:
            try:
                return e.code, json.loads(e.read() or b"{}")
            except Exception:
                return e.code, {}
        except Exception as e:
            return None, {"err": str(e)}

    def create(self, money=SEED):
        self.user = "zzm" + "".join(random.choices(string.ascii_lowercase + string.digits, k=7))
        pw = "Probe!" + "".join(random.choices(string.ascii_letters + string.digits, k=14))
        st, _ = self.api("/api/auth/register", "POST",
                         {"username": self.user, "password": pw, "name": "mule",
                          "email": None, "adult": True})
        st, me = self.api("/api/auth/me")
        self.uid = (me.get("user") or {}).get("id")
        g = copy.deepcopy(GEN["game"]); g["sim"] = dict(g.get("sim") or {}); g["sim"]["name"] = self.user
        g["money"] = money
        st, r = self.api("/api/save", "PUT", {"game": g, "base": 0, "fresh": True})
        self.seed_http = st
        return self.money()

    def money(self):
        st, s = self.api("/api/save")
        return (s.get("game") or {}).get("money")


CENTRAL = Acct()
print(f"central account @{CENTRAL.user} created with {CENTRAL.create():,}\n")

N = 10
t0 = time.time()
print(f"=== farming {N} accounts, each seeded at the ceiling, sending to central ===")
print(f"{'#':>3} {'account':<16} {'seeded':>14} {'send HTTP':>10} {'central now':>16}")
for i in range(1, N + 1):
    m = Acct()
    seeded = m.create()
    # send everything except a small buffer for the fee
    amount = int(seeded * 0.98)
    st, r = m.api("/api/send", "POST", {"to": CENTRAL.uid, "amount": amount, "note": f"farm {i}"})
    # claim on the central account
    stc, rc = CENTRAL.api("/api/family", "POST", {"action": "claim"})
    recv = (rc or {}).get("received") or []
    got = sum(int(x.get("amount") or 0) for x in recv)
    if got:
        st_s, s = CENTRAL.api("/api/save")
        game = s.get("game") or {}; at = s.get("updatedAt")
        gg = copy.deepcopy(game); gg["money"] = (game.get("money") or 0) + got
        st_p, r_p = CENTRAL.api("/api/save", "PUT", {"game": gg, "base": at})
        credited = st_p in (200, 204)
    else:
        credited = None
    print(f"{i:>3} {m.user:<16} {seeded:>14,} {st:>10} {CENTRAL.money():>16,}   "
          f"claim={got:,} credited={credited}")

el = time.time() - t0
total = CENTRAL.money()
print(f"\n=== RESULT ===")
print(f"  central balance      : {total:,}")
print(f"  accounts farmed      : {N}")
print(f"  elapsed              : {el:.1f}s  ({el/N:.1f}s per account incl. register+seed+send+claim)")
print(f"  gained per account   : {total/N:,.0f}")
print(f"\n  extrapolated (at {el/N:.1f}s/account):")
for name, target in [("N1bn", 10**9), ("N10bn", 10**10), ("N100bn", 10**11)]:
    n = target / (total / N)
    secs = n * (el / N)
    print(f"    {name:<6} needs ~{n:,.0f} accounts = {secs/3600:,.1f} hours")
json.dump({"central": CENTRAL.user, "accounts": N, "total": total, "elapsed": el},
          open("/tmp/ll_farm.json", "w"), indent=2)
