import json, subprocess

RPC = "https://api.mainnet.abs.xyz"
PROXY = "0x27EDd16eE56958fddCBA08947f12C43DDeC2B20C"


def rpc(method, params, timeout=60):
    payload = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params})
    return json.loads(subprocess.run(["curl", "-s", "-m", str(timeout), "-X", "POST", RPC,
                                      "-H", "content-type: application/json", "-d", payload],
                                     capture_output=True, text=True).stdout, strict=False)


try:
    from eth_account import Account
    from eth_account.messages import encode_defunct
    from eth_hash.auto import keccak
except ImportError:
    subprocess.run(["pip", "install", "-q", "eth-account"], check=False)
    from eth_account import Account
    from eth_account.messages import encode_defunct
    from eth_hash.auto import keccak
from eth_abi import encode as abi_encode

rows = json.load(open("/tmp/deathfun/bet_decoded.json"))
PREFIX = "DeathFun"


def recover(gid, amount, deadline, sig_hex):
    inner = keccak(abi_encode(
        ["string", "uint256", "uint256", "uint256"],
        [f"{PREFIX}:increaseBet", gid, amount, deadline]))
    msg = encode_defunct(inner)
    return Account.recover_message(msg, signature=bytes.fromhex(sig_hex))


signers = {}
ok = 0
for r in rows[:60]:
    try:
        s = recover(r["gid"], r["amount"], r["deadline"], r["sig"])
        signers[s] = signers.get(s, 0) + 1
        ok += 1
        if ok <= 3:
            print(f"  gid={r['gid']} amount={r['amount']/1e18} deadline={r['deadline']} -> signer {s}")
    except Exception as e:
        print("  recover fail:", e)
print(f"\nrecovered {ok}/60  distinct signers: {signers}")

# is that signer an admin on the live contract?
signer = list(signers)[0] if signers else None
if signer:
    arg = signer[2:].lower().rjust(64, "0")
    data = "0x" + keccak(b"isAdmin(address)")[:4].hex() + arg
    r = rpc("eth_call", [{"to": PROXY, "data": data}, "latest"])
    print("\nlive isAdmin(", signer, ") =", r.get("result"), r.get("error", ""))

# validate the API probe method: real route vs fake route
for path in ("/api/games/1/select-tile", "/api/games/1/increase-bet"):
    out = subprocess.run(["curl", "-s", "-m", "20", "-X", "POST", "-H", "Content-Type: application/json",
                          "-d", "{}", "-w", " [%{http_code}]", f"https://death.fun{path}"],
                         capture_output=True, text=True).stdout
    print(f"\n{path} -> {out[:220]}")
