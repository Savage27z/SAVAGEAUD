// F09-b: what does the create-response `hash` commit to?
// Uses the protocol's OWN hashing construction, verbatim from
// provably-fair/upstream-verifier-shared.js:
//     sha256( JSON.stringify({ version, rows: rows || [], seed }) )
// and brute-forces a defined candidate space to see if any payload reproduces
// the create-time hash recorded in F07 §6.
const crypto = require("crypto");
const fs = require("fs");

const CREATE_HASH = "0xbfed306807d95f94f876afe09ffd3a5fb13c3e01135c304aed5945f801326512";
const games = JSON.parse(fs.readFileSync("/tmp/f09a_games.json", "utf8"));
const g = games.find((x) => x.gid === 4839273);

const sha256Hex = (s) => crypto.createHash("sha256").update(s, "utf8").digest("hex");
const H = (o) => "0x" + sha256Hex(JSON.stringify(o));

// --- faithful reconstruction of the verifier's own helpers -------------------
const HOUSE_EDGE = 0.04; // F03/F07: live value is .04 (their published verifier hardcodes .05)
const sha256HexP = (s) => sha256Hex(s);
function deathTileIndex(seed, rowIndex, totalTiles) {
  const hash = sha256HexP(`${seed}-row${rowIndex}`);
  return parseInt(hash.slice(0, 8), 16) % totalTiles;
}
function buildRows(tileCounts, seed, withSkulls) {
  const rows = [];
  let cur = 1;
  for (let i = 0; i < tileCounts.length; i++) {
    const tiles = tileCounts[i];
    cur *= 1 / (1 - 1 / tiles);
    rows.push({
      tiles,
      deathTileIndex: withSkulls ? deathTileIndex(seed, i, tiles) : null,
      multiplier: cur * (1 - HOUSE_EDGE),
    });
  }
  return rows;
}

const cfg = JSON.parse(g.config);
const tileCounts = cfg.rowConfig;
const seed = g.seed;                     // "0x6d67…"
const seedNo0x = seed.replace(/^0x/, "");

console.log(`target gid ${g.gid}`);
console.log(`  config        : ${JSON.stringify(tileCounts).slice(0, 50)}…`);
console.log(`  seed (on-chain): ${seed}`);
console.log(`  create hash    : ${CREATE_HASH}`);
console.log(`  its chain hash : ${g.seedHash}`);
console.log(`  create == chain: ${CREATE_HASH.toLowerCase() === g.seedHash.toLowerCase()}`);
console.log();

// --- candidate space ---------------------------------------------------------
const versionVals = ["v1", "v2", 1, 2];
const rowsVals = {
  "actual rows w/ skulls": buildRows(tileCounts, seed, true),
  "actual rows, skulls=null": buildRows(tileCounts, seed, false),
  "actual rows, deathTileIndex omitted": buildRows(tileCounts, seed, false).map((r) => ({ tiles: r.tiles, multiplier: r.multiplier })),
  "tileCounts as numbers": tileCounts,
  "empty array": [],
};
const seedVals = { "seed=''": "", "seed=null": null, "seed=actual(0x)": seed, "seed=actual(no0x)": seedNo0x };

let tried = 0, hits = [];
for (const v of versionVals) {
  for (const [rn, rows] of Object.entries(rowsVals)) {
    for (const [sn, s] of Object.entries(seedVals)) {
      // exact shape from the verifier
      const obj = { version: v, rows: rows || [], seed: s };
      const h = H(obj);
      tried++;
      if (h.toLowerCase() === CREATE_HASH.toLowerCase()) hits.push({ v, rn, sn, shape: "with-seed-key" });
      // variant with the seed key absent (undefined => JSON.stringify drops it)
      const obj2 = { version: v, rows: rows || [] };
      if (sn.includes("''") || sn.includes("null")) {
        const h2 = H(obj2);
        tried++;
        if (h2.toLowerCase() === CREATE_HASH.toLowerCase()) hits.push({ v, rn, sn, shape: "no-seed-key" });
      }
    }
  }
}
console.log(`candidates tried: ${tried}`);
console.log(`HITS: ${hits.length ? JSON.stringify(hits, null, 1) : "NONE"}`);

// --- also: does the create hash match ANY of the 898 sampled games' seedHash? --
const sample = JSON.parse(fs.readFileSync(
  process.env.HOME + "/.hermes/workspace/SAVAGEAUD/TARGETS/deathfun/provably-fair/settled-games-sample.json", "utf8"));
const m = sample.filter((x) => (x.seedHash || "").toLowerCase() === CREATE_HASH.toLowerCase());
console.log(`\ncreate hash equals a seedHash in the 898-game sample: ${m.length ? JSON.stringify(m.map((x) => x.gid)) : "NONE"}`);

// --- sanity: prove the hasher reproduces a KNOWN on-chain commitment ---------
// gid 4839273 is settled with a revealed seed, so the verifier's construction
// over {version:"v1", rows:<actual>, seed:<seed>} must equal its on-chain seedHash.
const sanity = ["v1", "v2"].map((v) => ({
  v,
  rows: buildRows(tileCounts, seed, true),
}));
for (const s of sanity) {
  const h = H({ version: s.v, rows: s.rows, seed: seed });
  console.log(`SANITY ${s.v} rows-with-skulls vs chain seedHash: ${h.toLowerCase() === g.seedHash.toLowerCase()}  (${h.slice(0, 18)}…)`);
}
