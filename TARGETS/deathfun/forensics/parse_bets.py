import json, collections, datetime

SEL = "0b669290"
txs = json.load(open("/tmp/deathfun/bet_txs.json"))
print("txs:", len(txs))

seen = collections.defaultdict(list)
rows = []
bad = 0
for t in txs:
    inp = (t.get("input") or "0x")
    if not inp[2:].lower().startswith(SEL):
        bad += 1
        continue
    body = inp[2 + 8:]
    w = [body[i:i + 64] for i in range(0, len(body), 64)]
    gid = int(w[0], 16)
    amount = int(w[1], 16)
    deadline = int(w[2], 16)
    off_words = int(w[3], 16) // 32
    slen = int(w[off_words], 16)
    sig = "".join(w[off_words + 1: off_words + 1 + (slen + 31) // 32])[:slen * 2]
    seen[sig].append(t["hash"])
    rows.append({"gid": gid, "amount": amount, "deadline": deadline,
                 "value": int(t.get("value", "0x0"), 16), "sig": sig, "tx": t["hash"],
                 "from": t.get("from"), "block": int(t.get("blockNumber", "0x0"), 16)})

print("parsed:", len(rows), "non-matching selector:", bad)
print("DISTINCT signatures:", len(seen))
dupes = {s: h for s, h in seen.items() if len(h) > 1}
print("REUSED signatures (same sig, >1 tx):", len(dupes))
for s, h in list(dupes.items())[:5]:
    print("   ", s[:40], "->", len(h), "times", h[:3])

print("\nvalue attached:", collections.Counter(r["value"] for r in rows).most_common(5))
print("value == 0 count:", sum(1 for r in rows if r["value"] == 0))
print("amount == 0 count:", sum(1 for r in rows if r["amount"] == 0))

dl = [r["deadline"] for r in rows]
print("\ndeadline range:", datetime.datetime.utcfromtimestamp(min(dl)), "->", datetime.datetime.utcfromtimestamp(max(dl)))
ts = sorted(r["block"] for r in rows)
json.dump(rows, open("/tmp/deathfun/bet_decoded.json", "w"))
print("saved")
