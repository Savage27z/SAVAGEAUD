#!/usr/bin/env python3
"""TayDex pass7: READ-ONLY on-chain probes of 0x3ade22fa.. (Base).
Every call here is eth_call / eth_getCode / eth_getStorageAt -- a simulation against public
state. Nothing is signed, nothing is broadcast, no key is used, no state changes.

Goal: (1) read live config + real market data, (2) probe which mutating functions are
caller-gated by simulating them from a random address and decoding the revert.
"""
import json, os, random, re, time, urllib.error, urllib.request

TGT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "taydex")
CORE = "0x3ade22fa1ef5ac75437a3734d91ba588e54875dd"
RPCS = ["https://base-rpc.publicnode.com", "https://base.llamarpc.com",
        "https://1rpc.io/base", "https://base.drpc.org", "https://mainnet.base.org"]

abi = json.load(open(os.path.join(TGT, "abi_core.json")))

# ---------- minimal ABI encoder ----------
def sel(sig):
    import hashlib
    return hashlib.sha3_256(sig.encode()).hexdigest()[:8] if False else None

def keccak(data: bytes) -> bytes:
    """keccak256 via pycryptodome if present, else eth_hash, else sha3 (flagged)."""
    try:
        from Crypto.Hash import keccak as _k
        h = _k.new(digest_bits=256); h.update(data); return h.digest()
    except Exception:
        pass
    try:
        from eth_hash.auto import keccak as _k
        return _k(data)
    except Exception:
        import hashlib
        return hashlib.sha3_256(data).digest()   # WRONG for EVM; caller must detect

EVM_OK = True
try:
    from Crypto.Hash import keccak as _k
except Exception:
    try:
        from eth_hash.auto import keccak as _kh
    except Exception:
        EVM_OK = False

def sig4(sig: str) -> str:
    return "0x" + keccak(sig.encode()).hex()[:8]

def enc_uint(v):  return f"{int(v):064x}"
def enc_addr(a):  return a.lower().replace("0x", "").rjust(64, "0")
def enc_bool(b):  return enc_uint(1 if b else 0)

UA = ("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36")

def rpc(method, params, tries=3):
    """NOTE: the default urllib UA is WAF-blocked (HTTP 403) by these RPCs while curl
    succeeds -> always send a browser UA. Bodies of HTTPError responses are read so the
    real JSON-RPC error surfaces instead of being swallowed."""
    last = None
    for attempt in range(tries):
        for url in RPCS:
            try:
                body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method,
                                   "params": params}).encode()
                req = urllib.request.Request(
                    url, data=body,
                    headers={"Content-Type": "application/json",
                             "Accept": "application/json",
                             "User-Agent": UA})
                raw = urllib.request.urlopen(req, timeout=25).read()
            except urllib.error.HTTPError as e:
                try:
                    raw = e.read()
                except Exception:
                    last = f"HTTP {e.code}"
                    continue
            except Exception as e:
                last = f"{type(e).__name__}: {e}"
                continue
            try:
                r = json.loads(raw)
            except Exception:
                last = f"non-JSON: {raw[:120]!r}"
                continue
            if "result" in r:
                return r["result"], url
            if "error" in r:
                return {"__error__": r["error"]}, url
        time.sleep(1.0)
    return {"__error__": f"all RPCs failed: {last}"}, None

def call(data, frm="0x000000000000000000000000000000000000dEaD", to=CORE):
    return rpc("eth_call", [{"from": frm, "to": to, "data": data}, "latest"])

if not EVM_OK:
    raise SystemExit("NO KECCAK: need pycryptodome (pip install pycryptodome)")

print(f"[sel] signer()          = {sig4('signer()')}")
print(f"[sel] pushReferral(uint256,address) = {sig4('pushReferral(uint256,address)')}\n")

# ---------- (1) live state reads ----------
READS = [
    ("owner()",                  "owner()"),
    ("pendingOwner()",           "pendingOwner()"),
    ("signer()",                 "signer()"),
    ("usdc()",                   "usdc()"),
    ("feeRecipient()",           "feeRecipient()"),
    ("paused()",                 "paused()"),
    ("nextMarketId()",           "nextMarketId()"),
    ("MAX_OPTIONS()",            "MAX_OPTIONS()"),
    ("OUTCOME_YES()",            "OUTCOME_YES()"),
    ("OUTCOME_NO()",             "OUTCOME_NO()"),
    ("OUTCOME_DRAW()",           "OUTCOME_DRAW()"),
    ("OUTCOME_UNRESOLVED()",     "OUTCOME_UNRESOLVED()"),
    ("KIND_NONE()",              "KIND_NONE()"),
    ("KIND_WINNER()",            "KIND_WINNER()"),
    ("KIND_DRAW()",              "KIND_DRAW()"),
    ("KIND_VOID()",              "KIND_VOID()"),
    ("disputeFee()",             "disputeFee()"),
    ("marketCreationFee()",      "marketCreationFee()"),
    ("minLiquidityPerOption()",  "minLiquidityPerOption()"),
]
print("=" * 78)
print("(1) LIVE CONFIG  (read-only eth_call)")
print("=" * 78)
live = {}
for label, s in READS:
    res, url = call(sig4(s))
    live[label] = res
    if isinstance(res, str) and res.startswith("0x") and len(res) == 66:
        v = int(res, 16)
        as_addr = "0x" + res[-40:]
        print(f"  {label:<26} = {v:<12} (raw {res})  {'' if v > 2**32 else ''}"
              f"{'  addr=' + as_addr if v > 2**96 else ''}")
    else:
        print(f"  {label:<26} = {res}")

# ---------- (2) real markets ----------
print("\n" + "=" * 78)
print("(2) REAL MARKET STATE")
print("=" * 78)
n = live.get("nextMarketId()")
nextid = int(n, 16) if isinstance(n, str) else None
print(f"  nextMarketId = {nextid}")
if nextid:
    for mid in range(1, min(nextid, 7)):
        r, _ = call(sig4("getMarket(uint256)") + enc_uint(mid))
        if isinstance(r, str) and len(r) >= 2 + 64 * 6:
            b = r[2:]
            creator = "0x" + b[24:64]
            endDate = int(b[64:128], 16)
            numOpt = int(b[128:192], 16)
            feeBps = int(b[192:256], 16)
            resolved = int(b[256:320], 16)
            win = int(b[320:384], 16)
            win = win - 2**16 if win >= 2**15 else win
            print(f"  market {mid}: creator={creator} endDate={endDate} "
                  f"options={numOpt} creatorFeeBps={feeBps} resolved={bool(resolved)} "
                  f"winning={win}")
        else:
            print(f"  market {mid}: {r}")
        o, _ = call(sig4("getOption(uint256,uint16)") + enc_uint(mid) + enc_uint(0))
        print(f"      option0 = {o}")

# ---------- (3) nonce namespace ----------
print("\n" + "=" * 78)
print("(3) NONCE NAMESPACE  (the only thing binding a signature to an actor)")
print("=" * 78)
rand1 = "0x" + "".join(random.choice("0123456789abcdef") for _ in range(40))
rand2 = "0x" + "".join(random.choice("0123456789abcdef") for _ in range(40))
signer_addr = None
if isinstance(live.get("signer()"), str):
    signer_addr = "0x" + live["signer()"][-40:]
for label, a in [("random-fresh-1", rand1), ("random-fresh-2", rand2),
                 ("signer", signer_addr), ("owner", "0x" + live["owner()"][-40:]
                                           if isinstance(live.get("owner()"), str) else None)]:
    if not a:
        continue
    r, _ = call(sig4("nonces(address)") + enc_addr(a))
    print(f"  nonces({label} {a}) = {int(r, 16) if isinstance(r, str) else r}")

# ---------- (4) guard probes: simulate mutating fns from a random address ----------
print("\n" + "=" * 78)
print("(4) GUARD PROBES - simulate from a RANDOM address, decode the revert")
print("   a revert = gated (or would fail for another reason - decoded below)")
print("=" * 78)

# OZ v5 ownable + common selectors
ERRMAP = {
    "0x118cdaa7": "OwnableUnauthorizedAccount(address)",
    "0x1e4fbdf7": "OwnableInvalidOwner(address)",
    "0x8f4eb604": "EnforcedPause()",
    "0xd93c0665": "ExpectedPause()",
    "0xcd3f1659": "ERC1155InsufficientBalance(...)",
    "0xfb8f41b2": "ERC20InsufficientAllowance(...)",
    "0xe450d38c": "ERC20InsufficientBalance(...)",
    "0xf4d678b8": "InsufficientBalance()",
    "0x82b42900": "Unauthorized()",
    "0x90b8ec18": "TransferFailed()",
    "0x2c5211c6": "InvalidArgs()",
    "0x48f5c3ed": "ZeroAddress()",
    "0x1a1a1a1a": "?",
}
# any custom errors declared in the ABI -> exact selectors from their signature
for e in abi:
    if e.get("type") == "error":
        s = f"{e['name']}({','.join(i.get('type','?') for i in e.get('inputs',[]))})"
        ERRMAP[sig4(s)] = s

PROBES = [
    ("pushReferral(uint256,address)",        sig4("pushReferral(uint256,address)") + enc_uint(1) + enc_addr(rand1)),
    ("pushReferralBatch(uint256[],address[])", None),   # dynamic - skip encoding, note only
    ("rescueToken(address,address,uint256)", sig4("rescueToken(address,address,uint256)") + enc_addr("0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913") + enc_addr(rand1) + enc_uint(1)),
    ("sweepLeftover(uint256,uint16)",        sig4("sweepLeftover(uint256,uint16)") + enc_uint(1) + enc_uint(0)),
    ("setSigner(address)",                   sig4("setSigner(address)") + enc_addr(rand1)),
    ("setFeeRecipient(address)",             sig4("setFeeRecipient(address)") + enc_addr(rand1)),
    ("setMarketCreatorFeeShare(uint256,uint16)", sig4("setMarketCreatorFeeShare(uint256,uint16)") + enc_uint(1) + enc_uint(9999)),
    ("setDisputeFee(uint256)",               sig4("setDisputeFee(uint256)") + enc_uint(0)),
    ("setConfig(uint256,uint256)",           sig4("setConfig(uint256,uint256)") + enc_uint(0) + enc_uint(0)),
    ("pause()",                              sig4("pause()")),
    ("unpause()",                            sig4("unpause()")),
    ("voidMarket(uint256)",                  sig4("voidMarket(uint256)") + enc_uint(1)),
    ("resolveMarket(uint256,uint16)",        sig4("resolveMarket(uint256,uint16)") + enc_uint(1) + enc_uint(0)),
    ("resolveSingleBinary(uint256,bool)",    sig4("resolveSingleBinary(uint256,bool)") + enc_uint(1) + enc_bool(True)),
    ("resolveDraw(uint256)",                 sig4("resolveDraw(uint256)") + enc_uint(1)),
    ("resolveDispute(uint256,bool)",         sig4("resolveDispute(uint256,bool)") + enc_uint(1) + enc_bool(True)),
    ("claimCreatorFees(uint256)",            sig4("claimCreatorFees(uint256)") + enc_uint(1)),
    ("claimReferral(uint256)",               sig4("claimReferral(uint256)") + enc_uint(1)),
    ("claim(uint256,uint16)",                sig4("claim(uint256,uint16)") + enc_uint(1) + enc_uint(0)),
    ("dispute(uint256)",                     sig4("dispute(uint256)") + enc_uint(1)),
]
for label, data in PROBES:
    if data is None:
        print(f"  {label:<42} (dynamic args - not probed here)")
        continue
    r, url = call(data)
    if isinstance(r, dict) and "__error__" in r:
        print(f"  {label:<42} NODE-ERR {str(r['__error__'])[:60]}")
        continue
    if isinstance(r, str) and r.startswith("0x") and r != "0x":
        print(f"  {label:<42} RETURNED 0x{r[2:][:66]}  <-- survived simulation")
    elif r == "0x":
        print(f"  {label:<42} returned empty (ok / no return value)  <-- SURVIVED SIM")
    else:
        print(f"  {label:<42} revert={r}")
        m = re.search(r'0x[0-9a-fA-F]{8}', str(r))
        if m:
            print(f"      -> selector {m.group(0)} = {ERRMAP.get(m.group(0), 'UNKNOWN')}")
