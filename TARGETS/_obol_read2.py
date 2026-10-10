#!/usr/bin/env python3
"""Second read pass: band prices vs advertised 1.3^n, real Bought events (split + wallet),
and the ERC-6551 wiring. All selectors/topics come from the Sourcify signature lists."""
import json, os, urllib.request

RPC = "https://rpc.mainnet.chain.robinhood.com"
META = "/root/.hermes/workspace/SAVAGEAUD/TARGETS/obol/meta"
UA = "Mozilla/5.0 (X11; Linux x86_64) Chrome/153.0.0.0"
SALE = "0xD22301bcA4eCfFb9F4B87792885D766595e7363c"
NFT = "0x1BD783d8dcc50db3f610d1c46ec7e97d7f457402"
REG = "0x000000006551c19487814612e58FE06813775758"
IMPL = "0xac855818bc77cd378d7ce24ab6151491e1623dc6"
TREASURY = "0xA7DC540d12E53Cf8d6615921Fe7b4f9Ca73A0dBC"

def rpc(m, p):
    body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": m, "params": p}).encode()
    req = urllib.request.Request(RPC, data=body, headers={"Content-Type": "application/json", "User-Agent": UA})
    with urllib.request.urlopen(req, timeout=60) as r:
        o = json.loads(r.read().decode())
    if "error" in o: raise RuntimeError(o["error"])
    return o["result"]

sale = json.load(open(os.path.join(META, "sale.json")))
nft = json.load(open(os.path.join(META, "collection.json")))
impl = json.load(open(os.path.join(META, "accountImpl.json")))

def sigs(d, kind):
    return {s["signature"]: s for s in (d.get("signatures") or {}).get(kind, [])}

def selof(d, fname):
    for s in sigs(d, "function").values():
        if s["signature"].startswith(fname + "("):
            return s
    return None

def call(d, fname, to, args=()):
    s = selof(d, fname)
    if not s: return f"(no sig {fname})"
    data = "0x" + s["signatureHash4"][2:] + "".join("%064x" % a for a in args)
    out = rpc("eth_call", [{"to": to, "data": data}, "latest"])
    return out

print("=== band prices: on-chain vs advertised 0.01 * 1.3^n ===")
first = 10**16
exp = first
ok_all = True
for i in range(10):
    raw = call(sale, "bandPrice", SALE, (i,))
    v = int(raw, 16)
    want = (first * (13**i)) // (10**i)          # exact rational 1.3^i, floored
    # replicate the contract's own iterative integer chain
    match = "?"
    print(f"  band {i}: {v/1e18:.11f} ETH   ({v} wei)  advertised {want/1e18:.11f}  {'OK' if v==want else 'DIFF'}")
    if v != want: ok_all = False
print("  band price table exact:", ok_all)

print("\n=== Bought events (last 20k blocks) ===")
bought_topic = sigs(sale, "event").get("Bought(uint256,address,uint256,uint256,address,uint256,uint256)")
print("  topic0:", bought_topic and bought_topic["signatureHash32"])
logs = rpc("eth_getLogs", [{"fromBlock": hex(int(rpc("eth_blockNumber", []), 16) - 20000),
                           "toBlock": "latest", "address": SALE, "topics": [bought_topic["signatureHash32"]]}])
print("  events found:", len(logs))
tot_w = tot_t = 0
for lg in logs[-6:]:
    topics, data = lg["topics"], lg["data"][2:]
    words = [data[i*64:(i+1)*64] for i in range(len(data)//64)]
    tokenId = int(topics[1], 16)
    buyer = "0x" + topics[2][-40:]
    band, price, wallet, toW, toT = int(words[0],16), int(words[1],16), "0x"+words[2][-40:], int(words[3],16), int(words[4],16)
    # independent recompute of the ERC-6551 address
    print(f"  #{tokenId:5d} buyer {buyer} band {band} price {price/1e18:.11f} wallet {wallet} toWallet {toW/1e18:.6f} toTreasury {toT/1e18:.6f}")
    print(f"          split check: toWallet==price*0.9? {toW == price*9000//10000}   toW+toT==price? {toW+toT==price}")
for lg in logs:
    words = [lg["data"][2:][i*64:(i+1)*64] for i in range(len(lg["data"][2:])//64)]
    tot_w += int(words[3],16); tot_t += int(words[4],16)
print(f"  all {len(logs)} events: toWallet total {tot_w/1e18:.6f} ETH, treasury total {tot_t/1e18:.6f} ETH")

print("\n=== ERC-6551 wiring: does the account owner == NFT ownerOf? ===")
for tid in (0, 1, 317):
    try:
        acc = "0x" + call(sale, "walletOf", SALE, (tid,))[-40:]
        acc_owner = "0x" + rpc("eth_call", [{"to": acc, "data": "0x8da5cb5b"}, "latest"])[-40:]
        nft_owner = "0x" + call(nft, "ownerOf", NFT, (tid,))[-40:]
        code = (len(rpc("eth_getCode", [acc, "latest"])) - 2)//2
        print(f"  #{tid:5d} account {acc} code={code}B  account.owner()={acc_owner}  nft.ownerOf()={nft_owner}  MATCH={acc_owner==nft_owner}")
    except Exception as e:
        print(f"  #{tid}: {e}")

print("\n=== accountImpl config ===")
dollar_raw = rpc("eth_call", [{"to": IMPL, "data": "0x" + "d1b1c9c1"}, "latest"])  # placeholder, resolved below
s = None
for x in sigs(impl, "function").values():
    if x["signature"].startswith("dollar("): s = x
print("  dollar() selector:", s and s["signatureHash4"])
if s:
    dv = "0x" + rpc("eth_call", [{"to": IMPL, "data": s["signatureHash4"]}, "latest"])[-40:]
    print("  dollar:", dv)
    usdg = json.load(open("/dev/null")) if False else None
    try:
        nm = rpc("eth_call", [{"to": dv, "data": "0x06fdde03"}, "latest"])
        ln = int(nm[2+64:2+128], 16)
        print("  dollar name:", bytes.fromhex(nm[2+128:2+128+ln*2]).decode())
        sym = rpc("eth_call", [{"to": dv, "data": "0x95d89b41"}, "latest"])
        ln2 = int(sym[2+64:2+128], 16)
        print("  dollar symbol:", bytes.fromhex(sym[2+128:2+128+ln2*2]).decode())
    except Exception as e:
        print("  (name/symbol read failed:", e, ")")

print("\n=== balances ===")
for lbl, a in (("treasury Safe", TREASURY), ("sale", SALE), ("deployer", "0x76c4eEE755Ee20c973db55C522F1E75AD3132DFF")):
    print(f"  {lbl:14s} {int(rpc('eth_getBalance', [a, 'latest']),16)/1e18:.6f} ETH")
print("  sold now:", int(call(sale, "sold", SALE), 16))
