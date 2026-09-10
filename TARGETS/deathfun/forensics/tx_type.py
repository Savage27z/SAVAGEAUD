import json, subprocess

RPC = "https://api.mainnet.abs.xyz"


def rpc(m, p, t=60):
    payload = json.dumps({"jsonrpc": "2.0", "id": 1, "method": m, "params": p})
    return json.loads(subprocess.run(["curl", "-s", "-m", str(t), "-X", "POST", RPC,
                                      "-H", "content-type: application/json", "-d", payload],
                                     capture_output=True, text=True).stdout, strict=False)


def show(h, label):
    t = rpc("eth_getTransactionByHash", [h]).get("result")
    print(f"=== {label}")
    if not t:
        print("  not found"); return
    for k in ("type", "from", "to", "value", "gasPrice", "maxFeePerGas", "nonce", "transactionIndex",
              "paymaster", "paymasterInput", "gasPerPubdata", "factoryDeps", "customData", "v", "r", "s", "chainId"):
        if k in t:
            v = t[k]
            if isinstance(v, str) and len(v) > 90:
                v = v[:90] + f"...(len {len(v)})"
            print(f"  {k:16} {v}")
    print("  all keys:", sorted(t.keys()))


# a real increaseBet tx (2026-04-12, the last one) and a real createGame tx (recent, 2026-09)
show("0x731d9954d046b4c5ca349d4db1958a44b64b873feb64a042439d3e18800dc41b", "increaseBet 2026-04-12")

PROXY = "0x27EDd16eE56958fddCBA08947f12C43DDeC2B20C"
head = int(rpc("eth_blockNumber", [])["result"], 16)
T_CRE = "0x5ab4782178ec00656b6f3f3f73d1739ea9d5cba22c641e4b20767fbb57160943"
logs = rpc("eth_getLogs", [{"address": PROXY, "topics": [T_CRE], "fromBlock": hex(head - 3000), "toBlock": "latest"}]).get("result", [])
print("\nrecent GameCreated in window:", len(logs))
if logs:
    show(logs[-1]["transactionHash"], "createGame (recent, today)")

# is a player address a contract (smart account) or a plain EOA?
for a in ("0x2027e8a61acd572e584da99dfba33fcb22673dae", "0x9f06c49e76c58209055e0c89d6272e963d96abbe"):
    c = rpc("eth_getCode", [a, "latest"]).get("result", "0x")
    print(f"\ncode at player {a}: {len(c)//2 - 1} bytes  -> {'CONTRACT (smart account)' if len(c) > 2 else 'EOA'}")
