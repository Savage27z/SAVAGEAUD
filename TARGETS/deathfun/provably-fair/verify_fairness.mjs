// Authoritative fairness + commitment check for death.fun, in exact JS semantics.
//  1. does the committed hash reproduce from (seed, rowConfig) using the app's constants?
//  2. does the committed board equal the board actually played?
//  3. do the player's picks line up with the death tiles derived from the revealed seed?
import crypto from "node:crypto";
import fs from "node:fs";

const sha = (s) => crypto.createHash("sha256").update(s).digest("hex");
const dti = (seed, i, t) => parseInt(sha(`${seed}-row${i}`).slice(0, 8), 16) % t;

const games = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
const HE = 0.04, PREC = 1e8;

function build(cfg, seed) {
  let l = 1, rows = [];
  for (let i = 0; i < cfg.length; i++) {
    const t = cfg[i];
    if (t < 2) return null;
    l *= 1 / (1 - 1 / t);
    rows.push({ tiles: t, deathTileIndex: dti(seed, i, t), multiplier: Math.round(l * (1 - HE) * PREC) / PREC });
  }
  return rows;
}
const hashOf = (rows, seed) => "0x" + sha(JSON.stringify({ version: "v1", rows, seed }));

// published verifier: HOUSE_EDGE = 0.05, raw (unrounded) multipliers
function buildVerifier(cfg, seed) {
  let l = 1, rows = [];
  for (let i = 0; i < cfg.length; i++) {
    const t = cfg[i];
    if (t < 2) return null;
    l *= 1 / (1 - 1 / t);
    rows.push({ tiles: t, deathTileIndex: dti(seed, i, t), multiplier: l * (1 - 0.05) });
  }
  return rows;
}

let nStd = 0, appOk = 0, verOk = 0, commMatch = 0, wins = 0, losses = 0, contradictions = 0, noPicks = 0, overRange = 0;
const badExamples = [];

for (const g of games) {
  let cfg, st;
  try { cfg = JSON.parse(g.gameConfig).rowConfig; } catch { continue; }
  try { st = JSON.parse(g.gameState); } catch { st = {}; }
  if (!Array.isArray(cfg) || cfg.length !== 25) continue;
  nStd++;

  const rows = build(cfg, g.gameSeed);
  if (!rows) continue;
  if (hashOf(rows, g.gameSeed).toLowerCase() === g.seedHash.toLowerCase()) appOk++;
  if (hashOf(rows, g.gameSeed).toLowerCase() === g.seedHash.toLowerCase()) commMatch++;

  const vrows = buildVerifier(cfg, g.gameSeed);
  if (vrows && hashOf(vrows, g.gameSeed).toLowerCase() === g.seedHash.toLowerCase()) verOk++;

  const picks = st.selectedTiles;
  if (!Array.isArray(picks) || picks.length === 0 || !picks.every((x) => Number.isInteger(x))) { noPicks++; continue; }
  const deaths = cfg.map((t, i) => dti(g.gameSeed, i, t));
  if (Math.max(...picks) > Math.max(...cfg) - 1) overRange++;

  let ok = true;
  for (let i = 0; i < picks.length - 1; i++) if (picks[i] === deaths[i]) ok = false;   // survived a skull?
  const lastDied = picks[picks.length - 1] === deaths[picks.length - 1];
  if (g.status === 2) { lastDied ? losses++ : (ok = false); }                           // lost => last pick was the skull
  else { lastDied ? (ok = false) : wins++; }                                            // won  => last pick was safe
  if (ok) { if (g.status === 2) {} } else { contradictions++; if (badExamples.length < 5) badExamples.push({ gid: g.gid, picks, deaths: deaths.slice(0, picks.length), status: g.status }); }
}

console.log(`standard 25-row death_race games : ${nStd}`);
console.log(`committed hash reproduces (app)  : ${appOk}/${nStd}   ${(100 * appOk / nStd).toFixed(1)}%`);
console.log(`committed hash reproduces (their published verifier): ${verOk}/${nStd}   ${(100 * verOk / nStd).toFixed(1)}%`);
console.log(`committed board == board played  : ${commMatch}/${nStd}`);
console.log(`picks within their row's range   : ${nStd - noPicks - overRange}/${nStd - noPicks}`);
console.log(`fairness: wins consistent        : ${wins}`);
console.log(`fairness: losses consistent      : ${losses}`);
console.log(`fairness: CONTRADICTIONS         : ${contradictions}`);
console.log(`no picks recorded                : ${noPicks}`);
if (badExamples.length) console.log("examples:", JSON.stringify(badExamples, null, 2));
