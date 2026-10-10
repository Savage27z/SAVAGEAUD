#!/usr/bin/env python3
"""Read live state for the obol.sh Daemon contracts over Robinhood Chain RPC.
Selectors come from the Sourcify 'signatures.function' list so nothing is guessed."""
import json, os, sys, urllib.request

RPC = "https://rpc.mainnet.chain.robinhood.com"
META = "/root/.hermes/workspace/SAVAGEAUD/TARGETS/obol/meta"
UA = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 Chrome/153.0.0.0 Safari/537.36"
SALE = "0xD22301bcA4eCfFb9F4B87792885D766595e7363c"
NFT = "0x1BD783d8dcc50db3f610d1c46ec7e97d7f457402"
REGISTRY = "0x000000006551c19487814612e58FE06813775758"

def rpc(method, params):
    body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}).encode()
    req = urllib.request.Request(RPC, data=body, headers={"Content-Type": "application/json", "User-Agent": UA})
    with urllib.request.urlopen(req, timeout=60) as r:
        out = json.loads(r.read().decode())
    if "error" in out:
        raise RuntimeError(out["error"])
    return out["result"]

def sel_map(name):
    d = json.load(open(os.path.join(META, name + ".json")))
    m = {}
    abi = {a.get("name"): a for a in d.get("abi", []) if a.get("type") == "function"}
    for s in (d.get("signatures") or {}).get("function", []):
        sig = s["signature"]
        fname = sig.split("(")[0]
        m[fname] = {"sel": s["signatureHash4"], "sig": sig, "abi": abi.get(fname)}
    return m

def decode(abi, hexdata):
    if abi is None:
        return hexdata
    outs = abi.get("outputs") or []
    if not outs:
        return None
    raw = hexdata[2:] if hexdata.startswith("0x") else hexdata
    res = []
    for i, o in enumerate(outs):
        t = o["type"]
        chunk = raw[i*64:(i+1)*64]
        if not chunk:
            res.append(None); continue
        v = int(chunk, 16)
        if t.startswith("uint") or t.startswith("int"):
            res.append(v)
        elif t == "bool":
            res.append(bool(v))
        elif t == "address":
            res.append("0x%040x" % v)
        elif t == "string":
            # offset-encoded
            off = v * 2
            ln = int(raw[off:off+64], 16)
            data = raw[off+64:off+64+ln*2]
            res.append(bytes.fromhex(data).decode("utf8", "replace"))
        else:
            res.append("0x" + chunk)
    return res[0] if len(res) == 1 else res

def call(m, name, to, args=()):
    e = m[name]
    if e.get("abi") is None:
        return f"(no abi entry for {name})"
    sel = e["sel"][2:] if e["sel"].startswith("0x") else e["sel"]
    data = "0x" + sel + "".join("%064x" % a if isinstance(a, int) else a[2:].rjust(64, "0") for a in args)
    try:
        out = rpc("eth_call", [{"to": to, "data": data}, "latest"])
    except Exception as ex:
        return f"REVERT {ex}"
    return decode(e["abi"], out)

sale = sel_map("sale")
nft = sel_map("collection")

print("=== DaemonSale 0xD22301bc... live ===")
for f in ["supply", "walletBps", "opensAt", "treasury", "accountImpl", "sold", "currentBand", "price", "nft", "REGISTRY", "BANDS"]:
    if f in sale:
        print(f"  {f:14s} {call(sale, f, SALE)}")
    else:
        print(f"  {f:14s} (not in signatures)")

print("\n=== DaemonNFT 0x1BD783d8... live ===")
for f in ["name", "symbol", "supply", "owner", "totalSupply", "baseURI"]:
    if f in nft:
        print(f"  {f:14s} {call(nft, f, NFT)}")

print("\n=== walletOf() for a few tokenIds (ERC-6551 accounts) ===")
for tid in (0, 1, 5000, 10047):
    w = call(sale, "walletOf", SALE, (tid,))
    if isinstance(w, str) and w.startswith("0x"):
        code = rpc("eth_getCode", [w, "latest"])
        own = "n/a"
        try:
            own = decode({"outputs": [{"type": "address"}]}, rpc("eth_call", [{"to": w, "data": "0x8da5cb5b"}, "latest"]))
        except Exception as e:
            own = f"owner() revert: {e}"
        print(f"  tokenId {tid:5d} -> {w}  code={len(code)} bytes  owner()={own}")
    else:
        print(f"  tokenId {tid:5d} -> {w}")

print("\n=== contract code sizes / EOA checks ===")
for label, addr in [("sale", SALE), ("collection", NFT), ("accountImpl", "0xac855818bc77cd378d7ce24ab6151491e1623dc6"),
                    ("treasury", "0xA7DC540d12E53Cf8d6615921Fe7b4f9Ca73A0dBC"), ("deployer", "0x76c4eEE755Ee20c973db55C522F1E75AD3132DFF"),
                    ("registry", REGISTRY)]:
    code = rpc("eth_getCode", [addr, "latest"])
    n = (len(code) - 2) // 2
    print(f"  {label:12s} {addr} {n:6d} bytes  {'EOA' if n == 0 else 'contract'}")

print("\n=== chain / block ===")
bn = rpc("eth_blockNumber", [])
print("  block", int(bn, 16))
blk = rpc("eth_getBlockByNumber", [bn, False])
print("  timestamp", int(blk["timestamp"], 16), "chainId", int(rpc("eth_chainId", []), 16))
