#!/usr/bin/env python3
"""
Lagos Life - is a CLAIMED TRANSFER exempt from the save allowance?

Findings so far: the server debits the sender itself (no unsaved-debit hole), and
the recipient's credit is applied CLIENT-side after /api/family {action:claim}.

That client-side credit then has to pass the same rate-limited save. But if a
claimed transfer can land IMMEDIATELY (seconds after the previous save), it means
either the credit is exempt from the allowance, or the allowance is far larger
than the ~1,300-5,600/s measured.

Control: a direct +400,000 jump within seconds of a save was rejected earlier.
So: B sends 400,000 to C, C claims and applies it immediately, and we see if it
sticks. If it does, the claim path bypasses the allowance.
"""
import json, urllib.request, urllib.error, http.cookiejar, copy, random, string, time

BASE = "https://lagoslife.eliysites.com"
UA = ("Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/125.0 Safari/537.36")
GEN = json.load(open("/tmp/ll_genuine_save.json"))


class Acct:
    def __init__(self, tag):
        self.tag = tag
        self.jar = http.cookiejar.CookieJar()
        self.op = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(self.jar))
        self.pw = "Probe!" + "".join(random.choices(string.ascii_letters + string.digits, k=14))

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

    def register(self, money=1_000_000):
        self.user = "zz" + self.tag + "".join(random.choices(string.ascii_lowercase + string.digits, k=6))
        st, r = self.api("/api/auth/register", "POST",
                         {"username": self.user, "password": self.pw,
                          "name": f"Probe {self.tag}", "email": None, "adult": True})
        st, me = self.api("/api/auth/me")
        self.uid = (me.get("user") or {}).get("id")
        g = copy.deepcopy(GEN["game"]); g["sim"] = dict(g.get("sim") or {})
        g["sim"]["name"] = self.user; g["money"] = money
        st, r = self.api("/api/save", "PUT", {"game": g, "base": 0, "fresh": True})
        return (self.save()[0] or {}).get("money")

    def save(self):
        st, s = self.api("/api/save")
        return (s.get("game") or {}), s.get("updatedAt")

    def money(self):
        return self.save()[0].get("money")

    def anchor(self):
        g, at = self.save()
        return self.api("/api/save", "PUT", {"game": g, "base": at})[0]

    def put_money(self, value, base=None):
        g, at = self.save()
        g2 = copy.deepcopy(g); g2["money"] = value
        return self.api("/api/save", "PUT", {"game": g2, "base": base or at})


B, C = Acct("b2"), Acct("c2")
mb = B.register()
mc = C.register()
print(f"B @{B.user} = {mb:,}   C @{C.user} = {mc:,}")

AMOUNT = 400_000

print("\n=== CONTROL: can C jump +400,000 directly, right now? ===")
C.anchor()
m0 = C.money()
st, r = C.put_money(m0 + AMOUNT)
print(f"  direct +{AMOUNT:,} from {m0:,} -> HTTP {st}  money now {C.money():,}  "
      f"{(r or {}).get('error','')}")

print("\n=== B sends 400,000 to C ===")
st, r = B.api("/api/send", "POST", {"to": C.uid, "amount": AMOUNT, "note": "claim test"})
print(f"  send -> HTTP {st}  {json.dumps(r)[:160]}")
print(f"  B now {B.money():,}")

print("\n=== C claims, then applies the credit IMMEDIATELY ===")
st, r = C.api("/api/family", "POST", {"action": "claim"})
recv = (r or {}).get("received") or []
print(f"  claim -> HTTP {st}  received={json.dumps(recv)[:200]}")
total = sum(int(x.get("amount") or 0) for x in recv)
print(f"  total claimed = {total:,}")

if total:
    C.anchor()                     # re-anchor so the allowance window is ~0
    before = C.money()
    st, rr = C.put_money(before + total)
    after = C.money()
    ok = after == before + total
    print(f"  C save with credit: {before:,} -> PUT {before+total:,} -> HTTP {st}  server says {after:,}")
    print(f"\n  *** {'CLAIM BYPASSES THE ALLOWANCE' if ok else 'blocked - no bypass'} ***")
    print(f"      (control above rejected the same-size direct jump)")

print("\n=== also: can a SECOND claim of the same item re-credit? ===")
for i in range(2):
    st, r = C.api("/api/family", "POST", {"action": "claim"})
    print(f"  claim again #{i+1} -> {json.dumps(r)[:120]}")

print("\n=== and: max transfer size (FRIEND_SEND.max = 1e10) ===")
st, r = B.api("/api/send", "POST", {"to": C.uid, "amount": 10_000_000_000, "note": "max test"})
print(f"  send 10,000,000,000 -> HTTP {st}  {json.dumps(r)[:180]}")
print(f"\nB={B.money():,}  C={C.money():,}")
