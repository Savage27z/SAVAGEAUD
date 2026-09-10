import json, subprocess
from eth_hash.auto import keccak

RPC = "https://api.mainnet.abs.xyz"
PROXY = "0x27EDd16eE56958fddCBA08947f12C43DDeC2B20C"
IMPL = "0x2c133230cfca00b9bf78c46dae03a97019d96551"
ADMIN_PROXY = "0x054318d34e114840948d93d932af76a13e19ff2c"


def rpc(method, params, timeout=60):
    payload = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params})
    return json.loads(subprocess.run(
        ["curl", "-s", "-m", str(timeout), "-X", "POST", RPC, "-H", "content-type: application/json", "-d", payload],
        capture_output=True, text=True).stdout, strict=False)


def call(target, sig, args=""):
    data = "0x" + keccak(sig.encode())[:4].hex() + args
    r = rpc("eth_call", [{"to": target, "data": data}, "latest"])
    return r.get("result"), r.get("error")


def dec_str(res):
    h = res[2:]
    off = int(h[:64], 16) // 32
    ln = int(h[off * 64:(off + 1) * 64], 16)
    return bytes.fromhex(h[(off + 1) * 64:(off + 1) * 64 + ln * 2]).decode()


def dec_addr(res):
    return "0x" + res[2:][24:64]


print("chainId:", rpc("eth_chainId", []).get("result"), "=", int(rpc("eth_chainId", [])["result"], 16))
print("balance(proxy):", int(rpc("eth_getBalance", [PROXY, "latest"])["result"], 16) / 1e18, "ETH")

for sig in ("messagePrefix()", "owner()", "gameCounter()", "paused()", "serverSigner()"):
    res, err = call(PROXY, sig)
    if err:
        print(f"{sig:20} ERR {str(err)[:80]}")
    elif res and len(res) >= 66:
        if sig in ("owner()",):
            print(f"{sig:20} {dec_addr(res)}")
        elif sig == "gameCounter()":
            print(f"{sig:20} {int(res, 16)}")
        else:
            try:
                print(f"{sig:20} {dec_str(res)!r}")
            except Exception:
                print(f"{sig:20} raw {res[:80]}")
    else:
        print(f"{sig:20} {str(res)[:80]}")

print("\n--- impl checks ---")
res, err = call(IMPL, "owner()")
print("impl.owner():", dec_addr(res) if res and len(res) >= 66 else res)
res, err = call(IMPL, "messagePrefix()")
print("impl.messagePrefix:", dec_str(res) if res and len(res) >= 66 else res)

print("\n--- proxy admin contract owner ---")
res, err = call(ADMIN_PROXY, "owner()")
print("proxyAdmin.owner():", dec_addr(res) if res and len(res) >= 66 else res)

# code + selectors present in deployed impl bytecode
code = rpc("eth_getCode", [IMPL, "latest"]).get("result", "")
print("\nimpl code bytes:", (len(code) - 2) // 2)
for sig in ("increaseBet(uint256,uint256,uint256,bytes)", "createGame(string,bytes32,string,string,uint256,bytes)",
            "cashOut(uint256,uint256,string,string,uint256,bytes)", "withdrawFunds(uint256,address)",
            "markGameAsLost(uint256,string,string,uint256,bytes)"):
    sel = keccak(sig.encode())[:4].hex()
    print(f"  selector {sel} present: {sel in code[2:].lower()}  ({sig.split('(')[0]})")
