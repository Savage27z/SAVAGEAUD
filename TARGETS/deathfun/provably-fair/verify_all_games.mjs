// Verify every settled game's on-chain seedHash against candidate algorithms.
// Uses exact JS semantics: Math.round(1e8*e)/1e8 and JSON.stringify key order.
import crypto from "node:crypto";
import fs from "node:fs";

const sha = (s) => crypto.createHash("sha256").update(s).digest("hex");
const dti = (seed, i, t) => parseInt(sha(`${seed}-row${i}`).slice(0, 8), 16) % t;

const games = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));

function build(cfg, seed, he, prec, order) {
  let l = 1, rows = [];
  for (let i = 0; i < cfg.length; i++) {
    const t = cfg[i];
    if (t < 2) return null;
    l *= 1 / (1 - 1 / t);
    const o = l * (1 - he);
    const m = prec === null ? o : Math.round(o * prec) / prec; // JS round-half-up
    const d = dti(seed, i, t);
    rows.push(order === "verifier"
      ? { tiles: t, deathTileIndex: d, multiplier: m }
      : { tiles: t, multiplier: m, deathTileIndex: d });
  }
  return rows;
}

const variants = [];
for (const he of [0.04, 0.05]) {
  for (const prec of [null, 1e8, 1e4, 100]) {
    for (const order of ["verifier", "api"]) {
      variants.push({ he, prec, order, n: 0, label: `he=${he} prec=${prec} order=${order}` });
    }
  }
}

let usable = 0, emptyCfg = 0;
for (const g of games) {
  let cfg;
  try { cfg = JSON.parse(g.gameConfig).rowConfig; } catch { cfg = null; }
  if (cfg === null || cfg === undefined) continue;
  if (cfg.length === 0) { emptyCfg++; continue; }
  usable++;
  for (const v of variants) {
    const rows = build(cfg, g.gameSeed, v.he, v.prec, v.order);
    if (!rows) continue;
    const h = "0x" + sha(JSON.stringify({ version: "v1", rows, seed: g.gameSeed }));
    if (h.toLowerCase() === g.seedHash.toLowerCase()) v.n++;
  }
}

console.log(`games=${games.length}  usable=${usable}  emptyRowConfig=${emptyCfg}\n`);
for (const v of variants) console.log(`  ${v.label.padEnd(46)} ${String(v.n).padStart(4)}/${usable}  ${(100*v.n/usable).toFixed(1)}%`);
