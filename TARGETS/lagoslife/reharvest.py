#!/usr/bin/env python3
"""Re-harvest the live bundle after the sign-up change; diff chunk names vs the frozen set."""
import re, os, json, hashlib, urllib.request

BASE = "https://lagoslife.eliysites.com"
UA = ("Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/125.0 Safari/537.36")
NEW = "bundle_new"
os.makedirs(NEW, exist_ok=True)


def get(url):
    r = urllib.request.Request(url, headers={"User-Agent": UA, "Accept": "*/*"})
    with urllib.request.urlopen(r, timeout=45) as resp:
        return resp.read()


html = get(BASE + "/").decode("utf8", "replace")
urls = sorted(set(re.findall(r'/_next/static/[^"\'\\ )]+?\.js', html)))
print(f"homepage: {len(html)} bytes, {len(urls)} js refs")

# the app sits behind a chunk graph; pull every /_next/static js we can see, then follow refs
seen, todo = {}, list(urls)
while todo:
    u = todo.pop()
    if u in seen:
        continue
    try:
        b = get(BASE + u)
    except Exception as e:
        seen[u] = None; continue
    seen[u] = b
    t = b.decode("utf8", "replace")
    for m in re.findall(r'/_next/static/[^"\'\\ )]+?\.js', t):
        if m not in seen:
            todo.append(m)

ok = {u: b for u, b in seen.items() if b}
print(f"fetched {len(ok)} chunks, {sum(len(b) for b in ok.values())} bytes")

old = set(os.listdir("bundle")) if os.path.isdir("bundle") else set()
new = {}
for u, b in ok.items():
    name = u.split("/_next/static/")[-1].replace("/", "_")
    open(os.path.join(NEW, name), "wb").write(b)
    new[name] = hashlib.sha256(b).hexdigest()

added = sorted(set(new) - old)
missing = sorted(old - set(new))
print(f"\nNEW chunks  : {len(added)}")
for n in added:
    print(f"   + {n}  {new[n][:16]}  {len(ok[[u for u in ok if u.endswith(n.replace('_','/'))][0]]) if any(u.endswith(n.replace('_','/')) for u in ok) else ''}")
print(f"GONE chunks : {len(missing)}")
for n in missing[:12]:
    print(f"   - {n}")
json.dump({"new": added, "missing": missing, "sha": new}, open("reharvest.json", "w"), indent=2)

# hunt the new auth flow
print("\n=== auth-related strings in the live bundle ===")
pats = [r'api/auth/[a-z0-9/_-]+', r'[a-z]*[Cc]ode[a-zA-Z]*', r'sign-?up', r'verify']
found = {}
for name, b in ok.items():
    t = b.decode("utf8", "replace")
    for p in pats[:1]:
        for m in re.findall(p, t):
            found.setdefault(m, set()).add(name)
for k in sorted(found):
    print(f"   {k}   ({len(found[k])} chunk(s))")
