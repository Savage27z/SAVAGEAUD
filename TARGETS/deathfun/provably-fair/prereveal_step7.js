/**
 * Step 7: brute-force the `rows` element SHAPE.
 *
 * The 143 empty-config matches proved: version string, outer JSON key order, and the seed
 * representation are all correct — but `rows` was [] in every one of them, so they tell us
 * nothing about how a populated row is serialised.
 *
 * Search the shape space: key names, field order, nesting, extra fields, seed form.
 */
const crypto = require("crypto");
const fs = require("fs");
const sha256 = (s) => crypto.createHash("sha256").update(Buffer.from(s, "utf8")).digest("hex");

const games = JSON.parse(fs.readFileSync("/tmp/settled_games.json", "utf8"))
  .filter((g) => { try { const c = JSON.parse(g.gameConfig).rowConfig; return Array.isArray(c) && c.length === 25 && !c.includes(1); } catch { return false; } })
  .sort((a, b) => a.gid - b.gid);
const subset = games.slice(0, 40);
console.log(`testing against ${subset.length} of ${games.length} games with 25-row configs`);

const dti8 = (s, i, n) => parseInt(sha256(`${s}-row${i}`).slice(0, 8), 16) % n;

/** Build many candidate `rows` serialisations for a given config+seed. */
function shapes(counts, seed, seedAlt) {
  const mult = []; let cur = 1;
  for (const t of counts) mult.push((cur *= 1 / (1 - 1 / t)) * 0.95);
  const d = counts.map((t, i) => dti8(seedAlt ?? seed, i, t));
  const out = {};

  // 1. verifier shape
  out["{tiles,deathTileIndex,multiplier}"] = { version: "v1", rows: counts.map((t, i) => ({ tiles: t, deathTileIndex: d[i], multiplier: mult[i] })), seed };
  // 2. key-name permutations
  out["{tiles,deathIndex,multiplier}"] = { version: "v1", rows: counts.map((t, i) => ({ tiles: t, deathIndex: d[i], multiplier: mult[i] })), seed };
  out["{tiles,deathTile,mul}"] = { version: "v1", rows: counts.map((t, i) => ({ tiles: t, deathTile: d[i], mul: mult[i] })), seed };
  out["{tiles,deathTileIndex,mult}"] = { version: "v1", rows: counts.map((t, i) => ({ tiles: t, deathTileIndex: d[i], mult: mult[i] })), seed };
  out["{count,deathTileIndex,multiplier}"] = { version: "v1", rows: counts.map((t, i) => ({ count: t, deathTileIndex: d[i], multiplier: mult[i] })), seed };
  // 3. field order
  out["{tiles,multiplier,deathTileIndex}"] = { version: "v1", rows: counts.map((t, i) => ({ tiles: t, multiplier: mult[i], deathTileIndex: d[i] })), seed };
  out["{deathTileIndex,tiles,multiplier}"] = { version: "v1", rows: counts.map((t, i) => ({ deathTileIndex: d[i], tiles: t, multiplier: mult[i] })), seed };
  // 4. subsets / extras
  out["{tiles,deathTileIndex}"] = { version: "v1", rows: counts.map((t, i) => ({ tiles: t, deathTileIndex: d[i] })), seed };
  out["{tiles,multiplier}"] = { version: "v1", rows: counts.map((t, i) => ({ tiles: t, multiplier: mult[i] })), seed };
  out["{tiles}"] = { version: "v1", rows: counts.map((t) => ({ tiles: t })), seed };
  out["{tiles,deathTileIndex,multiplier,selected:null}"] = { version: "v1", rows: counts.map((t, i) => ({ tiles: t, deathTileIndex: d[i], multiplier: mult[i], selected: null })), seed };
  out["{tiles,deathTileIndex,multiplier,revealed:false}"] = { version: "v1", rows: counts.map((t, i) => ({ tiles: t, deathTileIndex: d[i], multiplier: mult[i], revealed: false })), seed };
  // 5. nesting / arrays
  out["arrays[tiles,dti,mult]"] = { version: "v1", rows: counts.map((t, i) => [t, d[i], mult[i]]), seed };
  out["raw counts as rows"] = { version: "v1", rows: counts, seed };
  out["{rows,seed} no version"] = { rows: counts.map((t, i) => ({ tiles: t, deathTileIndex: d[i], multiplier: mult[i] })), seed };
  out["{version,seed,rows}"] = { version: "v1", seed, rows: counts.map((t, i) => ({ tiles: t, deathTileIndex: d[i], multiplier: mult[i] })) };
  // 6. multiplier variants inside the verifier shape
  const m2 = []; let c2 = 1, e2 = 1;
  for (const t of counts) { c2 *= 1 / (1 - 1 / t); e2 *= 0.95; m2.push(c2 * e2); }
  out["{tiles,dti,mult} 0.95^n"] = { version: "v1", rows: counts.map((t, i) => ({ tiles: t, deathTileIndex: d[i], multiplier: m2[i] })), seed };
  const m3 = []; let c3 = 1;
  for (const t of counts) m3.push(c3 *= 1 / (1 - 1 / t));
  out["mult no edge"] = { version: "v1", rows: counts.map((t, i) => ({ tiles: t, deathTileIndex: d[i], multiplier: m3[i] })), seed };
  return out;
}

const names = Object.keys(shapes(JSON.parse(subset[0].gameConfig).rowConfig, subset[0].gameSeed));
const score = {}; for (const n of names) score[n] = 0;
const seedForms = { "seed with 0x": (g) => g.gameSeed, "seed without 0x": (g) => g.gameSeed.replace(/^0x/, "") };

const scoreBoard = {};
for (const [sfName, sf] of Object.entries(seedForms)) {
  for (const n of names) scoreBoard[`${sfName} | ${n}`] = 0;
  for (const g of subset) {
    const counts = JSON.parse(g.gameConfig).rowConfig;
    const sh = shapes(counts, g.gameSeed, sf(g));
    for (const [n, obj] of Object.entries(sh)) {
      const json = JSON.stringify(obj);
      if (("0x" + sha256(json)).toLowerCase() === g.seedHash.toLowerCase()) scoreBoard[`${sfName} | ${n}`]++;
    }
  }
}
const ranked = Object.entries(scoreBoard).sort((a, b) => b[1] - a[1]);
console.log(`\n=== row-shape search (${Object.keys(scoreBoard).length} combos) ===`);
for (const [n, v] of ranked.slice(0, 10)) console.log(`  ${String(v).padStart(3)}/${subset.length}  ${n}`);
const winners = ranked.filter(([, v]) => v > 0);
console.log(`\n  combos with ANY match: ${winners.length}`);
if (!winners.length) {
  console.log("\n  No populated-row shape reproduces the commitment.");
  console.log("  Implication: the server's hashed `rows` is NOT reconstructible from the on-chain");
  console.log("  gameConfig.rowConfig using the published verifier's algorithm. Either the server");
  console.log("  commits a structure the published verifier cannot rebuild, or the committed board");
  console.log("  is built from a different config than the one stored on-chain.");
  const g = subset[0];
  const counts = JSON.parse(g.gameConfig).rowConfig;
  console.log(`\n  worked example — game ${g.gid}`);
  console.log(`    on-chain config : ${g.gameConfig}`);
  console.log(`    on-chain seed   : ${g.gameSeed}`);
  console.log(`    on-chain hash   : ${g.seedHash}`);
  const sh = shapes(counts, g.gameSeed);
  for (const n of ["{tiles,deathTileIndex,multiplier}", "{tiles}"] ) {
    console.log(`    verifier-shape [${n}] -> ${("0x" + sha256(JSON.stringify(sh[n]))).slice(0, 40)}...`);
  }
}
