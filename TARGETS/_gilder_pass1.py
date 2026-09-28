#!/usr/bin/env python3
"""GILDer — Phase 0 recon (target: gilderfinance.com, Base, $118K, 45.7d, unaudited, non-DEX).

Why this target: it is the highest-value candidate on the clean shortlist whose SOURCE IS PUBLIC.
TayDex failed on exactly that -- unverified impls, no source, fork-only testing. Pre-vet oracle:
Sourcify v2 `?fields=all` (Blockscout's verification check is broken on this box).

Do it: harvest the app's addresses -> Sourcify-check each -> identify the system -> save source.
Read-only: public GETs.
"""
import json, os, re, time, urllib.error, urllib.request

BASE = os.path.dirname(os.path.abspath(__file__))
TGT = os.path.join(BASE, "gilder")
SRC = os.path.join(TGT, "src")
os.makedirs(SRC, exist_ok=True)
UA = ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/128.0 Safari/537.36")
SITE = "https://gilderfinance.com/"
CHAIN = 8453
RPC = "https://mainnet.base.org"

def get(url, t=30, raw=True, tries=3):
    for a in range(tries):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": UA, "Accept": "*/*"})
            b = urllib.request.urlopen(req, timeout=t).read().decode("utf-8", "replace")
            return b if raw else json.loads(b)
        except urllib.error.HTTPError as e:
            try:
                b = e.read().decode("utf-8", "replace")
                return b if raw else json.loads(b)
            except Exception:
                pass
        except Exception:
            pass
        time.sleep(0.8 + 0.4 * a)
    return "__ERR__" if raw else {}

def rpc(method, params):
    try:
        req = urllib.request.Request(RPC, data=json.dumps(
            {"jsonrpc": "2.0", "id": 1, "method": method, "params": params}).encode(),
            headers={"Content-Type": "application/json", "User-Agent": UA})
        return json.loads(urllib.request.urlopen(req, timeout=25).read()).get("result")
    except Exception:
        return None

ADDR_RX = re.compile(r"0x[a-fA-F0-9]{40}")

def is_system(a):
    a = a.lower()
    if a.startswith("0x420000000000000000000000000000000000"):
        return True
    if a[:26] == "0x000000000000000000000000" and int(a, 16) < 2**96:
        return True
    KNOWN = {
        "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913",  # USDC Base
        "0x4200000000000000000000000000000000000006",  # WETH
        "0xca11bde05977b3631167028862be2a173976ca11",  # multicall3
        "0x000000000022d473030f116ddee9f6b43ac78ba3",  # permit2
        "0x0000000071727de22e5e9d8baf0edac6f37da032",  # EP v0.7
        "0x2626664c2603336e57b271c5c0b26f421741e481",  # Uniswap Universal Router (Base)
        "0x33128a8fc17869897dce68ed026d694621f6fdfd",  # UniV3 factory Base
        "0x4752ba5dbc23f44d87826276bf6fd6b1c372ad24",  # UniV2 router Base
        "0x198ef79f1f515f02dfe9e3115ed9fc07183f02fc",  # UniV3 NFT manager Base
    }
    return a in KNOWN

# ---------- harvest ----------
print("=" * 100)
print(f"GILDer Phase 0 — {SITE}")
print("=" * 100)
html = get(SITE)
if html == "__ERR__":
    raise SystemExit("site fetch failed")
print(f"HTML {len(html):,}B")
origin = re.match(r"(https?://[^/]+)", SITE).group(1)
srcs = re.findall(r'<script[^>]+src=["\']([^"\']+)["\']', html)
srcs += re.findall(r'["\'](/_next/static/[^"\']+\.js)["\']', html)
srcs += re.findall(r'["\'](/assets/[^"\']+\.js)["\']', html)
seen, norm = set(), []
for s in srcs:
    if s.startswith("//"): s = "https:" + s
    elif s.startswith("/"): s = origin + s
    if s.startswith("http") and s not in seen:
        seen.add(s); norm.append(s)
addrs = {m.group(0).lower() for m in ADDR_RX.finditer(html)}
for s in norm[:16]:
    js = get(s)
    if js != "__ERR__":
        addrs |= {m.group(0).lower() for m in ADDR_RX.finditer(js)}
print(f"bundles: {len(norm)}   raw addresses: {len(addrs)}")

cand = sorted(a for a in addrs if not is_system(a))
print(f"non-system candidates: {len(cand)}\n")

# ---------- Sourcify check each ----------
print("=" * 100)
print("SOURCIFY: which candidates are verified, and what are they?")
print("=" * 100)
found = []
for a in cand:
    code = rpc("eth_getCode", [a, "latest"])
    if not (isinstance(code, str) and len(code) > 4):
        continue
    size = len(code[2:]) // 2
    d = get(f"https://sourcify.dev/server/v2/contract/{CHAIN}/{a}", raw=False)
    match = (d or {}).get("match")
    nsrc, names = 0, []
    if match:
        full = get(f"https://sourcify.dev/server/v2/contract/{CHAIN}/{a}?fields=all", raw=False)
        s = (full or {}).get("sources") or {}
        nsrc = len(s)
        names = list(s)[:6]
        # contract name from metadata compilationTarget (if present)
        md = (full or {}).get("metadata") or {}
        ct = (md.get("settings") or {}).get("compilationTarget") or {}
        contract_name = list(ct.values())
    else:
        contract_name = []
    if match or size > 2000:
        found.append({"addr": a, "size": size, "match": match, "nsrc": nsrc,
                      "files": names, "name": contract_name})
        print(f"  {a}  {size:>7,}B  match={match or '-':<12} srcs={nsrc:<3} "
              f"{contract_name[0] if contract_name else ''} {names[:3]}")

print(f"\n  {len(found)} contract(s) with code; "
      f"{sum(1 for f in found if f['match'])} verified")

json.dump(found, open(os.path.join(TGT, "phase0_contracts.json"), "w"), indent=1)

# ---------- save full source for the verified ones ----------
print("\n" + "=" * 100)
print("SAVING verified source")
print("=" * 100)
saved = 0
for f in found:
    if not f["match"]:
        continue
    full = get(f"https://sourcify.dev/server/v2/contract/{CHAIN}/{f['addr']}?fields=all", raw=False)
    s = (full or {}).get("sources") or {}
    d = os.path.join(SRC, f["addr"])
    os.makedirs(d, exist_ok=True)
    for path, info in s.items():
        content = info.get("content") if isinstance(info, dict) else info
        if not isinstance(content, str):
            continue
        fp = os.path.join(d, path.replace("/", "__"))
        open(fp, "w").write(content)
        saved += 1
    md = (full or {}).get("metadata")
    if md:
        json.dump(md, open(os.path.join(d, "_metadata.json"), "w"), indent=1)
    print(f"  {f['addr']}  {len(s)} file(s) -> {d}")
print(f"\n  total files saved: {saved}")
print(f"  source dir: {SRC}")
