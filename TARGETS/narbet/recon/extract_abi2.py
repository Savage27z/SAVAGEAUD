#!/usr/bin/env python3
"""nar.bet recon #2 — extract the REAL contract ABIs from the shipped bundle.

The bundle embeds full JSON ABIs (with `internalType`), which give every function and
event signature of the game contracts WITHOUT source code. First extractor missed them
because it required the array to begin with `[{"inputs"` and capped the window at 20 KB.

Method: bracket-match from every `[{` and keep arrays that look like ABIs.

Output: TARGETS/narbet/recon/abi-real.json
"""
import json, os, re, glob
from collections import defaultdict

OUT = os.path.expanduser("~/.hermes/workspace/SAVAGEAUD/TARGETS/narbet/recon")
os.makedirs(OUT, exist_ok=True)
blob = "".join(open(f, errors="ignore").read() for f in sorted(glob.glob("/tmp/narchunks/*.js")))
print("bundle bytes:", len(blob))


def bracket_slice(s, start):
    depth = 0
    in_str = False
    esc = False
    for i in range(start, min(len(s), start + 400000)):
        c = s[i]
        if in_str:
            if esc:
                esc = False
            elif c == "\\":
                esc = True
            elif c == '"':
                in_str = False
        else:
            if c == '"':
                in_str = True
            elif c == "[":
                depth += 1
            elif c == "]":
                depth -= 1
                if depth == 0:
                    return s[start:i + 1]
    return None


abis = []
seen_sha = set()
for m in re.finditer(r'\[\{"(?:inputs|anonymous|type|internalType)"', blob):
    js = bracket_slice(blob, m.start())
    if not js or len(js) < 150:
        continue
    if '"internalType"' not in js or '"type"' not in js:
        continue
    key = hash(js)
    if key in seen_sha:
        continue
    seen_sha.add(key)
    try:
        arr = json.loads(js)
    except Exception:
        continue
    if isinstance(arr, list) and any(isinstance(x, dict) and "type" in x for x in arr):
        abis.append(arr)

print("distinct ABI arrays parsed:", len(abis))

funcs, events, errors, ctors = {}, {}, {}, 0
for arr in abis:
    for item in arr:
        if not isinstance(item, dict):
            continue
        t = item.get("type")
        if t == "constructor":
            ctors += 1
            funcs["<constructor>"] = dict(
                inputs=",".join(i.get("type", "?") for i in item.get("inputs", [])),
                outputs="", mut=item.get("stateMutability", ""))
            continue
        name = item.get("name")
        if not name:
            continue
        sig_in = ",".join(
            f"{i.get('type','?')}{(' '+i.get('name')) if i.get('name') else ''}"
            for i in item.get("inputs", []))
        if t == "function":
            outs = ",".join(o.get("type", "?") for o in item.get("outputs", []))
            funcs[name] = dict(inputs=sig_in, outputs=outs,
                               mut=item.get("stateMutability", ""))
        elif t == "event":
            events[name] = dict(inputs=sig_in)
        elif t == "error":
            errors[name] = dict(inputs=sig_in)

print(f"\n=== FUNCTIONS ({len(funcs)}) ===")
for n in sorted(funcs):
    f = funcs[n]
    print(f"  {n}({f['inputs']}){'' if not f['outputs'] else ' -> ' + f['outputs']}  [{f['mut']}]")
print(f"\n=== EVENTS ({len(events)}) ===")
for n in sorted(events):
    print(f"  {n}({events[n]['inputs']})")
print(f"\n=== ERRORS ({len(errors)}) ===")
for n in sorted(errors):
    print(f"  {n}({errors[n]['inputs']})")

json.dump({"functions": funcs, "events": events, "errors": errors,
           "n_abi_arrays": len(abis)},
          open(os.path.join(OUT, "abi-real.json"), "w"), indent=1)
print(f"\nsaved {OUT}/abi-real.json")
