/**
 * Step 4: explain the 143 / 755 split.
 *
 * Question 1: the 143 games whose on-chain gameSeedHash I reproduced all did so with
 *             `rows: []` in the committed JSON. If those games are PLAYABLE, their board was
 *             never committed — the server would be free to choose the death tile after seeing
 *             the player's picks. That would be a Critical fairness break.
 *
 * Question 2: the 755 that did NOT reproduce. Either my row/multiplier reconstruction is
 *             subtly wrong, or the committed rows differ from the on-chain gameConfig — which
 *             would also be a fairness break. Need to know which.
 */
const crypto = require("crypto");
const fs = require("fs");

const sha256Hex = (s) => crypto.createHash("sha256").update(Buffer.from(s, "utf8")).digest("hex");
const dti = (seed, i, n) => parseInt(sha256Hex(`${seed}-row${i}`).slice(0, 8), 16) % n;

function rowsFor(counts, seed, edge = 0.05, mode = "cum_edge_each") {
  const mult = [];
  let cur = 1;
  for (const t of counts) {
    cur *= 1 / (1 - 1 / t);
    mult.push(mode === "cum_edge_each" ? cur * (1 - edge) : cur);
  }
  if (mode === "edge_at_end") for (let i = 0; i < mult.length; i++) mult[i] *= (1 - edge);
  return counts.map((t, i) => ({ tiles: t, deathTileIndex: dti(seed, i, t), multiplier: mult[i] }));
}
function commitJson(rows, seed, version = "v1") {
  return JSON.stringify({ version, rows, seed });
}

const games = JSON.parse(fs.readFileSync("/tmp/settled_games.json", "utf8"));

// ---- Q1: what are the 143 rows:[] games, really?
const emptyRows = [], matchedNonEmpty = [];
for (const g of games) {
  let cfg; try { cfg = JSON.parse(g.gameConfig); } catch { continue; }
  const counts = cfg.rowConfig;
  if (!Array.isArray(counts)) continue;
  const rows = rowsFor(counts, g.gameSeed);
  const h = "0x" + sha256Hex(commitJson(rows, g.gameSeed, g.algoVersion || "v1"));
  const match = h.toLowerCase() === g.seedHash.toLowerCase();
  if (match && counts.length === 0) emptyRows.push(g);
  if (match && counts.length > 0) matchedNonEmpty.push(g);
}

console.log("=== Q1: games whose commitment reproduced ===");
console.log(`  with rows: []          : ${emptyRows.length}`);
console.log(`  with a non-empty board : ${matchedNonEmpty.length}`);

const describe = (arr, label) => {
  console.log(`\n  ${label} — sample:`);
  for (const g of arr.slice(0, 6)) {
    let cfg = {}; try { cfg = JSON.parse(g.gameConfig); } catch {}
    let st = {}; try { st = JSON.parse(g.gameState); } catch {}
    console.log(`    game ${g.gid} status=${g.status === 1 ? "Won" : "Lost"} bet=${g.betAmount / 1e18} payout=${g.payout / 1e18}`);
    console.log(`        gameConfig  = ${g.gameConfig}`);
    console.log(`        gameState   = ${g.gameState}`);
    console.log(`        rowConfig len = ${(cfg.rowConfig || []).length}`);
  }
};
describe(emptyRows, "rows:[] matches");
describe(matchedNonEmpty, "non-empty matches");

// distribution of rowConfig length across ALL games
const byLen = {};
for (const g of games) {
  let cfg; try { cfg = JSON.parse(g.gameConfig); } catch { continue; }
  const n = (cfg.rowConfig || []).length;
  byLen[n] = (byLen[n] || 0) + 1;
}
console.log(`\n  rowConfig length distribution across ${games.length} settled games:`);
for (const k of Object.keys(byLen).sort((a, b) => a - b)) {
  console.log(`    length ${String(k).padStart(3)} : ${byLen[k]} games`);
}

// ---- Q2: for non-reproducing games, find the right formula
console.log("\n=== Q2: hunting the correct `rows` representation ===");
const variants = {
  "cum*edge, edge each row (0.05)": (c, s) => rowsFor(c, s, 0.05, "cum_edge_each"),
  "cum, no edge": (c, s) => rowsFor(c, s, 0.05, "none"),
  "cum, edge at end": (c, s) => rowsFor(c, s, 0.05, "edge_at_end"),
  "cum*edge 0.045": (c, s) => rowsFor(c, s, 0.045, "cum_edge_each"),
  "cum*edge 0.04": (c, s) => rowsFor(c, s, 0.04, "cum_edge_each"),
  "cum/1.05": (c, s) => { let cur = 1; const m = []; for (const t of c) { cur *= 1 / (1 - 1 / t); m.push(cur / 1.05); } return c.map((t, i) => ({ tiles: t, deathTileIndex: dti(s, i, t), multiplier: m[i] })); },
};
const score = {};
for (const [name, fn] of Object.entries(variants)) score[name] = 0;
for (const g of games) {
  let cfg; try { cfg = JSON.parse(g.gameConfig); } catch { continue; }
  const counts = cfg.rowConfig;
  if (!Array.isArray(counts) || counts.length === 0) continue;
  for (const [name, fn] of Object.entries(variants)) {
    try {
      const h = "0x" + sha256Hex(commitJson(fn(counts, g.gameSeed), g.gameSeed, g.algoVersion || "v1"));
      if (h.toLowerCase() === g.seedHash.toLowerCase()) score[name]++;
    } catch {}
  }
}
for (const [n, v] of Object.entries(score).sort((a, b) => b[1] - a[1])) console.log(`  ${String(v).padStart(4)} matches  ${n}`);

console.log("\n=== show the delta for one non-matching game (same config across variants) ===");
const target = games.find((g) => {
  try { return JSON.parse(g.gameConfig).rowConfig.length === 4; } catch { return false; }
});
if (target) {
  const counts = JSON.parse(target.gameConfig).rowConfig;
  console.log(`  game ${target.gid} config=${target.gameConfig}`);
  console.log(`  on-chain hash: ${target.seedHash}`);
  for (const [name, fn] of Object.entries(variants)) {
    const json = commitJson(fn(counts, target.gameSeed), target.gameSeed, target.algoVersion || "v1");
    console.log(`    ${name}`);
    console.log(`      json: ${json.slice(0, 220)}`);
    console.log(`      hash: ${"0x" + sha256Hex(json)}`);
  }
}
