#!/usr/bin/env python3
"""nar.bet recon — extract contract ABI + game constants from the shipped JS bundle.

No source required: a Next.js bundle carries the ABIs the app actually calls, plus the
addresses it calls them at. Those are ground truth for "what does the client invoke",
which is the reachability half of any finding.

Output: TARGETS/narbet/recon/abi-extract.json
"""
import json, os, re, glob
from collections import defaultdict

CHUNKS = "/tmp/narchunks"
OUT = os.path.expanduser("~/.hermes/workspace/SAVAGEAUD/TARGETS/narbet/recon")
os.makedirs(OUT, exist_ok=True)

blob_parts = []
for f in sorted(glob.glob(os.path.join(CHUNKS, "*.js"))):
    blob_parts.append(open(f, errors="ignore").read())
blob = "".join(blob_parts)
print("bundle bytes:", len(blob))

# ---- 1. ABI entries: {"name":"x","type":"function",...} inside JSON arrays
abi_re = re.compile(
    r'\{"((?:inputs|name|outputs|stateMutability|type|anonymous|indexed|internalType)":[\s\S]{0,400}?)\}'
)
raw = re.findall(r'\[(?:\{"inputs"' + r'[\s\S]{0,20000}?)\]', blob)
print("candidate ABI blobs:", len(raw))

funcs, events = defaultdict(dict), defaultdict(dict)
for chunk in raw:
    try:
        arr = json.loads(chunk)
    except Exception:
        continue
    if not isinstance(arr, list):
        continue
    for item in arr:
        if not isinstance(item, dict) or "type" not in item:
            continue
        name = item.get("name")
        if not name:
            continue
        if item["type"] == "function":
            ins = ",".join(i.get("type", "?") for i in item.get("inputs", []))
            outs = ",".join(o.get("type", "?") for o in item.get("outputs", []))
            funcs[name] = dict(inputs=ins, outputs=outs, mut=item.get("stateMutability", ""))
        elif item["type"] == "event":
            ins = ",".join(i.get("type", "?") for i in item.get("inputs", []))
            events[name] = dict(inputs=ins)

print(f"\nFUNCTIONS found: {len(funcs)}")
for n in sorted(funcs):
    f = funcs[n]
    print(f"  {n}({f['inputs']}) -> ({f['outputs']}) {f['mut']}")
print(f"\nEVENTS found: {len(events)}")
for n in sorted(events):
    print(f"  {n}({events[n]['inputs']})")

# ---- 2. entropy / game config constants
print("\n=== constant hunting ===")
for pat, label in [
    (r'houseEdge["\']?\s*[:=]\s*([0-9.]+)', "houseEdge"),
    (r'chainId["\']?\s*[:=]\s*(\d+)', "chainId"),
    (r'entropy["\']?\s*[:=]\s*["\'](0x[a-fA-F0-9]{40})', "entropy addr"),
    (r'contractAddress["\']?\s*[:=]\s*["\'](0x[a-fA-F0-9]{40})', "contractAddress"),
    (r'"0x[a-fA-F0-9]{40}"', "quoted addresses"),
]:
    hits = re.findall(pat, blob)
    if hits:
        uniq = sorted(set(hits))
        print(f"  {label:20} x{len(hits)} uniq={len(uniq)}: {uniq[:12]}")

json.dump({"functions": funcs, "events": events},
          open(os.path.join(OUT, "abi-extract.json"), "w"), indent=1)
print(f"\nsaved {OUT}/abi-extract.json")
