#!/usr/bin/env python3
"""TayDex pass19: catalogue the contract's REAL transaction history (Blockscout v2, retried).

Why: the newest tx calls sweepLeftover(24,0). Finding 2 hinges on whether unprivileged addresses
can call it -- so I need the actual callers, per function. Also locates real createMarket calldata
for the actor-binding replay test.

Read-only: public explorer API.
"""
import json, os, time, urllib.error, urllib.parse, urllib.request

C = "0x3ade22fa1ef5ac75437a3734d91ba588e54875dd"
TGT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "taydex")
UA = ("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36")
from Crypto.Hash import keccak as _k
def keccak(b): h = _k.new(digest_bits=256); h.update(b); return h.digest()
def sig4(s): return keccak(s.encode()).hex()[:8]

def get(url, tries=6):
    """Retry on transient 500s too -- Blockscout returns a JSON-parseable error body
    ('Internal server error') with HTTP 500, so a naive 'no items -> break' exits early."""
    last = None
    for t in range(tries):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": UA,
                                                       "Accept": "application/json"})
            d = json.loads(urllib.request.urlopen(req, timeout=40).read())
            if isinstance(d, dict) and ("items" in d or "result" in d):
                return d
            last = d
        except urllib.error.HTTPError as e:
            try:    last = json.loads(e.read())
            except Exception: last = f"HTTP {e.code}"
        except Exception as e:
            last = str(e)
        time.sleep(1.5 + 1.5 * t)
    return last if isinstance(last, dict) else None

# selector -> name, from the ABI
abi = json.load(open(os.path.join(TGT, "abi_core.json")))
def sig_of(e):
    ins = []
    for i in e.get("inputs", []):
        t = i.get("type", "?")
        if t.startswith("tuple"):
            t = "(" + ",".join(c.get("type", "?") for c in i.get("components", [])) + ")" + t[5:]
        ins.append(t)
    return f"{e['name']}({','.join(ins)})"
SEL = {sig4(sig_of(e)): sig_of(e) for e in abi if e.get("type") == "function"}
# deployed-only extras seen in pass9/pass12
SEL.update({"7c16cd9e": "cancelMarket(uint256)  [DEPLOYED ONLY]"})

print("=" * 100)
print("PAGING the contract's full tx history (Blockscout v2)")
print("=" * 100)
txs, url, seen = [], f"https://base.blockscout.com/api/v2/addresses/{C}/transactions", set()
while url and len(txs) < 600:
    d = get(url)
    if not isinstance(d, dict) or "items" not in d:
        print(f"  page failed: {str(d)[:140]}"); break
    for it in d["items"]:
        h = it.get("hash")
        if h in seen:
            continue
        seen.add(h)
        txs.append({"hash": h, "from": (it.get("from") or {}).get("hash"),
                    "to": (it.get("to") or {}).get("hash"),
                    "block": it.get("block"), "ts": it.get("timestamp"),
                    "input": it.get("raw_input") or "",
                    "method": it.get("method"),
                    "status": it.get("status")})
    np = d.get("next_page_params")
    url = (f"https://base.blockscout.com/api/v2/addresses/{C}/transactions?"
           + urllib.parse.urlencode(np)) if np else None
    print(f"  {len(txs)} txs so far (next page: {'yes' if np else 'no'})")
    time.sleep(0.6)

print(f"\n  TOTAL txs fetched: {len(txs)}")
json.dump(txs, open(os.path.join(TGT, "pass19_txhistory.json"), "w"), indent=1)

print("\n" + "=" * 100)
print("CALLS BY FUNCTION (from calldata selector)")
print("=" * 100)
from collections import defaultdict
byfn = defaultdict(list)
for t in txs:
    inp = t["input"] or ""
    sel = inp[2:10].lower() if len(inp) >= 10 else ""
    byfn[SEL.get(sel, f"UNKNOWN 0x{sel}")].append(t)
for fn, lst in sorted(byfn.items(), key=lambda kv: -len(kv[1])):
    print(f"\n  {fn}   x{len(lst)}")
    senders = {}
    for t in lst:
        senders[t["from"]] = senders.get(t["from"], 0) + 1
    for s, n in sorted(senders.items(), key=lambda kv: -kv[1]):
        print(f"      from {s}  x{n}")

print("\n" + "=" * 100)
print("sweepLeftover CALLS IN DETAIL  (Finding 2 hinges on these)")
print("=" * 100)
OWNER = "0xef869234bb919bbde0f44d98912e87d1ce0463f8"
FEE = "0xc0b085c1a5514d8541adcb105aa7e6e8e5bc74ed"
SWEEP = sig4("sweepLeftover(uint256,uint16)")
for t in txs:
    if (t["input"] or "").lower().startswith("0x" + SWEEP):
        args = t["input"][10:]
        mid = int(args[0:64], 16) if len(args) >= 64 else None
        oi = int(args[64:128], 16) if len(args) >= 128 else None
        who = t["from"]
        role = ("OWNER" if (who or "").lower() == OWNER else
                "feeRecipient" if (who or "").lower() == FEE else "THIRD PARTY")
        print(f"  {t['hash']}  block {t['block']}  {t['ts'][:19] if t['ts'] else ''}")
        print(f"      sweepLeftover(marketId={mid}, option={oi})   caller={who}  [{role}]  "
              f"status={t['status']}")

print("\n" + "=" * 100)
print("createMarket CALLS  (candidates for the replay test)")
print("=" * 100)
CM = sig4("createMarket((uint64,uint128[],uint16,uint256,uint256),bytes)")
cands = [t for t in txs if (t["input"] or "").lower().startswith("0x" + CM)]
for t in cands:
    print(f"  {t['hash']}  from={t['from']}  block={t['block']}  inlen={len(t['input'])}")
if not cands:
    print("  none")
json.dump(cands, open(os.path.join(TGT, "pass19_createmarket_txs.json"), "w"), indent=1)
