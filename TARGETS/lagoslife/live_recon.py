#!/usr/bin/env python3
"""
Lagos Life live recon - READ ONLY, unauthenticated.

Goal: confirm the live API's real shape before creating any account:
  - does the server answer JSON at these routes? (content-type, not status)
  - what does an unauthenticated /api/save look like?
  - what does /api/auth/register require? (schema oracle - read the RULE, not the status)
  - order of checks: auth before body validation, or body validation before auth?

Deliberately NOT doing here: no account creation, no writes, no PUT.
"""
import json, urllib.request, urllib.error

BASE = "https://lagoslife.eliysites.com"
UA = ("Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/125.0 Safari/537.36")


def req(path, method="GET", body=None, extra_headers=None):
    url = BASE + path
    headers = {"User-Agent": UA, "Accept": "application/json, text/plain, */*"}
    data = None
    if body is not None:
        data = json.dumps(body).encode()
        headers["Content-Type"] = "application/json"
    headers.update(extra_headers or {})
    r = urllib.request.Request(url, method=method, data=data, headers=headers)
    try:
        with urllib.request.urlopen(r, timeout=30) as resp:
            raw = resp.read()
            return resp.status, resp.headers.get("content-type", ""), raw
    except urllib.error.HTTPError as e:
        return e.code, e.headers.get("content-type", ""), e.read()
    except Exception as e:
        return None, f"ERR {e}", b""


def show(label, path, method="GET", body=None):
    st, ct, raw = req(path, method, body)
    txt = raw[:400].decode("utf-8", "replace").replace("\n", " ")
    print(f"\n--- {label}\n    {method} {path}\n    HTTP {st}  ct={ct}\n    {txt}")


print("=" * 90)
print("UNAUTHENTICATED RECON (read-only)")
print("=" * 90)

show("version", "/api/version")
show("geo (open?)", "/api/geo")
show("daily (need auth?)", "/api/daily")
show("forbes (public leaderboard?)", "/api/forbes")
show("THE SAVE - unauth GET", "/api/save")
show("save backup - unauth GET", "/api/save/backup")
show("old-account - unauth GET", "/api/save/old-account")
show("auth/me - unauth", "/api/auth/me")
show("players (public dir?)", "/api/players?q=a")
show("world", "/api/world")

print("\n" + "=" * 90)
print("SCHEMA ORACLE — register with junk, read the RULE not the status")
print("=" * 90)
show("register: empty body", "/api/auth/register", "POST", {})
show("register: junk keys", "/api/auth/register", "POST", {"foo": "bar"})
show("register: only username", "/api/auth/register", "POST", {"username": "x"})
show("login: junk", "/api/auth/login", "POST", {"username": "nope_nope", "password": "nope"})

print("\n" + "=" * 90)
print("ORDER OF CHECKS — does /api/save validate body before auth?")
print("=" * 90)
show("save PUT unauth, junk body", "/api/save", "PUT", {"game": {"money": 1e12}})
show("save PUT unauth, empty body", "/api/save", "PUT", {})
