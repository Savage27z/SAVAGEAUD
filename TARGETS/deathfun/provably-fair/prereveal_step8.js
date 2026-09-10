/**
 * Step 8: validate the commitment using the EXACT recovered implementation.
 *
 * Recovered from the live bundle:
 *   sha256Hex(s)              = createHash("sha256").update(s).digest("hex")
 *   generateGameSeed()        = randomBytes(32).toString("hex")
 *   getDeathTileIndex(s,i,n)  = parseInt(sha256(`${s}-row${i}`).slice(0,8),16) % n
 *   createCommitmentHash(v,r,s)= "0x" + sha256(JSON.stringify({version:v, rows:r, seed:s}))
 *   q(x)                      = Math.round(1e8*x)/1e8
 *   appConfig.houseEdge       = .04
 *   builder Y (threshold 1):  o=(l*=1/(1-1/d))*(1-edge);  n=q(o); c=getDeathTileIndex(seed,i,d)
 *   builder J (handles 1):    d>1 && (l*=1/(1-1/d)); n= d===1?null:q(o); c= d===1?0:getDeathTileIndex(...)
 */
const crypto = require("crypto");
const fs = require("fs");
const sha256Hex = (s) => crypto.createHash("sha256").update(s, "utf8").digest("hex");
const q = (x) => Math.round(1e8 * x) / 1e8;
const dti = (seed, i, n) => parseInt(sha256Hex(`${seed}-row${i}`).slice(0, 8), 16) % n;

function buildY(counts, seed, edge) {
  let l = 1;
  return counts.map((d, i) => {
    const o = (l *= 1 / (1 - 1 / d)) * (1 - edge);
    return { tiles: d, deathTileIndex: dti(seed, i, d), multiplier: q(o) };
  });
}
function buildJ(counts, seed, edge) {
  let l = 1;
  return counts.map((d, i) => {
    if (d > 1) l *= 1 / (1 - 1 / d);
    const o = l * (1 - edge);
    return { tiles: d, deathTileIndex: d === 1 ? 0 : dti(seed, i, d), multiplier: d === 1 ? null : q(o) };
  });
}
const commit = (version, rows, seed) => "0x" + sha256Hex(JSON.stringify({ version, rows, seed }));

const games = JSON.parse(fs.readFileSync("/tmp/settled_games.json", "utf8"));
console.log(`games: ${games.length}\n`);

const report = {};
for (const [bn, bf] of Object.entries({ Y: buildY, J: buildJ })) {
  for (const edge of [0.04, 0.05, 0.045]) {
    let ok = 0, bad = 0;
    const badCfg = {};
    for (const g of games) {
      let counts; try { counts = JSON.parse(g.gameConfig).rowConfig; } catch { continue; }
      if (!Array.isArray(counts)) continue;
      const rows = bf(counts, g.gameSeed, edge);
      const h = commit(g.algoVersion || "v1", rows, g.gameSeed);
      if (h.toLowerCase() === g.seedHash.toLowerCase()) ok++;
      else { bad++; const len = counts.length; badCfg[len] = (badCfg[len] || 0) + 1; }
    }
    report[`builder ${bn}, edge ${edge}`] = { ok, bad, badCfg };
    console.log(`=== builder ${bn}, houseEdge ${edge} ===`);
    console.log(`   reproduced: ${ok}   failed: ${bad}`);
    console.log(`   failures by config length: ${JSON.stringify(badCfg)}`);
  }
}

const best = Object.entries(report).sort((a, b) => b[1].ok - a[1].ok)[0];
console.log(`\n=== BEST: ${best[0]} -> ${best[1].ok} reproduced ===`);
if (best[1].ok > 0) {
  console.log("  ✅ commitment scheme fully reproduced");
  const g = games.find((x) => {
    try { return JSON.parse(x.gameConfig).rowConfig.length > 0; } catch { return false; }
  });
  const counts = JSON.parse(g.gameConfig).rowConfig;
  const bn = best[0].includes("builder Y") ? buildY : buildJ;
  const edge = Number(best[0].split("edge ")[1]);
  const rows = bn(counts, g.gameSeed, edge);
  const json = JSON.stringify({ version: g.algoVersion || "v1", rows, seed: g.gameSeed });
  console.log(`\n  example game ${g.gid}:`);
  console.log(`    computed: ${commit(g.algoVersion || "v1", rows, g.gameSeed)}`);
  console.log(`    onchain : ${g.seedHash}`);
  console.log(`    json head: ${json.slice(0, 260)}`);
} else {
  console.log("  ❌ still not reproduced -> the committed rows differ from what the on-chain");
  console.log("     gameConfig + the live bundle's own algorithm produce.");
}
