// F09-c: second round on the create-response `hash`.
// F09-b covered one key order (version, rows, seed) x row shapes x seed values.
// JSON.stringify PRESERVES insertion order, so a different top-level key order
// yields a different hash. Test all 6 permutations, extra keys, row shapes
// without `multiplier`, version encodings, and non-JSON string constructions.
const crypto = require("crypto");
const fs = require("fs");
const CREATE_HASH = "0xbfed306807d95f94f876afe09ffd3a5fb13c3e01135c304aed5945f801326512";
const games = JSON.parse(fs.readFileSync("/tmp/f09a_games.json", "utf8"));
const g = games.find((x) => x.gid === 4839273);
const sha256Hex = (s) => crypto.createHash("sha256").update(s, "utf8").digest("hex");
const keccak = (s) => "0x" + crypto.createHash("sha3-256").update(s, "utf8").digest("hex"); // note: NOT real keccak; label it
const H = (o) => "0x" + sha256Hex(JSON.stringify(o));
const Hk = (o) => keccak(JSON.stringify(o));

const cfg = JSON.parse(g.config);
const tileCounts = cfg.rowConfig;
const seed = g.seed;
function dti(seed, i, tiles) { return parseInt(sha256Hex(`${seed}-row${i}`).slice(0, 8), 16) % tiles; }
function rows(withSkulls, withMult = true) {
  const out = []; let cur = 1;
  for (let i = 0; i < tileCounts.length; i++) {
    const t = tileCounts[i]; cur *= 1 / (1 - 1 / t);
    const r = { tiles: t, deathTileIndex: withSkulls ? dti(seed, i, t) : null };
    if (withMult) r.multiplier = cur * 0.96;
    out.push(r);
  }
  return out;
}

const variants = [];
const rowSets = {
  "skulls+mult": rows(true, true),
  "skulls, no mult": rows(true, false),
  "null skulls+mult": rows(false, true),
  "tileCounts only": tileCounts,
  "empty": [],
};
const seedVals = { s0: "", sx: seed, sn: seed.replace(/^0x/, ""), snull: null };
const versVals = { v1: "v1", v2: "v2", n1: 1, none: undefined };

// all 6 key orders + extra-key shapes
const orders = [
  ["version", "rows", "seed"], ["version", "seed", "rows"], ["rows", "version", "seed"],
  ["rows", "seed", "version"], ["seed", "version", "rows"], ["seed", "rows", "version"],
];
let tried = 0, hits = [];
for (const [rn, rv] of Object.entries(rowSets)) {
  for (const [sn, sv] of Object.entries(seedVals)) {
    for (const [vn, vv] of Object.entries(versVals)) {
      for (const ord of orders) {
        const src = { version: vv, rows: rv, seed: sv };
        const obj = {};
        for (const k of ord) obj[k] = src[k];
        tried++;
        const h = H(obj);
        if (h.toLowerCase() === CREATE_HASH.toLowerCase()) hits.push({ kind: "sha256", ord, rn, sn, vn });
      }
    }
  }
}
// row object key orders (tiles/deathTileIndex/multiplier) — 6 perms on the first row shape
const rowOrders = [
  ["tiles", "deathTileIndex", "multiplier"], ["tiles", "multiplier", "deathTileIndex"],
  ["deathTileIndex", "tiles", "multiplier"], ["multiplier", "tiles", "deathTileIndex"],
];
for (const ro of rowOrders) {
  const rv = rows(true, true).map((r) => { const o = {}; for (const k of ro) o[k] = r[k]; return o; });
  tried++;
  const h = H({ version: "v1", rows: rv, seed: seed });
  if (h.toLowerCase() === CREATE_HASH.toLowerCase()) hits.push({ kind: "sha256-rowkeyorder", ro });
}
// non-JSON string constructions
const strings = {
  "seed+config+algo": seed + g.config + g.algo,
  "uuid": "1a06e1a5-6583-4737-b681-53c961ba3769",
  "uuid+seed": "1a06e1a5-6583-4737-b681-53c961ba3769" + seed,
};
for (const [k, s] of Object.entries(strings)) {
  tried++;
  if (("0x" + sha256Hex(s)).toLowerCase() === CREATE_HASH.toLowerCase()) hits.push({ kind: "sha256-string", k });
}
console.log(`F09-c candidates tried: ${tried}`);
console.log(`HITS: ${hits.length ? JSON.stringify(hits, null, 1) : "NONE"}`);
console.log(`\n(For reference, a passing sanity control from F09-b: the protocol's own`);
console.log(` construction over {version:"v1", rows:<actual,skulls+mult>, seed:<seed>} DOES`);
console.log(` reproduce the on-chain gameSeedHash — so the hasher here is correct.)`);
