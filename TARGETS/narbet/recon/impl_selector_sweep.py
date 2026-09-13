#!/usr/bin/env python3
"""nar.bet — impl selector sweep (structural, decisive).

Extracts every dispatched selector from an implementation's runtime bytecode
(standard `PUSH4 <sel> EQ` pattern) and diffs it against the recovered ABI.

Why this matters: the recovered ABI came from the frontend bundle, so it only
lists what the *frontend* calls. A refund-commit entry point the frontend never
uses would be invisible in the ABI but visible here. An implementation ABI that
is a strict subset of the recovered ABI is a strong (and calibratable) result.

Usage: impl_selector_sweep.py <0x-impl-address-or-hexfile> [...]
Output: recon/selector-sweep.json
"""
import json, os, re, sys, urllib.request
from eth_utils import keccak

OUT = os.path.expanduser("~/.hermes/workspace/SAVAGEAUD/TARGETS/narbet/recon")
UA = {"Content-Type": "application/json",
      "User-Agent": "Mozilla/5.0 (X11; Linux x86_64) Chrome/124.0 Safari/537.36",
      "Accept": "application/json"}
RPC = "https://rpc2.monad.xyz"

IMPLS = {
    "RPS": "0x8d2026407da5324bf955ba7f21962816cb477bfc",
    "CoinFlip": "0xbe4d58428ae13e0b8edbab92e7994e4c7f0073ee",
    "BankRoll": "0xf53441ef835df1106198038ef71d8459f389ec15",
    "config209": "0xdba35808de5e89e5e0ca28605d7d3f0292579404",
}


def fetch_code(addr):
    body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": "eth_getCode",
                       "params": [addr, "latest"]}).encode()
    r = urllib.request.Request(RPC, data=body, headers=UA)
    return json.loads(urllib.request.urlopen(r, timeout=60).read())["result"]


def canonical(inputs):
    if not inputs:
        return []
    out, depth, cur = [], 0, ""
    for ch in inputs:
        if ch in "([":
            depth += 1
        elif ch in ")]":
            depth -= 1
        if ch == "," and depth == 0:
            out.append(cur.strip()); cur = ""
        else:
            cur += ch
    if cur.strip():
        out.append(cur.strip())
    types = []
    for p in out:
        t = p.split()[0] if p.split() else p
        if t.startswith("tuple"):
            return None
        types.append(t)
    return types


def dispatched_selectors(code_hex):
    """Find `63 <4 bytes> 14` (PUSH4 sel; EQ) — the standard dispatcher compare."""
    code = code_hex[2:] if code_hex.startswith("0x") else code_hex
    sels = set()
    for m in re.finditer(r"63([0-9a-f]{8})14", code):
        sels.add("0x" + m.group(1))
    return sels


def main():
    abi = json.load(open(os.path.join(OUT, "abi-real.json")))
    abi_sel = {}
    for n, s in abi["functions"].items():
        t = canonical(s.get("inputs", ""))
        if t is None:
            continue
        sig = f"{n}({','.join(t)})"
        abi_sel["0x" + keccak(text=sig)[:4].hex()] = sig

    result = {}
    for label, addr in IMPLS.items():
        code = fetch_code(addr)
        sels = dispatched_selectors(code)
        known = {s: abi_sel[s] for s in sels if s in abi_sel}
        unknown = sorted(s for s in sels if s not in abi_sel)
        print(f"\n=== {label} {addr} codesize={len(code)//2 - 1}")
        print(f"  dispatched selectors: {len(sels)}   matched from ABI: {len(known)}   UNKNOWN: {len(unknown)}")
        for s, sig in sorted(known.items(), key=lambda kv: kv[1]):
            print(f"    ✔ {s} {sig}")
        for s in unknown:
            print(f"    ✖ {s}  <-- NOT IN RECOVERED ABI")
        result[label] = {"address": addr, "codesize": len(code) // 2 - 1,
                         "n_dispatched": len(sels), "known": known, "unknown": unknown}
        with open(os.path.join(OUT, "bytecode", f"{label}-impl.hex"), "w") as f:
            f.write(code)

    with open(os.path.join(OUT, "selector-sweep.json"), "w") as f:
        json.dump(result, f, indent=1)
    print("\nsaved recon/selector-sweep.json + recon/bytecode/*.hex")


if __name__ == "__main__":
    main()
