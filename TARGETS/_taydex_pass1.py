#!/usr/bin/env python3
"""TayDex pass 1 — bundle recon + FAIRNESS CLASSIFICATION before any slot is spent.
Classifies: provider-VRF (IEntropy/VRF/getFee/randomNumber) vs server-seed commit-reveal
(seedHash + later revealed seed) vs client-side. Also: module map, API surface, and the
public verifier if one ships."""
import re, json, time, urllib.request, urllib.parse, os

UA = {"User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) Chrome/128.0 Safari/537.36"}
OUT = "/root/.hermes/workspace/SAVAGEAUD/TARGETS/taydex"
os.makedirs(OUT, exist_ok=True)
ORIGIN = "https://taydex.fun"

def get(u, t=25):
    try:
        with urllib.request.urlopen(urllib.request.Request(u, headers=UA), timeout=t) as r:
            return r.read().decode("utf-8", "replace")
    except Exception as e:
        return f"__ERR__{type(e).__name__}"

home = get(ORIGIN)
print(f"═══ {ORIGIN}  ({len(home) if isinstance(home,str) else 0:,} bytes)")
for k in ["_next","__NEXT_DATA__","vite","nuxt","webpack","wagmi","viem","privy","dynamic",
          "reown","walletconnect","erc4337","entrypoint","paymaster","supabase","firebase"]:
    n = len(re.findall(k, home, re.I)) if isinstance(home, str) else 0
    if n: print(f"    marker {k}: {n}")
print("    title:", (re.search(r'<title>([^<]*)</title>', home) or [None,'—'])[1] if isinstance(home,str) else '—')

# harvest chunks
refs = set(re.findall(r'(?:src|href)="([^"]+\.js[^"]*)"', home))
refs |= set(re.findall(r'["\'](/(?:assets|static|_next|js|build|chunks?)/[A-Za-z0-9._/-]+\.js)["\']', home))
print(f"\n═══ module map — {len(refs)} chunks")
blob = home
chunks = {}
for r_ in sorted(refs):
    u = urllib.parse.urljoin(ORIGIN, r_)
    b = get(u)
    if isinstance(b, str) and not b.startswith("__ERR__"):
        chunks[u] = b; blob += b
print(f"    fetched {len(chunks)} chunks, total {len(blob):,} bytes")
names = sorted(set(re.findall(r'([A-Za-z0-9_-]{4,40})\.js', " ".join(refs))))
print("    chunk stems:", ", ".join(names[:28]))

print("\n═══ FAIRNESS CLASSIFICATION (the question that decides the workflow)")
SIG = {
 "provider-VRF / Pyth Entropy": r"IEntropy|entropyCallback|getRandomFee|randomNumber|"
                                r"RandomnessProvider|_entropyCallback|entropyId|requestRandom",
 "Chainlink VRF":               r"VRFCoordinator|requestRandomWords|fulfillRandomWords|vrfCoordinator",
 "server-seed commit-reveal":   r"seedHash|gameSeedHash|commitmentHash|serverSeed|clientSeed|"
                                r"revealedSeed|nonce_|createCommitment",
 "provably-fair tooling":       r"provably[ -]?fair|verifyGame|verifier|fairVerify|verifyRound",
 "graph/offchain outcome":      r"outcomeId|resolveMarket|resolutionSource|uma|optimisticOracle",
 "client-side RNG (red flag)":  r"Math\.random\(\)|crypto\.getRandomValues",
}
hits = {}
for label, rx in SIG.items():
    m = re.findall(rx, blob, re.I)
    hits[label] = len(m)
    print(f"    {label:32} {len(m):>4}   {sorted(set(m))[:6]}")
dom = sorted(set(re.findall(r'https?://([a-z0-9.-]+\.[a-z]{2,})', blob)))
print("\n    external hosts:", ", ".join([d for d in dom if not re.search(r'w3\.org|schema|google|gstatic|github|npm', d)][:22]))

print("\n═══ prediction-market / gambling semantics present?")
for label, rx in {"market/resolve": r"resolveMarket|marketId|outcome|settleMarket|claimWinnings",
                  "bet/stake":      r"placeBet|betAmount|stake\(|wager|position",
                  "house edge":     r"houseEdge|edgeFactor|feeBps|spreadBps|rake",
                  "AA/paymaster":   r"paymaster|UserOperation|userOp|sendUserOperation|bundler",
                  "payout signer":  r"serverSignature|serverSig|signedPayout|payoutAmount"}.items():
    m = re.findall(rx, blob, re.I)
    print(f"    {label:18} {len(m):>4}   {sorted(set(m))[:5]}")

json.dump({"origin":ORIGIN,"chunks":sorted(chunks), "classification":hits,
           "external_hosts":dom}, open(f"{OUT}/pass1_bundle.json","w"), indent=1)
print(f"\n[saved] {OUT}/pass1_bundle.json")
print("    Math.random in bundle:", hits["client-side RNG (red flag)"], "(review context before reacting)")
for m in re.finditer(r'.{70}Math\.random\(\).{70}', blob):
    print("      …", m.group(0).replace("\n"," ")[:150]); break
