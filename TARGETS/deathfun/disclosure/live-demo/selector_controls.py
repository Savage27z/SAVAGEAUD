import importlib.util
from Crypto.Hash import keccak as _k
spec = importlib.util.spec_from_file_location(
    "rd", "/root/.hermes/workspace/SAVAGEAUD/TARGETS/deathfun/disclosure/live-demo/replay_demo.py")
rd = importlib.util.module_from_spec(spec); spec.loader.exec_module(rd)

def er(sig):
    h = _k.new(digest_bits=256); h.update(sig.encode()); return "0x" + h.hexdigest()[:8]

SIGEXPIRED = er("SignatureExpired()")
print("SignatureExpired() selector from source:", SIGEXPIRED)

def probe(label, data):
    try:
        r = rd.rpc("eth_call", [{"to": rd.CONTRACT, "data": data, "from": "0x" + "22"*20}, "latest"])
        print(f"  {label:34} -> RETURNED {str(r)[:80]}")
    except RuntimeError as e:
        d = ""
        try:
            import ast; d = ast.literal_eval(str(e)).get("data", "")
        except Exception: pass
        tag = "  <== SignatureExpired()  FUNCTION EXISTS" if d == SIGEXPIRED else ""
        print(f"  {label:34} -> revert data {d}{tag}")

print("\n=== existence proofs on the LIVE proxy (positive, not absence inference) ===")
probe("increaseBet (deadline=1, expired)",
      rd.selector("increaseBet(uint256,uint256,uint256,bytes)")
      + rd.enc_uint(4838798) + rd.enc_uint(0) + rd.enc_uint(1) + rd.enc_uint(0x80) + rd.enc_uint(0))

probe("increaseBet v2-style (also deadline=1)",
      rd.selector("increaseBet(uint256,uint256,uint256,bytes)")
      + rd.enc_uint(1) + rd.enc_uint(10**15) + rd.enc_uint(1) + rd.enc_uint(0x80) + rd.enc_uint(0))

print("\n=== controls ===")
probe("nonexistent selector 0xdeadbeef", "0xdeadbeef")
probe("games(nonexistent id)", rd.selector("games(uint256)") + rd.enc_uint(999999999))
probe("claimRakeback (v2 only, not deployed)",
      rd.selector("claimRakeback(uint256,uint256,bytes)") + rd.enc_uint(0) + rd.enc_uint(0) + rd.enc_uint(0x60) + rd.enc_uint(0))
