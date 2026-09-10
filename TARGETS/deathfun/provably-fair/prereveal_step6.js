/**
 * Step 6: why don't the 755 real-board games reproduce?
 *
 * The 143 empty-config games reproduce byte-exact, which proves my JSON structure, version
 * string AND seed representation are all correct (the seed is inside that JSON). So the error
 * can only be in the `rows` array: deathTileIndex, multiplier, or both.
 *
 * Brute-force the (deathTileIndex x multiplier) space against real games and find the combo
 * that reproduces the on-chain commitment.
 */
const crypto = require("crypto");
const fs = require("fs");
const sha256 = (s) => crypto.createHash("sha256").update(Buffer.from(s, "utf8")).digest("hex");

const games = JSON.parse(fs.readFileSync("/tmp/settled_games.json", "utf8"))
  .filter((g) => { try { const c = JSON.parse(g.gameConfig).rowConfig; return Array.isArray(c) && c.length > 0 && !c.includes(1); } catch { return false; } })
  .sort((a, b) => a.gid - b.gid);
console.log(`testing against ${games.length} real-board games (no 1-tile rows)`);
console.log(`sample: ${games.slice(0, 5).map((g) => `${g.gid}:${g.gameConfig}`).join("  ")}\n`);

const DTI = {
  "slice8%n (verifier)": (s, i, n) => parseInt(sha256(`${s}-row${i}`).slice(0, 8), 16) % n,
  "slice16%n": (s, i, n) => parseInt(sha256(`${s}-row${i}`).slice(0, 16), 16) % n,
  "bigint(whole)%n": (s, i, n) => Number(BigInt("0x" + sha256(`${s}-row${i}`)) % BigInt(n)),
  "slice8%n no-dash": (s, i, n) => parseInt(sha256(`${s}row${i}`).slice(0, 8), 16) % n,
  "slice8%n i-seed": (s, i, n) => parseInt(sha256(`row${i}-${s}`).slice(0, 8), 16) % n,
  "slice8%n dash-i": (s, i, n) => parseInt(sha256(`${s}-${i}`).slice(0, 8), 16) % n,
  "slice8%n 1-indexed": (s, i, n) => parseInt(sha256(`${s}-row${i + 1}`).slice(0, 8), 16) % n,
  "lastBytes%d": (s, i, n) => parseInt(sha256(`${s}-row${i}`).slice(-8), 16) % n,
};

const MULT = {
  "cum*0.95 each": (c) => { let cur = 1; return c.map((t) => (cur *= 1 / (1 - 1 / t)) * 0.95); },
  "cum*(0.95^(i+1))": (c) => { let cur = 1, e = 1; return c.map((t) => { cur *= 1 / (1 - 1 / t); e *= 0.95; return cur * e; }); },
  "cum no edge": (c) => { let cur = 1; return c.map((t) => (cur *= 1 / (1 - 1 / t))); },
  "cum*0.95 round4": (c) => { let cur = 1; return c.map((t) => Math.round((cur *= 1 / (1 - 1 / t)) * 0.95 * 1e4) / 1e4); },
  "cum*0.95 round2": (c) => { let cur = 1; return c.map((t) => Math.round((cur *= 1 / (1 - 1 / t)) * 0.95 * 100) / 100); },
  "cum/1.05 each": (c) => { let cur = 1; return c.map((t) => (cur *= 1 / (1 - 1 / t)) / 1.05); },
  "cum*0.96 each": (c) => { let cur = 1; return c.map((t) => (cur *= 1 / (1 - 1 / t)) * 0.96); },
  "cum*0.9 each": (c) => { let cur = 1; return c.map((t) => (cur *= 1 / (1 - 1 / t)) * 0.9); },
};

const results = [];
for (const [dn, df] of Object.entries(DTI)) {
  for (const [mn, mf] of Object.entries(MULT)) {
    let hits = 0, tried = 0;
    for (const g of games) {
      const counts = JSON.parse(g.gameConfig).rowConfig;
      const mult = mf(counts);
      const rows = counts.map((t, i) => ({ tiles: t, deathTileIndex: df(g.gameSeed, i, t), multiplier: mult[i] }));
      const json = JSON.stringify({ version: g.algoVersion || "v1", rows, seed: g.gameSeed });
      const h = "0x" + sha256(json);
      tried++;
      if (h.toLowerCase() === g.seedHash.toLowerCase()) hits++;
    }
    results.push({ dn, mn, hits, tried });
  }
}
results.sort((a, b) => b.hits - a.hits);
console.log("=== (deathTileIndex x multiplier) grid, best first ===");
for (const r of results.slice(0, 12)) {
  console.log(`  ${String(r.hits).padStart(4)}/${r.tried}  DTI[${r.dn}]  MULT[${r.mn}]`);
}
console.log(`\n  total combos tested: ${results.length}   combos with any hit: ${results.filter((r) => r.hits > 0).length}`);

// show the gap for the single best combo on one game
const best = results[0];
const g = games[0];
const counts = JSON.parse(g.gameConfig).rowConfig;
const mult = MULT[best.mn](counts);
const rows = counts.map((t, i) => ({ tiles: t, deathTileIndex: DTI[best.dn](g.gameSeed, i, t), multiplier: mult[i] }));
const json = JSON.stringify({ version: g.algoVersion || "v1", rows, seed: g.gameSeed });
console.log(`\n=== best combo applied to game ${g.gid} (config ${g.gameConfig}) ===`);
console.log(`  config length : ${counts.length}`);
console.log(`  json length   : ${json.length}`);
console.log(`  computed      : ${"0x" + sha256(json)}`);
console.log(`  on-chain      : ${g.seedHash}`);
console.log(`  first 200 of json: ${json.slice(0, 200)}`);

// does the on-chain config even have the right LENGTH vs what a 25-row board needs?
console.log(`\n=== sanity: are the on-chain configs plausible as hashed input at all? ===`);
console.log(`  distinct configs: ${new Set(games.map((g) => g.gameConfig)).size} across ${games.length} games`);
const counter = {};
for (const g of games) counter[g.gameConfig] = (counter[g.gameConfig] || 0) + 1;
for (const [c, n] of Object.entries(counter).sort((a, b) => b[1] - a[1]).slice(0, 5)) {
  console.log(`    ${String(n).padStart(4)}x  ${c.slice(0, 110)}`);
}
