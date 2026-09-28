#!/usr/bin/env python3
"""Pre-vet v3 — the pipeline the provably-fair skill prescribes:
  harvest addresses from a project's own bundle  ->  keep only those that are REAL
  CONTRACTS (eth_getCode != 0x) on the pinned chain  ->  then check proxy/impl verification.
This kills the two v2 faults: cross-chain attribution and bytecode-fragment noise."""
import json, re, urllib.request, urllib.error, time, urllib.parse

UA = {"User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) Chrome/128.0 Safari/537.36"}
RPC = {"base":"https://mainnet.base.org","ethereum":"https://eth.llamarpc.com",
       "arbitrum":"https://arb1.arbitrum.io/rpc","optimism":"https://mainnet.optimism.io",
       "polygon":"https://polygon-rpc.com","monad":"https://rpc.monad.xyz"}
BS  = {"base":"base.blockscout.com","ethereum":"eth.blockscout.com","arbitrum":"arbitrum.blockscout.com",
       "optimism":"optimism.blockscout.com","polygon":"polygon.blockscout.com","monad":"monad.blockscout.com"}
CANON = {"0x4200000000000000000000000000000000000006","0x833589fcd6edb6e08f4c7c32d4f71b54bda02913",
         "0xca11bde05977b3631167028862be2a173976ca11","0x000000000022d473030f116ddee9f6b43ac78ba3",
         "0x0000000000000000000000000000000000000000","0xeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"}

def get(url, t=25, raw=False):
    try:
        with urllib.request.urlopen(urllib.request.Request(url, headers=UA), timeout=t) as r:
            b = r.read().decode("utf-8", "replace")
        return b if raw else json.loads(b)
    except Exception as e:
        return f"__ERR__{type(e).__name__}" if raw else {"__err__": type(e).__name__}

def rpc(chain, method, params):
    url = RPC.get(chain)
    if not url: return None
    body = json.dumps({"jsonrpc":"2.0","id":1,"method":method,"params":params}).encode()
    try:
        with urllib.request.urlopen(urllib.request.Request(
                url, data=body, headers={**UA,"Content-Type":"application/json"}), timeout=25) as r:
            return json.loads(r.read()).get("result")
    except Exception:
        return None

def harvest(origin):
    if not origin: return set(), None
    if not origin.startswith("http"): origin = "https://" + origin
    html = get(origin, 25, raw=True)
    if not isinstance(html, str) or html.startswith("__ERR__"): return set(), None
    blob = html
    refs = set(re.findall(r'(?:src|href)="([^"]+\.js[^"]*)"', html))
    refs |= set(re.findall(r'["\'](/(?:assets|static|_next|js|build|chunks?)/[A-Za-z0-9._/-]+\.js)["\']', html))
    for r_ in list(refs)[:30]:
        b = get(urllib.parse.urljoin(origin, r_), 20, raw=True)
        if isinstance(b, str) and not b.startswith("__ERR__"): blob += b
        time.sleep(0.05)
    # pin the chain from the bundle's own chainId if present
    chain = None
    for m in re.findall(r'chainId["\']?\s*[:=]\s*["\']?(\d+)', blob)[:40]:
        chain = {"8453":"base","1":"ethereum","42161":"arbitrum","10":"optimism","137":"polygon",
                 "143":"monad"}.get(m, chain)
        if chain: break
    addrs = set(a.lower() for a in re.findall(r'0x[a-fA-F0-9]{40}', blob))
    return {a for a in addrs if a not in CANON}, chain

TARGETS = [
  ("Charity Billionaire", "Yield Lottery", "Base", None, "https://x.com/"),
  ("Hot Take",            "Prediction Market", "Base", None, None),
  ("TayDex",              "Prediction Market", "Base", "https://taydex.fun", None),
]

protos = get("https://api.llama.fi/protocols")
byname = {p["name"]: p for p in protos} if isinstance(protos, list) else {}

for name, cat, chain_hint, url_hint, _ in TARGETS:
    p = byname.get(name, {})
    url = url_hint or p.get("url") or ""
    tw  = p.get("twitter")
    print(f"═══ {name} [{cat}] · tvl=${round(p.get('tvl') or 0):,} · audits={p.get('audits')} · twitter={tw or '—'}")
    if not url:
        print("    no site URL on DefiLlama and twitter handle not resolvable here — needs a manual entry point\n")
        continue
    addrs, pinned = harvest(url)
    chain = pinned or chain_hint.lower()
    print(f"    site={url}  chain_hint={chain_hint}  pinned-from-bundle={pinned}  -> using '{chain}'")
    print(f"    harvested {len(addrs)} non-canonical addresses; testing each with eth_getCode...")
    real = []
    for a in sorted(addrs):
        code = rpc(chain, "eth_getCode", [a, "latest"])
        if code and len(code) > 2:
            real.append((a, (len(code)-2)//2))
    print(f"    REAL CONTRACTS on {chain}: {len(real)} of {len(addrs)}")
    host = BS.get(chain)
    for a, size in real[:8]:
        if not host:
            print(f"      {a}  code={size:,} bytes (no explorer route)"); continue
        d = get(f"https://{host}/api/v2/smart-contracts/{a}")
        ver, nm, pt = d.get("is_verified"), d.get("name"), d.get("proxy_type")
        line = f"      {a} {size:>6,}B verified={str(ver):5} {str(nm)[:24]:24}"
        imps = d.get("implementations") or []
        if imps:
            ia = imps[0].get("address_hash")
            di = get(f"https://{host}/api/v2/smart-contracts/{ia}")
            line += f" → impl {ia[:10]}.. verified={di.get('is_verified')}"
            if ver and di.get("is_verified") is False: line += "  <<< VERIFIED PROXY, UNVERIFIED IMPL"
        print(line)
        time.sleep(0.3)
    print()
