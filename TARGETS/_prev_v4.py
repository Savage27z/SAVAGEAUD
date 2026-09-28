#!/usr/bin/env python3
"""Pre-vet v4 — rank the CLEAN shortlist (genuinely new + unaudited + non-DEX) and check the two
things that decide whether a target is audit-able at all:
  1. do real CONTRACTS exist on the stated chain?          (eth_getCode != 0x)
  2. is there SOURCE to read?                              (Blockscout v2 + Sourcify)
TayDex died on (2): unverified impls, no source, fork-only testing. Never pick blind again.

Also fixes the census's age_d flaw: age_d == 0.0 means "no listing date" and is dominated by
2020-2021 legacy protocols, so those are excluded here.
"""
import json, os, re, time, urllib.error, urllib.request

BASE = os.path.dirname(os.path.abspath(__file__))
UA = ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/128.0 Safari/537.36")

RPC = {"Ethereum": "https://eth.llamarpc.com", "Base": "https://mainnet.base.org",
       "Arbitrum": "https://arb1.arbitrum.io/rpc", "Optimism": "https://mainnet.optimism.io",
       "Polygon": "https://polygon-rpc.com", "Avalanche": "https://api.avax.network/ext/bc/C/rpc",
       "Monad": "https://rpc.monad.xyz", "Fantom": "https://rpc.ftm.tools",
       "Mantle": "https://rpc.mantle.xyz", "BSC": "https://bsc-dataseed.binance.org"}
EXPL = {"Ethereum": ("eth.blockscout.com", 1), "Base": ("base.blockscout.com", 8453),
        "Arbitrum": ("arbitrum.blockscout.com", 42161), "Optimism": ("optimism.blockscout.com", 10),
        "Polygon": ("polygon.blockscout.com", 137),
        "Avalanche": ("avalanche.blockscout.com", 43114), "Monad": ("monad.blockscout.com", 143),
        "Mantle": ("mantle.blockscout.com", 5000)}
CANON = {"0x4200000000000000000000000000000000000006",
         "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913",
         "0xca11bde05977b3631167028862be2a173976ca11",
         "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48",
         "0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2",
         "0x000000000022d473030f116ddee9f6b43ac78ba3",
         "0x0000000000000000000000000000000000000000",
         "0xeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"}

def get(url, t=25, raw=False, tries=2):
    for a in range(tries):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": UA,
                                                       "Accept": "*/*"})
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
        time.sleep(0.8 + a)
    return "__ERR__" if raw else {}

def rpc(chain, method, params):
    url = RPC.get(chain)
    if not url:
        return None
    body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method,
                       "params": params}).encode()
    try:
        req = urllib.request.Request(url, data=body,
                                     headers={"Content-Type": "application/json", "User-Agent": UA})
        return json.loads(urllib.request.urlopen(req, timeout=25).read()).get("result")
    except Exception:
        return None

ADDR_RX = re.compile(r"0x[a-fA-F0-9]{40}")

def harvest(url):
    """Collect candidate addresses from a project's own page (and its JS bundles)."""
    if not url:
        return set()
    if not url.startswith("http"):
        url = "https://" + url
    found = set()
    html = get(url, 25, raw=True)
    if html == "__ERR__":
        return found
    for m in ADDR_RX.finditer(html):
        found.add(m.group(0).lower())
    # follow script bundles, favicons excluded
    for src in re.findall(r'<script[^>]+src=["\']([^"\']+)["\']', html)[:6]:
        if src.startswith("//"):
            src = "https:" + src
        elif src.startswith("/"):
            base = re.match(r'(https?://[^/]+)', url)
            src = (base.group(1) if base else url) + src
        if src.startswith("http"):
            js = get(src, 25, raw=True)
            if js != "__ERR__":
                for m in ADDR_RX.finditer(js):
                    found.add(m.group(0).lower())
    return {a for a in found if a not in CANON}

def name_from_slug(url):
    return (url or "").rsplit("/", 1)[-1].lower()

def check_verified(chain, addr):
    """Returns (verified, source_len, note) using Blockscout v2 then Sourcify."""
    expl, cid = EXPL.get(chain, (None, None))
    if expl:
        d = get(f"https://{expl}/api/v2/smart-contracts/{addr}")
        if isinstance(d, dict) and d:
            if d.get("is_verified") or d.get("source_code"):
                src = d.get("source_code") or ""
                return True, len(src), "blockscout"
            if "is_verified" in d or "source_code" in d:
                return False, 0, "blockscout(unverified)"
    if cid:
        d = get(f"https://sourcify.dev/server/v2/contract/{cid}/{addr}")
        st = (d or {}).get("match") or (d or {}).get("status")
        if st in ("exact_match", "match", "full", "partial"):
            return True, 0, f"sourcify:{st}"
    return None, 0, "unknown"

# ---------- load the CLEAN shortlist ----------
data = json.load(open(os.path.join(BASE, "_census_unaudited.json")))
clean = [x for x in data if (x.get("age_d") or 0) >= 3 and not x.get("audit_links")]
clean.sort(key=lambda x: -(x.get("tvl") or 0))
print(f"clean shortlist: {len(clean)} targets (new + unaudited + non-DEX)\n")

TOP = clean[:12]
print("=" * 104)
print("PRE-VET: do real contracts exist, and is there SOURCE to read?")
print("=" * 104)
results = []
for x in TOP:
    name, url = x["name"], (x.get("url") or "")
    chain = (x.get("chains") or ["Ethereum"])[0]
    print(f"\n### {name}   ${x['tvl']:,.0f}  {x['age_d']:.1f}d  {chain}  {url or '@'+(x.get('twitter') or '')}")
    addrs = harvest(url)
    print(f"  addresses harvested: {len(addrs)}")
    if not addrs:
        print("  -> no addresses found on the page (JS-only or blocked). Needs manual recon.")
        results.append({"name": name, "tvl": x["tvl"], "chain": chain, "contracts": 0,
                        "verified": 0, "note": "no-addresses"})
        continue
    real, verified, srcbytes = [], [], 0
    for a in list(addrs)[:14]:
        code = rpc(chain, "eth_getCode", [a, "latest"])
        if isinstance(code, str) and len(code) > 4:
            real.append(a)
            v, sl, note = check_verified(chain, a)
            if v:
                verified.append(a)
                srcbytes += sl
    print(f"  real contracts on {chain}: {len(real)}   with source: {len(verified)}")
    for a in real[:6]:
        v, sl, note = check_verified(chain, a)
        mark = "VERIFIED" if v else ("unverified" if v is False else "unknown")
        print(f"     {a}  {mark} {note} src={sl}B")
    results.append({"name": name, "tvl": x["tvl"], "chain": chain,
                    "contracts": len(real), "verified": len(verified), "srcbytes": srcbytes,
                    "note": ""})

print("\n" + "=" * 104)
print("RANKED BY AUDIT-ABILITY (source available) x VALUE")
print("=" * 104)
results.sort(key=lambda r: (-(r["verified"]), -(r["tvl"] or 0)))
print(f"{'target':<26}{'TVL':>10}  {'chain':<11}{'contracts':>10}{'w/ source':>10}  note")
for r in results:
    print(f"{r['name'][:25]:<26}{(r['tvl'] or 0):>10,.0f}  {r['chain'][:10]:<11}"
          f"{r['contracts']:>10}{r['verified']:>10}  {r['note']}")
json.dump(results, open(os.path.join(BASE, "_prevetshortlist_v4.json"), "w"), indent=1)
print("\n[saved] _prevetshortlist_v4.json")
