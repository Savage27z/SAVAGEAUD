#!/usr/bin/env python3
"""
Lagos Life - walk the NEW email-code sign-up flow end to end.

  POST /api/auth/code   {mode:"signup", name, username, email, adult:true} -> {ticket, to, resendIn}
  POST /api/auth/verify {ticket, code, username}                           -> {existing, user}

Uses a disposable mail.tm inbox (no third-party address involved), then tests:
  * does the code arrive / is it 6 digits
  * does /api/auth/verify rate-limit wrong codes (brute-force exposure)
  * is the ticket/orate reusable
"""
import json, time, random, string, urllib.request, urllib.error, http.cookiejar

GAME = "https://lagoslife.eliysites.com"
UA = ("Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/125.0 Safari/537.36")

game_jar = http.cookiejar.CookieJar()
game_op = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(game_jar))


def req(url, method="GET", body=None, headers=None, opener=None):
    h = {"User-Agent": UA, "Accept": "application/json"}
    if headers:
        h.update(headers)
    d = None
    if body is not None:
        d = json.dumps(body).encode()
        h["Content-Type"] = "application/json"
    r = urllib.request.Request(url, method=method, data=d, headers=h)
    op = opener or urllib.request.build_opener()
    try:
        with op.open(r, timeout=40) as resp:
            raw = resp.read()
            return resp.status, (json.loads(raw) if raw else {})
    except urllib.error.HTTPError as e:
        raw = e.read()
        try:
            return e.code, json.loads(raw or b"{}")
        except Exception:
            return e.code, {"_raw": raw[:200].decode("utf8", "replace")}
    except Exception as e:
        return None, {"err": str(e)}


def game(p, m="GET", b=None):
    return req(GAME + p, m, b,
               {"Origin": GAME, "Referer": GAME + "/"}, game_op)


# ------------------------------------------------------------------ disposable inbox
print("=== mail.tm disposable inbox ===")
st, doms = req("https://api.mail.tm/domains")
_dl = doms.get("hydra:member") if isinstance(doms, dict) else doms
domain = (_dl or [{}])[0].get("domain")
addr = "ll" + "".join(random.choices(string.ascii_lowercase + string.digits, k=10)) + "@" + str(domain)
pw = "Probe!" + "".join(random.choices(string.ascii_letters + string.digits, k=12))
st, acct = req("https://api.mail.tm/accounts", "POST", {"address": addr, "password": pw})
print(f"  {addr}  HTTP {st}  id={'set' if acct.get('id') else acct}")
st, tok = req("https://api.mail.tm/token", "POST", {"address": addr, "password": pw})
jwt = tok.get("token")
print(f"  token HTTP {st}  {'ok' if jwt else tok}")

inbox_op = urllib.request.build_opener()
AUTH = {"Authorization": "Bearer " + jwt} if jwt else {}


def inbox():
    st, m = req("https://api.mail.tm/messages", headers=AUTH, opener=inbox_op)
    msgs = (m.get("hydra:member") if isinstance(m, dict) else m) or []
    return st, msgs


# ------------------------------------------------------------------ step 1: request code
username = "zz" + "".join(random.choices(string.ascii_lowercase + string.digits, k=9))
print(f"\n=== step 1: POST /api/auth/code  (username {username}) ===")
st, r = game("/api/auth/code", "POST",
             {"mode": "signup", "name": "Probe", "username": username, "email": addr, "adult": True})
print(f"  HTTP {st}  {json.dumps(r)[:300]}")
ticket = r.get("ticket")
if not ticket:
    print("  !! no ticket returned - stopping"); raise SystemExit(1)

# ------------------------------------------------------------------ step 2: read the mail
print("\n=== step 2: read the code from the inbox ===")
code = None
for i in range(20):
    time.sleep(3)
    st, msgs = inbox()
    if msgs:
        mid = msgs[0]["id"]
        st2, full = req(f"https://api.mail.tm/messages/{mid}", headers=AUTH, opener=inbox_op)
        txt = json.dumps(full)
        print(f"  [{i}] mail arrived: {full.get('subject','?')!r}")
        import re
        subj = full.get("subject") or ""
        m = (re.search(r"\b(\d{6})\b", subj)
             or re.search(r"(?<![#\d])(\d{6})(?![\d])", txt))
        if m:
            code = m.group(1); print(f"  CODE = {code}"); break
    else:
        print(f"  [{i}] inbox empty")
if not code:
    print("  !! no code arrived"); raise SystemExit(1)

# ------------------------------------------------------------------ step 3: the real code first
print("\n=== step 3: verify with the REAL code (tries left untouched) ===")
st, r = game("/api/auth/verify", "POST", {"ticket": ticket, "code": code, "username": username})
print(f"  HTTP {st}  {json.dumps(r)[:300]}")
st, me = game("/api/auth/me")
print(f"  /api/auth/me -> HTTP {st}  {json.dumps(me)[:220]}")

# ------------------------------------------------------------------ step 4: brute-force headroom
print("\n=== step 4: NEW ticket, then exhaust the wrong-code counter ===")
u2 = "zz" + "".join(random.choices(string.ascii_lowercase + string.digits, k=9))
st, r2 = game("/api/auth/code", "POST",
              {"mode": "signup", "name": "Probe", "username": u2, "email": addr, "adult": True})
t2 = r2.get("ticket")
print(f"  fresh ticket -> HTTP {st}  {json.dumps(r2)[:160]}")
if t2:
    for i in range(7):
        st_v, rv = game("/api/auth/verify", "POST", {"ticket": t2, "code": "000000", "username": u2})
        print(f"    attempt {i+1}: HTTP {st_v}  {json.dumps(rv)[:130]}")
        if st_v != 400 or str(rv.get("code")) != "wrong":
            break
    st, r3 = game("/api/auth/code", "POST",
                  {"mode": "signup", "name": "Probe", "username": u2, "email": addr, "adult": True})
    print(f"  immediately request a new code -> HTTP {st}  {json.dumps(r3)[:170]}")

json.dump({"email": addr, "username": username, "code": code, "verify": r, "me": me},
          open("/tmp/ll_newauth.json", "w"), indent=2)
print("\n-> /tmp/ll_newauth.json")
