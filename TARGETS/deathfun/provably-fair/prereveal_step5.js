/**
 * Step 5: are the `rows: []` (board-not-committed) games the CURRENT mode?
 *
 * If the un-committed games cluster at the top of the gameId range, the live mode is the one
 * whose commitment carries no board — meaning the death tiles can be chosen after the player
 * has already picked.
 */
const crypto = require("crypto");
const fs = require("fs");
const sha256Hex = (s) => crypto.createHash("sha256").update(Buffer.from(s, "utf8")).digest("hex");

const games = JSON.parse(fs.readFileSync("/tmp/settled_games.json", "utf8"))
  .sort((a, b) => a.gid - b.gid);

const rows = games.map((g) => {
  let cfg = {}; try { cfg = JSON.parse(g.gameConfig); } catch {}
  let st = {}; try { st = JSON.parse(g.gameState); } catch {}
  const rc = cfg.rowConfig;
  const len = Array.isArray(rc) ? rc.length : -1;
  const json = JSON.stringify({ version: g.algoVersion || "v1", rows: [], seed: g.gameSeed });
  const emptyMatch = "0x" + sha256Hex(json) === g.seedHash.toLowerCase();
  return { gid: g.gid, t: g.createdAt, status: g.status, len, emptyMatch,
           picks: Array.isArray(st.selectedTiles) ? st.selectedTiles.length : 0,
           bet: g.betAmount, payout: g.payout, cfg: g.gameConfig };
});

console.log("=== gameId span of the sample ===");
console.log(`  ${rows[0].gid} .. ${rows[rows.length - 1].gid}   (${rows.length} games)`);

const empty = rows.filter((r) => r.len === 0);
const nonEmpty = rows.filter((r) => r.len > 0);
const range = (a) => a.length ? `${a[0].gid}..${a[a.length - 1].gid}` : "-";

console.log(`\n=== rowConfig: []  (board NOT committed) ===`);
console.log(`  count        : ${empty.length}`);
console.log(`  gameId range : ${range(empty)}`);
console.log(`  empty-hash reproduces for all of them: ${empty.every((r) => r.emptyMatch)}`);
const wonE = empty.filter((r) => r.status === 1), lostE = empty.filter((r) => r.status === 2);
console.log(`  Won ${wonE.length} / Lost ${lostE.length}`);
if (wonE.length) {
  const pay = wonE.map((r) => r.payout / r.bet);
  console.log(`  payout multiple on wins: min ${Math.min(...pay).toFixed(4)}x  max ${Math.max(...pay).toFixed(4)}x`);
}
const picks = [...new Set(empty.map((r) => r.picks))].sort((a, b) => a - b);
console.log(`  distinct pick-counts: ${picks.join(", ")}`);

console.log(`\n=== rowConfig non-empty (board committed) ===`);
console.log(`  count        : ${nonEmpty.length}`);
console.log(`  gameId range : ${range(nonEmpty)}`);
const lens = {}; for (const r of nonEmpty) lens[r.len] = (lens[r.len] || 0) + 1;
console.log(`  config lengths: ${Object.entries(lens).map(([k, v]) => `${k}->${v}`).join("  ")}`);

console.log(`\n=== interleaving: last 40 games by id (E = empty/board-free config) ===`);
const tail = rows.slice(-40);
console.log("  " + tail.map((r) => `${r.gid}${r.len === 0 ? "(E)" : `(${r.len})`}`).join(" "));

console.log(`\n=== per-mode timeline (first and last createdAt) ===`);
const ts = (x) => new Date(x * 1000).toISOString().replace("T", " ").slice(0, 19);
if (empty.length) console.log(`  empty-config   : ${ts(empty[0].t)}  ..  ${ts(empty[empty.length - 1].t)}`);
if (nonEmpty.length) console.log(`  normal-config  : ${ts(nonEmpty[0].t)}  ..  ${ts(nonEmpty[nonEmpty.length - 1].t)}`);

console.log(`\n=== sample empty-config games (full detail) ===`);
for (const r of empty.slice(-8)) {
  console.log(`  game ${r.gid} ${r.status === 1 ? "Won " : "Lost"} picks=${JSON.stringify(r.cfg)} state=${JSON.stringify(r.cfg)}`);
}
fs.writeFileSync("/tmp/mode_split.json", JSON.stringify({ empty, nonEmpty }, null, 2));
console.log("\nwrote /tmp/mode_split.json");
