#!/usr/bin/env python3
"""
Lagos Life - FUND LOSS: a transfer the recipient cannot bank is destroyed.

Observed during the farming test:
  sender debited -> recipient's inbox gets the item -> recipient claims
  -> server returns the item and REMOVES it from the inbox
  -> the recipient's client-side credit then FAILS the save allowance
  -> recipient balance unchanged, sender already paid  =>  the money is gone.

This isolates it with clean before/after numbers.
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

    def create(self, money=2_000_000):
        self.user = "zzd" + "".join(random.choices(string.ascii_lowercase + string.digits, k=7))
        pw = "Probe!" + "".join(random.choices(string.ascii_letters + string.digits, k=14))
        self.api("/api/auth/register", "POST",
                 {"username": self.user, "password": pw, "name": "d", "email": None, "adult": True})
        st, me = self.api("/api/auth/me")
        self.uid = (me.get("user") or {}).get("id")
        g = copy.deepcopy(GEN["game"]); g["sim"] = dict(g.get("sim") or {}); g["sim"]["name"] = self.user
        g["money"] = money
        self.api("/api/save", "PUT", {"game": g, "base": 0, "fresh": True})
        return self.money()

    def money(self):
        st, s = self.api("/api/save")
        return (s.get("game") or {}).get("money")

    def save_state(self):
        st, s = self.api("/api/save")
        return s.get("game") or {}, s.get("updatedAt")


S = Acct(); R = Acct()
S_0 = S.create(2_000_000)
R_0 = R.create(500_000)
print(f"sender @{S.user} = {S_0:,}   recipient @{R.user} = {R_0:,}\n")

AMOUNT = 1_500_000
print(f"=== sender sends {AMOUNT:,} to recipient ===")
st, r = S.api("/api/send", "POST", {"to": R.uid, "amount": AMOUNT, "note": "loss test"})
print(f"  send -> HTTP {st}  {json.dumps(r)[:140]}")
S_1 = S.money()
print(f"  sender  {S_0:,} -> {S_1:,}   (lost {S_0 - S_1:,})")

print(f"\n=== recipient claims ===")
st, r = R.api("/api/family", "POST", {"action": "claim"})
recv = (r or {}).get("received") or []
got = sum(int(x.get("amount") or 0) for x in recv)
print(f"  claim -> HTTP {st}  received {got:,}")

print(f"\n=== recipient applies the credit and saves (as the real client does) ===")
game, at = R.save_state()
gg = copy.deepcopy(game); gg["money"] = (game.get("money") or 0) + got
st_p, r_p = R.api("/api/save", "PUT", {"game": gg, "base": at})
R_1 = R.money()
print(f"  save -> HTTP {st_p}  {(r_p or {}).get('error','')}")
print(f"  recipient {R_0:,} -> {R_1:,}")

print(f"\n=== does a second claim recover it? ===")
st, r = R.api("/api/family", "POST", {"action": "claim"})
print(f"  claim again -> {json.dumps(r)[:140]}")

print("\n" + "=" * 84)
print("RESULT")
print("=" * 84)
print(f"  sender paid          : {S_0 - S_1:,}")
print(f"  recipient received   : {R_1 - R_0:,}")
print(f"  EVIDENCE: sender lost {S_0-S_1:,}, recipient gained {R_1-R_0:,}")
if (R_1 - R_0) < (S_0 - S_1):
    print(f"  *** {S_0-S_1-(R_1-R_0):,} has been DESTROYED - the transfer is gone for both parties ***")
json.dump({"sender_lost": S_0 - S_1, "recipient_gained": R_1 - R_0, "amount": AMOUNT},
          open("/tmp/ll_loss.json", "w"), indent=2)
