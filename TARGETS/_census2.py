#!/usr/bin/env python3
"""Census v2 — fixes v1's two faults:
  (1) DefiLlama `audits` is an INTEGER count (0-3) plus `audit_links`, not a list.
      v1 labelled every protocol AUDITED off a truthy int. Print the real numbers.
  (2) The dapp directories are JS-rendered -> fetch with headless Chrome, not urllib.
"""
import json, re, subprocess, urllib.request, time, os, tempfile

UA = {"User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) Chrome/128.0 Safari/537.36"}
OUT = "/root/.hermes/workspace/SAVAGEAUD/TARGETS"

def get(url, timeout=60):
    try:
        with urllib.request.urlopen(urllib.request.Request(url, headers=UA), timeout=timeout) as r:
            return r.read().decode("utf-8", "replace")
    except Exception as e:
        return f"__ERR__{type(e).__name__}"

def chrome(url, budget=12000):
    with tempfile.NamedTemporaryFile(suffix=".html", delete=False) as t:
        path = t.name
    subprocess.run(["google-chrome", "--headless=new", "--disable-gpu", "--no-sandbox",
                    "--hide-scrollbars", f"--virtual-time-budget={budget}",
                    "--dump-dom", url], capture_output=True, timeout=120, text=True,
                   stdout=open(path, "w"))
    body = open(path, encoding="utf-8", errors="replace").read()
    os.unlink(path)
    return body

protos = json.loads(get("https://api.llama.fi/protocols"))
now = time.time()
EVM = {"Ethereum","Base","Arbitrum","Optimism","Polygon","BSC","Avalanche","Gnosis","Fantom","Celo",
       "Linea","Scroll","Blast","Manta","Mode","zkSync Era","Polygon zkEVM","opBNB","Metis","Mantle",
       "Berachain","Sonic","Unichain","World Chain","Abstract","HyperEVM","Monad"}

print("=== audit-field control (v1 bug check) ===")
sample = [p for p in protos if (p.get("tvl") or 0) > 1e6][:5]
for p in sample:
    print(f"   {p['name'][:26]:26} audits={p.get('audits')!r} ({type(p.get('audits')).__name__}) "
          f"audit_links={'yes' if p.get('audit_links') else 'none'}")

def band(cat_filter=None, max_tvl=200_000, max_days=60, require_unaudited=False):
    out = []
    for p in protos:
        tvl = p.get("tvl") or 0
        cat = p.get("category") or ""
        chains = set(p.get("chains") or [])
        if not (0 < tvl <= max_tvl): continue
        if not (chains & EVM): continue
        if cat_filter and cat not in cat_filter: continue
        listed = p.get("listedAt")
        age = (now - listed)/86400 if listed else None
        if age is not None and age > max_days: continue
        n_aud = p.get("audits") if isinstance(p.get("audits"), int) else 0
        if require_unaudited and n_aud > 0: continue
        out.append({"name": p["name"], "cat": cat, "tvl": round(tvl), "age_d": round(age,1) if age else None,
                    "chains": sorted(chains & EVM), "audits": n_aud,
                    "audit_links": (p.get("audit_links") or [])[:2], "url": p.get("url"),
                    "twitter": p.get("twitter"), "desc": (p.get("description") or "")[:150]})
    return sorted(out, key=lambda c: (c["audits"], c["age_d"] or 9e9))

print("\n=== GAMBLING-ADJACENT classes in the band (DefiLlama taxonomy) ===")
for cls in [{"Yield Lottery"}, {"Prediction Market"}, {"Gaming"}]:
    rows = band(cls)
    print(f"  -- {list(cls)[0]}: {len(rows)} in band")
    for r in rows[:12]:
        print(f"     {r['name'][:26]:26} ${r['tvl']:>7,} {str(r['age_d']):>5}d audits={r['audits']} "
              f"{','.join(r['chains'])[:18]:18} {(r['url'] or '')[:38]}")

print("\n=== UNAUDITED, <60d, non-DEX, in band — the freshest slots ===")
un = [r for r in band(max_days=60, require_unaudited=True)
      if r["cat"] not in {"Dexs","DEX Aggregator"}]
print(f"  {len(un)} candidates. Top 20 by age:")
for r in un[:20]:
    print(f"   {r['name'][:28]:28} {r['cat'][:17]:17} ${r['tvl']:>7,} {str(r['age_d']):>5}d "
          f"{','.join(r['chains'])[:16]:16} {(r['url'] or '')[:34]}")
json.dump(un, open(f"{OUT}/_census_unaudited.json","w"), indent=1)

print("\n=== dapp directories via headless Chrome (gambling discovery) ===")
for label, url, pat in [
    ("Alchemy: decentralized games on Base", "https://www.alchemy.com/dapps/list-of/decentralized-games-on-base", r"/dapps/([a-z0-9-]+)"),
    ("DappRadar gambling", "https://dappradar.com/rankings/category/gambling", r"/dapp/([a-z0-9-]+)"),
]:
    try:
        dom = chrome(url)
    except Exception as e:
        print(f"  {label}: chrome failed {e}"); continue
    slugs = sorted(set(re.findall(pat, dom)))
    print(f"  {label}: {len(dom)} bytes -> {len(slugs)} slugs")
    print(f"     {', '.join(slugs[:28])}")
