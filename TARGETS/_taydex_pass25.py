#!/usr/bin/env python3
"""TayDex pass25: identify the deployed contract's OWN trade entry points.

pass19 found real calls to two selectors the app ABI does not know:
  0x9aa63277  x12  (0x729939ac x11, 0x22845bd1 x1)   <- likely the deployed version's trade
  0x7c9aea76  x4   (0xc0b085c1= feeRecipient x3, 0x729939ac x1)
and the deployed code emits TradeExecuted(uint256,uint16,address,bool,uint8,uint256,uint256,uint256,uint256).
The app's buy/sell do not exist here, so trades must go through one of these.

Goal: name them, then read a real call's arguments and logs. If the deployed trade path is NOT
signature-gated the way createMarket is, that is a genuine finding on the money path.

Read-only: 4byte/openchain lookups + explorer tx data + eth_call.
"""
import json, os, time, urllib.error, urllib.parse, urllib.request

C = "0x3ade22fa1ef5ac75437a3734d91ba588e54875dd"
TGT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "taydex")
UA = ("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36")
from Crypto.Hash import keccak as _k
def keccak(b): h = _k.new(digest_bits=256); h.update(b); return h.digest()
def sig4(s): return keccak(s.encode()).hex()[:8]

def fetch(url, tries=4):
    for t in range(tries):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": UA,
                                                       "Accept": "application/json"})
            return json.loads(urllib.request.urlopen(req, timeout=35).read())
        except urllib.error.HTTPError as e:
            try:    return json.loads(e.read())
            except Exception: pass
        except Exception:
            pass
        time.sleep(1.2 + t)
    return None

UNKNOWN = ["9aa63277", "7c9aea76", "1f18c427", "285204f0", "29091ad3",
           "2bfa23e7", "2cd44ac3", "35e2f383", "6cdb3d13", "711bec91", "03a24d07",
           "03dee4c5", "7c16cd9e", "5b059991", "9aa63277"]
print("=" * 96)
print("NAME THE DEPLOYED-ONLY SELECTORS")
print("=" * 96)
named = {}
for s in dict.fromkeys(UNKNOWN):
    got = []
    d = fetch(f"https://www.4byte.directory/api/v1/signatures/?hex_signature=0x{s}")
    for r in (d or {}).get("results", [])[:3]:
        got.append(("4byte", r["text_signature"]))
    # openchain.xyz as a second source (the bundle itself referenced it)
    o = fetch(f"https://api.openchain.xyz/signature-database/v1/lookup?function=0x{s}&filter=true")
    res = ((o or {}).get("result") or {}).get("function") or {}
    for item in (res.get(f"0x{s}") or []):
        got.append(("openchain", item.get("name")))
    named[s] = got
    label = "; ".join(f"{src}:{n}" for src, n in got) if got else "<no match>"
    print(f"  0x{s}  {label}")

# ---------- pull the real calls and decode ----------
print("\n" + "=" * 96)
print("REAL CALLS to the unknown selectors (arguments + logs)")
print("=" * 96)
txfile = os.path.join(TGT, "pass19_txhistory.json")
txs = json.load(open(txfile))

def words(inp):
    body = inp[10:]              # strip 0x + selector
    return [body[i*64:(i+1)*64] for i in range(len(body)//64)]

TARGETS = ["9aa63277", "7c9aea76"]
for sel in TARGETS:
    hits = [t for t in txs if (t.get("input") or "").lower().startswith("0x" + sel)]
    print(f"\n--- 0x{sel}  ({len(hits)} call(s))  {named.get(sel, [])}")
    for t in hits[:3]:
        wd = words(t["input"])
        print(f"  {t['hash']}")
        print(f"    from {t['from']}   method-field={t.get('method')}   status={t.get('status')}")
        for i, w in enumerate(wd[:12]):
            dec = int(w, 16)
            as_addr = "0x" + w[-40:] if dec > 2**96 else ""
            print(f"      w{i:<2} {w}  dec={dec if dec < 2**80 else '-'} {as_addr}")
        # logs for this tx
        lg = fetch(f"https://base.blockscout.com/api/v2/transactions/{t['hash']}/logs")
        items = (lg or {}).get("items") if isinstance(lg, dict) else None
        if items:
            for L in items[:6]:
                tops = L.get("topics") or []
                dec = L.get("decoded") or {}
                name = dec.get("method_call") or dec.get("name") or ""
                params = [(p.get("name"), p.get("value")) for p in (dec.get("parameters") or [])]
                print(f"      LOG {name}  {params if params else tops[:3]}")
    # compare: did TradeExecuted fire in those txs?
print("\n" + "=" * 96)
print("Which topic0 do these calls emit?  (looking for TradeExecuted)")
print("=" * 96)
TE = "0x" + keccak(b"TradeExecuted(uint256,uint16,address,bool,uint8,uint256,uint256,uint256,uint256)").hex()
print(f"  TradeExecuted topic0 = {TE}")
for sel in TARGETS:
    for t in [x for x in txs if (x.get("input") or "").lower().startswith("0x" + sel)][:4]:
        lg = fetch(f"https://base.blockscout.com/api/v2/transactions/{t['hash']}/logs")
        items = (lg or {}).get("items") if isinstance(lg, dict) else []
        tops = [((L.get("topics") or [""])[0]) for L in (items or [])]
        print(f"  0x{sel} {t['hash'][:18]}… emits {['TradeExecuted' if x.lower()==TE.lower() else x[:16] for x in tops]}")
