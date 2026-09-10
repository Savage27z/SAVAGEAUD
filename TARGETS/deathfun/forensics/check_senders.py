import json, collections

rows = json.load(open("/tmp/deathfun/bet_decoded.json"))
logs = json.load(open("/tmp/deathfun/betincrease.json"))
logs.sort(key=lambda l: int(l["blockNumber"], 16))

# event: topics[1] = gameId, topics[2] = player (indexed)
by_tx = {l["transactionHash"]: l for l in logs}

match = 0
mismatch = 0
froms = collections.Counter()
players = collections.Counter()
samples = []
for r in rows:
    l = by_tx.get(r["tx"])
    if not l:
        continue
    player = "0x" + l["topics"][2][-40:]
    sender = (r["from"] or "").lower()
    players[player] += 1
    froms[sender] += 1
    if sender == player:
        match += 1
    else:
        mismatch += 1
        if len(samples) < 5:
            samples.append((r["tx"], sender, player))

print("txs where tx.from == game.player :", match)
print("txs where they differ            :", mismatch)
print("\nnumber of distinct senders :", len(froms))
print("top senders:", froms.most_common(3))
print("\nnumber of distinct players :", len(players))
print("top players:", players.most_common(3))
print("\nmismatch samples:", samples)

print("\nsample rows:")
for r in rows[:3]:
    l = by_tx[r["tx"]]
    print("  gid", r["gid"], "amount", r["amount"] / 1e18, "value", r["value"] / 1e18,
          "from", r["from"], "player", "0x" + l["topics"][2][-40:])
