#!/usr/bin/env python3
"""Target census: (a) new EVM protocols off DefiLlama under the size/age filter,
(b) gambling/casino candidates off dapp-directory lists (DefiLlama does not index
consumer casinos). Prints only candidates — filtering happens here, not in context."""
import json, urllib.request, urllib.error, time, datetime, re

UA = {"User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) Chrome/128.0 Safari/537.36"}

def get(url, timeout=60):
    try:
        with urllib.request.urlopen(urllib.request.Request(url, headers=UA), timeout=timeout) as r:
            return r.read().decode("utf-8", "replace")
    except Exception as e:
        return f"__ERR__{type(e).__name__}:{e}"

print("=" * 78)
print("A) DefiLlama — new/small EVM protocols (< $200K TVL), non-DEX")
print("=" * 78)
raw = get("https://api.llama.fi/protocols")
try:
    protos = json.loads(raw)
except Exception as e:
    print("  fetch/parse failed:", raw[:200]); protos = []

EVM = {"Ethereum","Base","Arbitrum","Optimism","Polygon","BSC","Avalanche","Gnosis","Fantom",
       "Celo","Linea","Scroll","Blast","Manta","Mode","zkSync Era","Polygon zkEVM","opBNB",
       "Metis","Mantle","Berachain","Sonic","Unichain","World Chain","Abstract","HyperEVM","Monad"}
SKIP_CAT = {"Dexes","DEX Aggregator","Lending","Liquid Staking","Bridge","CEX","Chain"}

# discover the shape once
if protos:
    print("  fields available:", ", ".join(sorted(protos[0].keys()))[:400])
    now = time.time()
    cands = []
    for p in protos:
        tvl = p.get("tvl") or 0
        cat = p.get("category") or ""
        chains = set(p.get("chains") or [])
        if not (0 < tvl < 200_000):            continue
        if cat in SKIP_CAT:                    continue
        if not (chains & EVM):                 continue
        listed = p.get("listedAt")
        age_d = (now - listed) / 86400 if listed else None
        cands.append({
            "name": p.get("name"), "cat": cat, "tvl": round(tvl),
            "chains": sorted(chains & EVM)[:3], "listed_days": round(age_d, 1) if age_d else None,
            "url": p.get("url"), "audits": p.get("audit_links") or p.get("audits") or [],
            "audit_n": p.get("audit_note") or "", "mcap": p.get("mcap"),
            "oracles": p.get("oracles"), "change_7d": p.get("change_7d"),
        })
    # newest first, then smallest
    cands.sort(key=lambda c: (c["listed_days"] if c["listed_days"] is not None else 9e9))
    print(f"\n  {len(cands)} candidates in the size band. Newest 25:")
    for c in cands[:25]:
        aud = "AUDITED" if c["audits"] else "no-audit"
        print(f"   {c['name'][:28]:28} {c['cat'][:18]:18} ${c['tvl']:>7,} "
              f"{str(c['listed_days']):>6}d {aud:9} {','.join(c['chains'])[:22]}")
    # category histogram of ALL small non-DEX EVM
    from collections import Counter
    print("\n  category mix in band:", dict(Counter(c["cat"] for c in cands).most_common(12)))
    json.dump(cands, open("/root/.hermes/workspace/SAVAGEAUD/TARGETS/_census_defillama.json","w"), indent=1)

print()
print("=" * 78)
print("B) Gambling/casino discovery — dapp directories (DefiLlama has no casino bucket)")
print("=" * 78)
dirs = [
 ("Alchemy dapp store / decentralized games on Base", "https://www.alchemy.com/dapps/list-of/decentralized-games-on-base"),
 ("Alchemy dapp store / decentralized games on Arbitrum", "https://www.alchemy.com/dapps/list-of/decentralized-games-on-arbitrum"),
 ("DappRadar gambling dapps", "https://dappradar.com/rankings/category/gambling"),
]
for label, url in dirs:
    body = get(url, timeout=45)
    if body.startswith("__ERR__"):
        print(f"  {label}: {body[:80]}"); continue
    # pull dapp names + any outbound links
    hosts = sorted(set(re.findall(r'https?://([a-z0-9.-]+\.[a-z]{2,})', body)))
    dapps = sorted(set(re.findall(r'data-dapp-name="([^"]{2,40})"', body)))[:20]
    print(f"  {label}: {len(body)} bytes, {len(hosts)} hosts")
    interesting = [h for h in hosts if not re.search(
        r'alchemy|google|gstatic|cloudflare|twitter|x\.com|discord|github|youtube|linkedin|'
        r'facebook|instagram|medium|reddit|apple|amazonaws|sentry|segment|hotjar|intercom', h)]
    print(f"     candidate hosts: {', '.join(interesting[:18])}")
    if dapps: print(f"     dapp names: {', '.join(dapps)}")
