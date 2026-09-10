/**
 * Step 3: validate the commitment scheme, then test seed predictability.
 *
 * Scheme (from the official verifier, shared.js generateGameHash + deathFun.js):
 *   rows[i].deathTileIndex = parseInt(sha256(`${seed}-row${i}`).slice(0,8), 16) % tiles_i
 *   rows[i].multiplier     = cumulative( tiles/(tiles-1) ) * 0.95
 *   gameSeedHash           = "0x" + sha256(JSON.stringify({version, rows, seed}))
 *
 * If that reproduces the on-chain hash, the scheme is confirmed: the entire board is a
 * deterministic function of the seed alone. Then the only question is seed secrecy.
 */
const crypto = require("crypto");
const fs = require("fs");

const sha256Hex = (s) => crypto.createHash("sha256").update(Buffer.from(s, "utf8")).digest("hex");

function deathTileIndex(seed, rowIndex, totalTiles) {
  const h = sha256Hex(`${seed}-row${rowIndex}`);
  return parseInt(h.slice(0, 8), 16) % totalTiles;
}
function rowMultipliers(tileCounts) {
  const mult = [];
  let cur = 1;
  const HOUSE_EDGE = 0.05;
  for (const tiles of tileCounts) {
    cur *= 1 / (1 - 1 / tiles);
    mult.push(cur * (1 - HOUSE_EDGE));
  }
  return mult;
}
function reconstructRows(tileCounts, seed) {
  const mult = rowMultipliers(tileCounts);
  const rows = [];
  for (let i = 0; i < tileCounts.length; i++) {
    rows.push({ tiles: tileCounts[i], deathTileIndex: deathTileIndex(seed, i, tileCounts[i]), multiplier: mult[i] });
  }
  return rows;
}
function commit(version, tileCounts, seed) {
  const rows = reconstructRows(tileCounts, seed);
  const gameData = JSON.stringify({ version, rows, seed });
  return { hash: "0x" + sha256Hex(gameData), json: gameData };
}

const games = JSON.parse(fs.readFileSync("/tmp/settled_games.json", "utf8"));
console.log(`testing commitment against ${games.length} settled games\n`);

let ok = 0, bad = 0;
const examples = [];
for (const g of games) {
  let cfg;
  try { cfg = JSON.parse(g.gameConfig); } catch { continue; }
  const counts = cfg.rowConfig;
  if (!Array.isArray(counts)) continue;
  const { hash, json } = commit(g.algoVersion || "v1", counts, g.gameSeed);
  if (hash.toLowerCase() === g.seedHash.toLowerCase()) { ok++; if (examples.length < 2) examples.push({ g, json, hash }); }
  else bad++;
}
console.log(`=== COMMITMENT VALIDATION ===`);
console.log(`  reproduced on-chain gameSeedHash : ${ok}`);
console.log(`  did not reproduce                : ${bad}`);
if (ok > 0) {
  console.log(`\n  ✅ SCHEME CONFIRMED — the whole board is a deterministic function of the seed.`);
  const e = examples[0];
  console.log(`\n  example (game ${e.g.gid}):`);
  console.log(`    seed: ${e.g.gameSeed}`);
  console.log(`    json: ${e.json.slice(0, 300)}${e.json.length > 300 ? "…" : ""}`);
  console.log(`    computed: ${e.hash}`);
  console.log(`    on-chain: ${e.g.seedHash}`);
}

// ---- seed predictability: is seed_n a hash of anything public we already know?
console.log(`\n=== SEED PREDICTABILITY TESTS ===`);
const byId = [...games].sort((a, b) => a.gid - b.gid);
const H = {
  sha256: (s) => sha256Hex(s),
  sha256_0x: (s) => "0x" + sha256Hex(s),
  sha256_hexdigest_bytes: (s) => sha256Hex(s),
  keccak: (s) => "0x" + crypto.createHash("sha3-256").update(s).digest("hex"),
};
const hits = {};
const tryHit = (label, computed, seed) => {
  if (computed.toLowerCase() === seed.toLowerCase()) hits[label] = (hits[label] || 0) + 1;
};

for (let i = 0; i < byId.length; i++) {
  const g = byId[i];
  const seed = g.gameSeed;
  const S = String(g.gid), P = g.player, T = String(g.createdAt), B = String(g.betAmount);
  for (const [hn, hf] of Object.entries(H)) {
    tryHit(`${hn}(gid)`, hf(S), seed);
    tryHit(`${hn}(gid+player)`, hf(S + P), seed);
    tryHit(`${hn}(player+gid)`, hf(P + S), seed);
    tryHit(`${hn}(createdAt)`, hf(T), seed);
    tryHit(`${hn}(gid,createdAt)`, hf(S + T), seed);
    tryHit(`${hn}(player,createdAt)`, hf(P + T), seed);
    tryHit(`${hn}(player)`, hf(P), seed);
    tryHit(`${hn}(betAmount)`, hf(B), seed);
    if (i > 0) {
      const prev = byId[i - 1].gameSeed;
      tryHit(`${hn}(prevSeed)`, hf(prev), seed);
      tryHit(`${hn}(prevSeedRaw)`, hf(prev.replace(/^0x/, "")), seed);
      tryHit(`${hn}(gid+prevSeed)`, hf(S + prev), seed);
      tryHit(`${hn}(prevSeed+gid)`, hf(prev + S), seed);
    }
  }
}
console.log(`  games tested: ${byId.length}`);
if (Object.keys(hits).length) {
  console.log("  *** PREDICTABLE SEED FOUND ***");
  for (const [k, v] of Object.entries(hits)) console.log(`     ${k}: ${v} matches`);
} else {
  console.log("  no seed derived from gid/player/time/betAmount/previous-seed under these hash fns");
}

// ---- does the seed look like raw hex entropy, or like a hash with structure?
console.log(`\n=== SEED SHAPE ===`);
const lens = new Set(byId.map((g) => g.gameSeed.length));
console.log(`  lengths observed: ${[...lens].join(", ")} (66 chars = "0x" + 32 bytes)`);
const firstBytes = byId.slice(0, 8).map((g) => g.gameSeed.slice(2, 10));
console.log(`  first 4 bytes of first 8 seeds: ${firstBytes.join(" ")}`);
const allSame = new Set(byId.map((g) => g.gameSeed)).size !== byId.length;
console.log(`  any duplicated seeds: ${allSame}`);
