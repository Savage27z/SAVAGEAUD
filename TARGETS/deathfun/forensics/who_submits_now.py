import json, subprocess, collections
from concurrent.futures import ThreadPoolExecutor

RPC = "https://api.mainnet.abs.xyz"
PROXY = "0x27EDd16eE56958fddCBA08947f12C43DDeC2B20C"
T_CRE = "0x5ab4782178ec00656b6f3f3f73d1739ea9d5cba22c641e4b20767fbb57160943"  # GameCreated
T_PAY = "0xca18b3e4c1f4a1342b2e2e8b6c68bd49c1ff679624d67b618db852effe04dcba"  # PayoutSent


def rpc(m, p, t=60):
    payload = json.dumps({"jsonrpc": "2.0", "id": 1, "method": m, "params": p})
    return json.loads(subprocess.run(["curl", "-s", "-m", str(t), "-X", "POST", RPC,
                                      "-H", "content-type: application/json", "-d", payload],
                                     capture_output=True, text=True).stdout, strict=False)


head = int(rpc("eth_blockNumber", [])["result"], 16)
lo = head - 20000

cre = rpc("eth_getLogs", [{"address": PROXY, "topics": [T_CRE], "fromBlock": hex(lo), "toBlock": "latest"}]).get("result", [])
pay = rpc("eth_getLogs", [{"address": PROXY, "topics": [T_PAY], "fromBlock": hex(lo), "toBlock": "latest"}]).get("result", [])
print("recent GameCreated:", len(cre), " recent PayoutSent:", len(pay))


def txof(h):
    return rpc("eth_getTransactionByHash", [h]).get("result")


def analyze(logs, label, player_topic):
    sample = logs[-12:]
    with ThreadPoolExecutor(max_workers=8) as ex:
        txs = list(ex.map(lambda l: txof(l["transactionHash"]), sample))
    match = mism = 0
    froms = collections.Counter()
    for l, t in zip(sample, txs):
        if not t:
            continue
        player = "0x" + l["topics"][player_topic][-40:]
        frm = (t.get("from") or "").lower()
        froms[frm] += 1
        if frm == player:
            match += 1
        else:
            mism += 1
    print(f"\n{label}: sampled {len(sample)}  tx.from==subject: {match}  differ: {mism}")
    print(f"  distinct senders in sample: {len(froms)}")
    for f, c in froms.most_common(3):
        print(f"    {f}  x{c}")
    return match, mism, froms


analyze(cre, "createGame (GameCreated.player)", 2)
analyze(pay, "cashOut   (PayoutSent.recipient)", 2)
