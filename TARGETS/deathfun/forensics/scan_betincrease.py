import json, subprocess, time

RPC = "https://api.mainnet.abs.xyz"
PROXY = "0x27EDd16eE56958fddCBA08947f12C43DDeC2B20C"
IMPL = "0x2c133230cfca00b9bf78c46dae03a97019d96551"
T_BET = "0x5831ed986017af0b34bece8d89d150d50038c97309d6e777009673096eec542c"  # BetIncrease
T_CRE = "0x5ab4782178ec00656b6f3f3f73d1739ea9d5cba22c641e4b20767fbb57160943"  # GameCreated


def rpc(method, params, timeout=90):
    payload = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params})
    return json.loads(subprocess.run(
        ["curl", "-s", "-m", str(timeout), "-X", "POST", RPC, "-H", "content-type: application/json", "-d", payload],
        capture_output=True, text=True).stdout, strict=False)


head = int(rpc("eth_blockNumber", [])["result"], 16)
print("head", head)

# find deployment block of the proxy by binary-searching code presence
def has_code(blk):
    r = rpc("eth_getCode", [PROXY, hex(blk)])
    c = r.get("result", "0x")
    return c and c not in ("0x", "0x0")

lo, hi = 0, head
if has_code(hi):
    while lo < hi:
        mid = (lo + hi) // 2
        if has_code(mid):
            hi = mid
        else:
            lo = mid + 1
print("proxy deployed at block", lo)

# scan the whole life for BetIncrease logs, chunked
STEP = 50000
found = []
start = lo
t0 = time.time()
while start <= head:
    end = min(start + STEP - 1, head)
    r = rpc("eth_getLogs", [{"address": PROXY, "topics": [T_BET],
                             "fromBlock": hex(start), "toBlock": hex(end)}])
    if "result" in r:
        found.extend(r["result"])
    else:
        print("  chunk err", start, end, str(r)[:120])
    start = end + 1
    if time.time() - t0 > 420:
        print("  time budget hit at", start)
        break

print("\nBetIncrease events over ENTIRE contract life:", len(found))
for l in found[:10]:
    print(json.dumps(l))
if found:
    json.dump(found, open("/tmp/deathfun/betincrease.json", "w"))

# also: has GameCreated always looked the same? first block of game activity
r = rpc("eth_getLogs", [{"address": PROXY, "topics": [T_CRE],
                         "fromBlock": hex(lo), "toBlock": hex(min(lo + STEP, head))}])
print("\nGameCreated in first 50k blocks of life:", len(r.get("result", [])))
