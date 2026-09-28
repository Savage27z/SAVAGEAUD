#!/usr/bin/env python3
"""Pre-vet the shortlist properly. For each candidate: resolve its chain case-insensitively,
take DefiLlama's address if present, otherwise harvest 0x addresses from the project's own
site/bundle, then check verification + proxy->impl on the matching Blockscout."""
import json, re, urllib.request, urllib.error, time, tempfile, subprocess, os

UA = {"User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) Chrome/128.0 Safari/537.36"}
BS = {"ethereum":"eth.blockscout.com","base":"base.blockscout.com","arbitrum":"arbitrum.blockscout.com",
      "optimism":"optimism.blockscout.com","polygon":"polygon.blockscout.com","gnosis":"gnosis.blockscout.com",
      "scroll":"scroll.blockscout.com","zksync era":"zksync.blockscout.com","berachain":"berachain.blockscout.com",
      "monad":"monad.blockscout.com","mantle":"mantle.blockscout.com","sonic":"sonic.blockscout.com",
      "linea":"linea.blockscout.com","blast":"blast.blockscout.com","abstract":"abstract.blockscout.com",
      "unichain":"unichain.blockscout.com","world chain":"world.blockscout.com","hyperevm":"hyperevm.blockscout.com"}

KNOWN = {  # canonical infra to drop from bundle harvests
 "0x4200000000000000000000000000000000000006":"WETH(Base predeploy)",
 "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913":"USDC(Base)",
 "0xcA11bde05977b3631167028862bE2a173976CA11":"Multicall3",
 "0x000000000022D473030F116dDEE9F6B43aC78BA3":"Permit2",
 "0x0000000000000000000000000000000000000000":"zero",
}

def get(url, t=30, raw=False):
    try:
        with urllib.request.urlopen(urllib.request.Request(url, headers=UA), timeout=t) as r:
            b = r.read().decode("utf-8", "replace")
        return b if raw else json.loads(b)
    except Exception as e:
        return f"__ERR__{type(e).__name__}" if raw else {"__err__": type(e).__name__}

def harvest(origin):
    """HTML + every same-origin JS chunk -> set of 0x addresses."""
    if not origin: return set()
    if not origin.startswith("http"): origin = "https://" + origin
    html = get(origin, 25, raw=True)
    if not isinstance(html, str) or html.startswith("__ERR__"): return set()
    found = set(re.findall(r'0x[a-fA-F0-9]{40}', html))
    refs = set(re.findall(r'(?:src|href)="([^"]+\.js[^"]*)"', html))
    refs |= set(re.findall(r'["\'](/(?:assets|static|_next|js|build|chunks?)/[A-Za-z0-9._/-]+\.js)["\']', html))
    for r_ in list(refs)[:25]:
        u = urllib.parse.urljoin(origin, r_)
        body = get(u, 20, raw=True)
        if isinstance(body, str) and not body.startswith("__ERR__"):
            found |= set(re.findall(r'0x[a-fA-F0-9]{40}', body))
        time.sleep(0.1)
    return found

import urllib.parse
cand = json.load(open("/root/.hermes/workspace/SAVAGEAUD/TARGETS/_census_unaudited.json"))
protos = get("https://api.llama.fi/protocols")
byname = {p["name"]: p for p in protos} if isinstance(protos, list) else {}
FOCUS = ["Charity Billionaire","Hot Take","TayDex","Antseed","Stochastic Finance","TermiX",
         "AlfaClub","Bonker","HRUSD","zERC20","Prodigy.Fi V2","Ref Market"]

for c in cand:
    if c["name"] not in FOCUS: continue
    p = byname.get(c["name"], {})
    raw = (p.get("address") or "")
    chain = c["chains"][0] if c["chains"] else "?"
    dl_addr = ""
    if ":" in raw:
        pref, dl_addr = raw.split(":", 1); chain = pref
    host = BS.get(chain.lower())
    print(f"═══ {c['name']}  [{c['cat']}] ${c['tvl']:,} · {c['age_d']}d · audits={c['audits']}")
    print(f"    chain={chain}  url={c['url'] or '—'}")
    targets = []
    if dl_addr and host:
        targets.append(("defillama", dl_addr))
    if c.get("url") and host:
        hs = harvest(c["url"])
        new = [a for a in hs if a.lower() not in {k.lower() for k in KNOWN}]
        print(f"    harvested {len(hs)} addresses from its site ({len(new)} non-canonical)")
        for a in new[:6]:
            targets.append(("site", a))
    if not host:
        print(f"    no Blockscout route for chain '{chain}' — cannot pre-vet here\n"); continue
    seen = set()
    for src, a in targets:
        if a.lower() in seen: continue
        seen.add(a.lower())
        d = get(f"https://{host}/api/v2/smart-contracts/{a}")
        ver, nm, pt = d.get("is_verified"), d.get("name"), d.get("proxy_type")
        tag = ""
        imps = d.get("implementations") or []
        if imps:
            ia = imps[0].get("address_hash")
            di = get(f"https://{host}/api/v2/smart-contracts/{ia}")
            iver = di.get("is_verified")
            tag = f" → impl {ia[:10]}.. verified={iver} {di.get('name')!r}"
            if iver is False and ver: tag += "   <<< VERIFIED PROXY, UNVERIFIED IMPL"
        print(f"      [{src:9}] {a} verified={str(ver):5} {str(nm)[:26]:26}{tag}")
        time.sleep(0.3)
    print()
