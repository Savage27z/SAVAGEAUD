#!/usr/bin/env python3
"""
Lagos Life - THE /api/send DUPLICATION TEST.

The client's money-send does:
    await api.save(game)                       # save FIRST
    let a = await api.sendMoney(to, amount)    # server records the transfer
    mutate(e => { e.money -= a.amount + a.fee })   # <-- debit applied CLIENT-SIDE

So the server credits the recipient, and the sender's debit only exists if the
sender's own client applies it. FRIEND_SEND = {min: 100, max: 1e10}.

If the server does NOT debit the sender server-side, then:
   - the sender keeps its balance
   - the recipient gains it
   - repeating the send CREATES money each round (bounded only by send count)

Test with two accounts I control (B = sender, C = recipient), independent of A
(which is busy with the allowance-curve measurement).
"""
import json, urllib.request, urllib.error, http.cookiejar, copy, random, string

BASE = "https://lagoslife.eliysites.com"
UA = ("Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/125.0 Safari/537.36")
GEN = json.load(open("/tmp/ll_genuine_save.json"))   # a genuine 54-key game built by the real client


class Acct:
    def __init__(self, tag):
        self.tag = tag
        self.jar = http.cookiejar.CookieJar()
        self.op = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(self.jar))
        self.user = None
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

    def register_and_seed(self):
        self.user = "zz" + self.tag + "".join(random.choices(string.ascii_lowercase + string.digits, k=6))
        st, r = self.api("/api/auth/register", "POST",
                         {"username": self.user, "password": self.pw,
                          "name": f"Probe {self.tag}", "email": None, "adult": True})
        print(f"  register @{self.user} -> HTTP {st} {json.dumps(r)[:120]}")
        st, me = self.api("/api/auth/me")
        self.uid = (me.get("user") or {}).get("id")
        # seed a genuine game object (the server rejects hand-made ones)
        game = copy.deepcopy(GEN["game"])
        game["sim"] = dict(game.get("sim") or {}); game["sim"]["name"] = self.user
        game["money"] = 1_000_000
        st, r = self.api("/api/save", "PUT", {"game": game, "base": 0, "fresh": True})
        st2, s = self.api("/api/save")
        print(f"    seed save -> HTTP {st}  money={(s.get('game') or {}).get('money')}  uid={self.uid}")
        return (s.get("game") or {}).get("money")

    def money(self):
        st, s = self.api("/api/save")
        return (s.get("game") or {}).get("money")

    def family(self):
        st, f = self.api("/api/family")
        return f or {}


print("=" * 96)
print("STEP 1 - create sender B and recipient C")
print("=" * 96)
B, C = Acct("b"), Acct("c")
mb0 = B.register_and_seed()
mc0 = C.register_and_seed()

print("\n" + "=" * 96)
print("STEP 2 - B sends money to C, and we DO NOT apply any client-side debit")
print("=" * 96)
AMOUNT = 500_000
print(f"  B money before = {B.money():,}   C money before = {C.money():,}")
for i in range(1, 4):
    st, r = B.api("/api/send", "POST", {"to": C.uid, "amount": AMOUNT, "note": f"probe {i}"})
    b_after, c_after = B.money(), C.money()
    fam = C.family()
    incoming = fam.get("incoming")
    print(f"\n  send #{i}: HTTP {st}  resp={json.dumps(r)[:150]}")
    print(f"    B money after = {b_after:,}   (started {mb0:,})")
    print(f"    C money after = {c_after:,}   (started {mc0:,})")
    print(f"    C incoming    = {json.dumps(incoming)[:200]}")

print("\n" + "=" * 96)
print("STEP 3 - does C have a claimable inbox? try /api/family {action:claim}")
print("=" * 96)
for i in range(1, 4):
    st, r = C.api("/api/family", "POST", {"action": "claim"})
    print(f"  claim #{i}: HTTP {st}  resp={json.dumps(r)[:200]}   C money={C.money():,}")

st, r = C.api("/api/family", "POST", {"action": "history"})
print(f"\n  money history: HTTP {st}  {json.dumps(r)[:400]}")

print("\n" + "=" * 96)
print("VERDICT INPUTS")
print("=" * 96)
print(f"  B: started {mb0:,}  -> now {B.money():,}")
print(f"  C: started {mc0:,}  -> now {C.money():,}")
json.dump({"B": B.user, "C": C.user, "B_money": B.money(), "C_money": C.money()},
          open("/tmp/ll_send_test.json", "w"), indent=2)
