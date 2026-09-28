#!/usr/bin/env python3
"""Focused recon on the top two candidates: do they have REAL, SOURCE-VERIFIED contracts?

Fixes two flaws from _prev_v4:
  - must exclude chain PREdeploys/system contracts (0x4200..00xx on Base/OP, 0x0000..00xx) --
    those were reported "VERIFIED" and are not the project's contracts
  - must follow the app's JS bundles (Next.js chunks), not just the HTML, or SPAs yield nothing

Targets: GILDer ($118K Base Yield 45.7d) and Enhanced ($156K Ethereum Yield 45d), both unaudited.
"""
import json, os, re, time, urllib.error, urllib.request

BASE = os.path.dirname(os.path.abspath(__file__))
UA = ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/128.0 Safari/537.36")
RPC = {"Ethereum": "https://eth.llamarpc.com", "Base": "https://mainnet.base.org",
       "Arbitrum": "https://arb1.arbitrum.io/rpc"}
EXPL = {"Ethereum": ("eth.blockscout.com", 1), "Base": ("base.blockscout.com", 8453),
        "Arbitrum": ("arbitrum.blockscout.com", 42161)}

def get(url, t=25, raw=True, tries=2):
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
        time.sleep(0.7)
    return "__ERR__" if raw else {}

def rpc(chain, method, params):
    url = RPC.get(chain)
    if not url: return None
    try:
        req = urllib.request.Request(url, data=json.dumps(
            {"jsonrpc": "2.0", "id": 1, "method": method, "params": params}).encode(),
            headers={"Content-Type": "application/json", "User-Agent": UA})
        return json.loads(urllib.request.urlopen(req, timeout=25).read()).get("result")
    except Exception:
        return None

ADDR_RX = re.compile(r"0x[a-fA-F0-9]{40}")

def is_system(addr):
    """Chain predeploys / system contracts / known infrastructure -- not the project's own."""
    a = addr.lower()
    if a.startswith("0x420000000000000000000000000000000000"):
        return True                                    # OP-stack predeploys
    if a[:24] == "0x000000000000000000000000" and int(a, 16) < 2**64:
        return True                                    # low-number system contracts
    CANON = {
        "0x4200000000000000000000000000000000000006",  # WETH (Base)
        "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913",  # USDC (Base)
        "0xca11bde05977b3631167028862be2a173976ca11",  # multicall3
        "0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2",  # WETH
        "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48",  # USDC
        "0x6b175474e89094c44da98b954eedeac495271d0f",  # DAI
        "0x2260fac5e5542a773aa44fbcfedf7c193bc2c599",  # WBTC
        "0x000000000022d473030f116ddee9f6b43ac78ba3",  # permit2
        "0x0000000071727de22e5e9d8baf0edac6f37da032",  # ERC-4337 EP v0.7
        "0x5ff137d4b0fdcd49dca30c7cf57e578a026d2789",  # ERC-4337 EP v0.6
        "0x64ff637fb478863b7468bc97d30a5bf3a428a1fd",
        "0x1f98431c8ad98523631ae4a59f267346ea31f984",  # Uniswap V3 factory
        "0x7a250d5630b4cf539739df2c5dacb4c659f2488d",  # UniV2 router
        "0xe592427a0aece92de3edee1f18e0157c05861564",  # UniV3 router
        "0x68b3465833fb72a70ecdf485e0e4c7bd8665fc45",
        "0x1111111254eeb25477b68fb85ed929f73a960582",  # 1inch
    }
    return a in CANON

def collect(url, chain, depth_bundles=10):
    """HTML + its JS bundles -> candidate addresses."""
    if not url.startswith("http"):
        url = "https://" + url
    found, seen_src = set(), set()
    html = get(url)
    if html == "__ERR__":
        print(f"    (HTML fetch failed for {url})")
        return set(), 0
    print(f"    HTML {len(html):,}B")
    for m in ADDR_RX.finditer(html):
        found.add(m.group(0).lower())
    origin = re.match(r"(https?://[^/]+)", url)
    origin = origin.group(1) if origin else url
    srcs = re.findall(r'<script[^>]+src=["\']([^"\']+)["\']', html)
    # Next.js: also pick chunk paths out of inline scripts
    srcs += re.findall(r'["\'](/_next/static/[^"\']+\.js)["\']', html)
    srcs += re.findall(r'["\'](/assets/[^"\']+\.js)["\']', html)
    norm, njs = [], 0
    for s in srcs:
        if s.startswith("//"): s = "https:" + s
        elif s.startswith("/"): s = origin + s
        if s.startswith("http") and s not in seen_src:
            seen_src.add(s); norm.append(s)
    for s in norm[:depth_bundles]:
        js = get(s)
        if js == "__ERR__": continue
        njs += 1
        for m in ADDR_RX.finditer(js):
            found.add(m.group(0).lower())
    return found, njs

def verify(chain, addr):
    expl, cid = EXPL.get(chain, (None, None))
    if expl:
        d = get(f"https://{expl}/api/v2/smart-contracts/{addr}", raw=False)
        if isinstance(d, dict) and d:
            if d.get("is_verified") or d.get("source_code"):
                return True, len(d.get("source_code") or ""), "blockscout"
            if "is_verified" in d or "source_code" in d:
                return False, 0, "blockscout"
    return None, 0, "-"

CANDS = [("GILDer", "https://gilderfinance.com/", "Base", 118091, 45.7),
         ("Enhanced", "https://enhanced.fi", "Ethereum", 156326, 45.0),
         ("Enhanced(@enhanced_defi)", "https://www.enhanced.finance", "Ethereum", 156326, 45.0)]

for name, url, chain, tvl, age in CANDS:
    print("=" * 100)
    print(f"{name}   ${tvl:,}  {age}d  {chain}   {url}")
    print("=" * 100)
    addrs, njs = collect(url, chain)
    cand = [a for a in addrs if not is_system(a)]
    print(f"    bundles read: {njs}   raw addrs {len(addrs)}   non-system {len(cand)}")
    real, ver = [], []
    for a in cand[:20]:
        code = rpc(chain, "eth_getCode", [a, "latest"])
        if isinstance(code, str) and len(code) > 4:
            size = len(code[2:]) // 2
            v, sl, note = verify(chain, a)
            real.append((a, size))
            if v:
                ver.append((a, size, sl, note))
    print(f"    real contracts: {len(real)}   verified: {len(ver)}")
    for a, size in sorted(real, key=lambda t: -t[1])[:8]:
        v, sl, note = verify(chain, a)
        mark = "VERIFIED" if v else ("unverified" if v is False else "?")
        print(f"       {a}  {size:>7,}B runtime   {mark} {note} src={sl}B")
    print()
