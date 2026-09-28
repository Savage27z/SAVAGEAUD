#!/usr/bin/env python3
"""TayDex pass11: FALSIFIABLE CONTROL for the ABI-vs-chain mismatch.

Method: my selector census says 45 app-ABI functions exist in the deployed bytecode and 24 do
not. Predict, for every VIEW function, that 'present => returns' and 'missing => reverts'.
Then actually call them. If the prediction holds across the set, the census is sound and the
mismatch is the CONTRACT's. Any counterexample means my census is wrong and I retract.

Read-only: eth_call only. Nothing signed, nothing broadcast.
"""
import json, os, time, urllib.error, urllib.request

TGT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "taydex")
CORE = "0x3ade22fa1ef5ac75437a3734d91ba588e54875dd"
RPCS = ["https://base-rpc.publicnode.com", "https://1rpc.io/base",
        "https://mainnet.base.org", "https://base.drpc.org"]
UA = ("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36")
from Crypto.Hash import keccak as _k
def keccak(b): h = _k.new(digest_bits=256); h.update(b); return h.digest()
def sig4(s): return keccak(s.encode()).hex()[:8]

def rpc(m, p, tries=4):
    last = None
    for _ in range(tries):
        for url in RPCS:
            try:
                body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": m,
                                   "params": p}).encode()
                req = urllib.request.Request(url, data=body,
                    headers={"Content-Type": "application/json", "User-Agent": UA})
                raw = urllib.request.urlopen(req, timeout=25).read()
            except urllib.error.HTTPError as e:
                raw = e.read()
            except Exception as e:
                last = str(e); continue
            try: r = json.loads(raw)
            except Exception: last = raw[:80]; continue
            if "result" in r: return r["result"]
            if "error" in r:  return {"__e__": r["error"]}
        time.sleep(1)
    return {"__e__": last}

def u(v): return f"{int(v):064x}"
def a(x): return x.lower().replace("0x", "").rjust(64, "0")

ADDR = "0x9a7f9a7f9a7f9a7f9a7f9a7f9a7f9a7f9a7f9a7f"

# (signature, args-encoding, predicted)   predicted from pass9 census
PRED = [
    # ---- predicted PRESENT (return a value) ----
    ("owner()",                              "",                                 "PRESENT"),
    ("signer()",                             "",                                 "PRESENT"),
    ("usdc()",                               "",                                 "PRESENT"),
    ("feeRecipient()",                       "",                                 "PRESENT"),
    ("nextMarketId()",                       "",                                 "PRESENT"),
    ("MAX_OPTIONS()",                        "",                                 "PRESENT"),
    ("OUTCOME_YES()",                        "",                                 "PRESENT"),
    ("OUTCOME_NO()",                         "",                                 "PRESENT"),
    ("disputeFee()",                         "",                                 "PRESENT"),
    ("marketCreationFee()",                  "",                                 "PRESENT"),
    ("minLiquidityPerOption()",              "",                                 "PRESENT"),
    ("eip712Domain()",                       "",                                 "PRESENT"),
    ("markets(uint256)",                     u(1),                               "PRESENT"),
    ("getMarket(uint256)",                   u(1),                               "PRESENT"),
    ("getOption(uint256,uint16)",            u(1) + u(0),                        "PRESENT"),
    ("marketCreatorFees(uint256)",           u(1),                               "PRESENT"),
    ("marketDisputer(uint256)",              u(1),                               "PRESENT"),
    ("marketDisputeStake(uint256)",          u(1),                               "PRESENT"),
    ("userShares(address,uint256,uint16,uint8)", a(ADDR) + u(1) + u(0) + u(0),   "PRESENT"),
    ("nonces(address)",                      a(ADDR),                            "PRESENT"),
    ("isApprovedForAll(address,address)",    a(ADDR) + a(ADDR),                  "PRESENT"),
    ("supportsInterface(bytes4)",            "01ffc9a7".ljust(64, "0"),          "PRESENT"),
    ("uri(uint256)",                         u(1),                               "PRESENT"),
    # ---- predicted MISSING (revert: no such function) ----
    ("balanceOf(address,uint256)",           a(ADDR) + u(1),                     "MISSING"),
    ("KIND_NONE()",                          "",                                 "MISSING"),
    ("KIND_WINNER()",                        "",                                 "MISSING"),
    ("KIND_DRAW()",                          "",                                 "MISSING"),
    ("KIND_VOID()",                          "",                                 "MISSING"),
    ("OUTCOME_DRAW()",                       "",                                 "MISSING"),
    ("OUTCOME_UNRESOLVED()",                 "",                                 "MISSING"),
    ("paused()",                             "",                                 "MISSING"),
    ("pendingOwner()",                       "",                                 "MISSING"),
    ("resolutionKind(uint256)",              u(1),                               "MISSING"),
    ("getReferralAccrued(uint256,address)",  u(1) + a(ADDR),                     "MISSING"),
    ("marketReferralAccrued(uint256,address)", u(1) + a(ADDR),                   "MISSING"),
]

print("=" * 96)
print("FALSIFIABLE CONTROL: does census-predicted PRESENT/MISSING match live behaviour?")
print("=" * 96)
print(f"{'view function':<42} {'predicted':<10} {'observed':<12} verdict")
print("-" * 96)
ok = bad = 0
mismatches = []
for sig, args, pred in PRED:
    r = rpc("eth_call", [{"from": ADDR, "to": CORE, "data": "0x" + sig4(sig) + args},
                         "latest"])
    reverts = isinstance(r, dict)
    observed = "REVERTS" if reverts else "returns"
    good = (pred == "PRESENT" and not reverts) or (pred == "MISSING" and reverts)
    if good: ok += 1
    else:
        bad += 1
        mismatches.append((sig, pred, observed))
    got = ""
    if not reverts and isinstance(r, str) and r != "0x":
        v = int(r[2:][:64], 16)
        got = f"  [{v if v < 2**80 else '0x' + r[2:][24:64]}]"
    print(f"{sig:<42} {pred:<10} {observed:<12} {'ok' if good else '*** MISMATCH'}{got}")

print("-" * 96)
print(f"prediction hits: {ok}/{len(PRED)}   mismatches: {bad}")
if mismatches:
    print("\nMISMATCHES (would invalidate the census):")
    for s, p, o in mismatches:
        print(f"   {s}: predicted {p}, observed {o}")

# ---------- what the deployed contract HAS that the app doesn't know ----------
print("\n" + "=" * 96)
print("DEPLOYED-ONLY PUSH4 SELECTORS (in bytecode, not in the app ABI)")
print("=" * 96)
code = rpc("eth_getCode", [CORE, "latest"])[2:]
by = bytes.fromhex(code)
PUSH1 = 0x60
push4, i, n = set(), 0, len(by)
while i < n:
    op = by[i]
    if op == 0x63 and i + 4 < n: push4.add(by[i+1:i+5].hex())
    if PUSH1 <= op <= 0x7f: i += 1 + (op - PUSH1 + 1)
    elif op == 0x5f:        i += 1
    else:                   i += 1

abi = json.load(open(os.path.join(TGT, "abi_core.json")))
def sig_of(e):
    ins = []
    for x in e.get("inputs", []):
        t = x.get("type", "?")
        if t.startswith("tuple"):
            t = "(" + ",".join(c.get("type", "?") for c in x.get("components", [])) + ")" + t[5:]
        ins.append(t)
    return f"{e['name']}({','.join(ins)})"
known = {sig4(sig_of(e)) for e in abi if e.get("type") == "function"}
unknown = sorted(push4 - known)
print(f"  {len(unknown)} selector(s) not in the app ABI")
json.dump(unknown, open(os.path.join(TGT, "deployed_only_selectors.json"), "w"), indent=1)
for s in unknown:
    print(f"    0x{s}")
print("\n  (resolve these against 4byte.directory next - they identify what the OLDER "
      "deployed version implemented)")
