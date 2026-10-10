#!/usr/bin/env python3
"""Decode the deployed immutable values out of the Sourcify runtime records.
Immutables are baked into the runtime bytecode; Sourcify exposes the exact values
under runtimeBytecode.transformationValues.immutables (keyed by AST id)."""
import json, os

META = "/root/.hermes/workspace/SAVAGEAUD/TARGETS/obol/meta"

def ident(kind, word):
    v = int(word, 16)
    if kind == "addr":
        return "0x%040x" % v
    return v

def decode(name, expect):
    d = json.load(open(os.path.join(META, name + ".json")))
    imm = (((d.get("runtimeBytecode") or {}).get("transformationValues") or {}).get("immutables")) or {}
    print(f"\n=== {name} ({d['address']}) — {len(imm)} immutables ===")
    print(f"  isProxy: {(d.get('proxyResolution') or {}).get('isProxy')}   match: {d.get('match')}")
    vals = {}
    for ast_id, word in sorted(imm.items(), key=lambda kv: int(kv[0])):
        v = int(word, 16)
        kind = "addr" if v > 2**40 and v < 2**160 else "int"
        guess = ""
        if kind == "int":
            if v in (10048,): guess = "supply?"
            elif v in (9000,): guess = "walletBps?"
            elif 1_700_000_000 < v < 2_000_000_000:
                import datetime
                guess = "opensAt? " + datetime.datetime.utcfromtimestamp(v).isoformat() + "Z"
        else:
            guess = "address"
        vals[ast_id] = word
        print(f"  astId {ast_id:>4}  {word}  ({guess})")
    return vals

for n, exp in (("sale", None), ("collection", None)):
    decode(n, exp)

# also: deployment info
for n in ("sale", "collection"):
    d = json.load(open(os.path.join(META, n + ".json")))
    dep = d.get("deployment") or {}
    print(f"\n{n}: deployed by {dep.get('deployer')} at block {dep.get('blockNumber')} tx {dep.get('transactionHash')}")
    print(f"   constructor args: {((d.get('runtimeBytecode') or {}).get('transformationValues') or {}).get('constructorArguments')}")
