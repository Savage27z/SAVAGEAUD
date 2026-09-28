#!/usr/bin/env python3
"""Pre-vet gate over the shortlist: is the source VERIFIED, and if the address is a
proxy, is the IMPLEMENTATION verified? (A verified proxy hides an unverified impl.)
Also: fetch the dapp directories with headless Chrome for gambling discovery."""
import json, re, subprocess, urllib.request, time, os, tempfile

UA = {"User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) Chrome/128.0 Safari/537.36"}
BS = {"Ethereum":"eth.blockscout.com","Base":"base.blockscout.com","Arbitrum":"arbitrum.blockscout.com",
      "Optimism":"optimism.blockscout.com","Polygon":"polygon.blockscout.com","Gnosis":"gnosis.blockscout.com",
      "Scroll":"scroll.blockscout.com","zkSync Era":"zksync.blockscout.com","Berachain":"berachain.blockscout.com",
      "Monad":"monad.blockscout.com","Mantle":"mantle.blockscout.com","Sonic":"sonic.blockscout.com"}

def get(url, timeout=30):
    try:
        with urllib.request.urlopen(urllib.request.Request(url, headers=UA), timeout=timeout) as r:
            return json.loads(r.read())
    except Exception as e:
        return {"__err__": f"{type(e).__name__}"}

def chrome(url, budget=14000):
    path = tempfile.mktemp(suffix=".html")
    with open(path, "w") as fh:
        subprocess.run(["google-chrome","--headless=new","--disable-gpu","--no-sandbox",
                        "--hide-scrollbars", f"--virtual-time-budget={budget}","--dump-dom",url],
                       stdout=fh, stderr=subprocess.DEVNULL, timeout=150)
    body = open(path,encoding="utf-8",errors="replace").read(); os.unlink(path); return body

protos = get("https://api.llama.fi/protocols")
by_name = {p["name"]: p for p in protos} if isinstance(protos, list) else {}
SHORT = ["Charity Billionaire","Hot Take","TayDex","EnterDAO","The Gavel Protocol",
         "StonkBrokers Desks","Antseed","XAX V2","Stochastic Finance","Dirac Classic Curation",
         "zERC20","Prodigy.Fi V2","fija Finance","Murk Finance","TermiX","AlfaClub","HRUSD","Bonker",
         "Qiro Finance","Ref Market","OpenStock","CEDEX Earn"]

print("═══ PRE-VET — source verification + proxy→impl resolution ═══")
rows=[]
for name in SHORT:
    p = by_name.get(name)
    if not p:
        print(f"  {name[:26]:26} not found in current listing"); continue
    addr = (p.get("address") or "").strip()
    chain = (p.get("chain") or (p.get("chains") or ["?"])[0])
    host = BS.get(chain)
    if not addr:
        print(f"  {name[:26]:26} {chain:10} NO ADDRESS on DefiLlama"); continue
    if not host:
        print(f"  {name[:26]:26} {chain:10} {addr} (no blockscout for this chain)"); continue
    d = get(f"https://{host}/api/v2/smart-contracts/{addr}")
    ver = d.get("is_verified"); nm = d.get("name"); ptype = d.get("proxy_type")
    imps = d.get("implementations") or []
    note = ""
    if imps:
        ia = imps[0].get("address_hash")
        di = get(f"https://{host}/api/v2/smart-contracts/{ia}")
        iver = di.get("is_verified"); inm = di.get("name")
        note = f"impl {ia[:10]}.. verified={iver} name={inm!r}"
    rows.append({"name":name,"chain":chain,"addr":addr,"verified":ver,"contract":nm,
                 "proxy":ptype,"impl_note":note,"cat":p.get("category"),"tvl":round(p.get("tvl") or 0),
                 "age_d":round((time.time()-(p.get("listedAt") or time.time()))/86400,1),
                 "audits":p.get("audits"),"url":p.get("url")})
    print(f"  {name[:26]:26} {chain:10} {addr[:12]}.. verified={str(ver):5} proxy={str(ptype):8} {nm!r}")
    if note: print(f"       └─ {note}")
    time.sleep(0.4)
json.dump(rows, open("/root/.hermes/workspace/SAVAGEAUD/TARGETS/_prevetshortlist.json","w"), indent=1)

print("\n═══ gambling discovery via rendered directories ═══")
for label,url,pat in [("Alchemy games on Base","https://www.alchemy.com/dapps/list-of/decentralized-games-on-base",r"/dapps/([a-z0-9-]+)"),
                      ("DappRadar gambling","https://dappradar.com/rankings/category/gambling",r"/dapp/([a-z0-9-]+)"),
                      ("DappRadar games","https://dappradar.com/rankings/category/games",r"/dapp/([a-z0-9-]+)")]:
    try:
        dom = chrome(url)
    except Exception as e:
        print(f"  {label}: failed ({type(e).__name__})"); continue
    slugs = sorted(set(re.findall(pat, dom)))
    print(f"  {label}: {len(dom):,} bytes -> {len(slugs)} slugs")
    if slugs: print(f"     {', '.join(slugs[:30])}")
