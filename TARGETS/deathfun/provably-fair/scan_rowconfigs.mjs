// Scan death.fun's on-chain game history for rowConfig values outside the client-side bounds.
//
// Question this answers: is `rowConfig` (client-supplied) actually bounded by the server, or only
// by the client's own UI check (MIN_TILES=2, MAX_TILES=7)? If illegal configs exist on-chain, the
// server does not validate. If none exist, that is *not* proof of validation — only that none has
// been tried. See findings/F04-rowconfig-client-controlled-open.md.
//
//   node scan_rowconfigs.mjs [sampleSize]
//
// Selectors are constants, hardcoded because Node ships sha3-256 (different padding from keccak256)
// and this script deliberately has no dependencies:
//   0x117a5b90 = games(uint256)   [keccak("games(uint256)")[:4]]
//   0x2e0be39a = gameCounter()
// Both were derived and self-checked against the verified keccak used in the Python tooling.
import fs from "node:fs";

const RPC = process.env.DF_RPC ?? "https://api.mainnet.abs.xyz/";
const CONTRACT = "0x27EDd16eE56958fddCBA08947f12C43DDeC2B20C";
const SEL_GAMES = "0x117a5b90";
const SEL_COUNTER = "0x2e0be39a";
const N = Number(process.argv[2] ?? 450);

async function batch(calls) {
  const body = JSON.stringify(calls.map((c, i) => ({ jsonrpc: "2.0", id: i, method: c.m, params: c.p })));
  const res = await fetch(RPC, { method: "POST", headers: { "Content-Type": "application/json" }, body });
  const json = await res.json();
  const out = {};
  for (const r of json) out[r.id] = r.result;
  return out;
}
const call = (data) => ({ m: "eth_call", p: [{ to: CONTRACT, data }, "latest"] });

function decStr(h, byteOff) {
  const off = byteOff * 2;
  const len = parseInt(h.slice(off, off + 64), 16);
  return Buffer.from(h.slice(off + 64, off + 64 + len * 2), "hex").toString("utf8");
}

const counter = parseInt((await batch([call(SEL_COUNTER)]))[0], 16);
console.log(`gameCounter (latest gid): ${counter}`);

const step = Math.max(1, Math.floor(counter / N));
const gids = [...new Set([
  1,
  ...Array.from({ length: N }, (_, i) => 1 + i * step).filter((g) => g <= counter),
  ...Array.from({ length: 60 }, (_, i) => counter - 59 + i).filter((g) => g >= 1),
])].sort((a, b) => a - b);
console.log(`sampling ${gids.length} games\n`);

const byLen = new Map();       // len -> Map(value -> count)
const games = new Map();       // gid -> {rc, state}
for (let i = 0; i < gids.length; i += 40) {
  const chunk = gids.slice(i, i + 40);
  const r = await batch(chunk.map((g) => call(SEL_GAMES + g.toString(16).padStart(64, "0"))));
  chunk.forEach((g, j) => {
    const raw = r[j];
    if (!raw || raw.length < 2 + 64 * 10) return;
    const h = raw.slice(2);
    try {
      const cfgOff = parseInt(h.slice(8 * 64, 9 * 64), 16);
      const stOff = parseInt(h.slice(9 * 64, 10 * 64), 16);
      const rc = JSON.parse(decStr(h, cfgOff)).rowConfig;
      const state = decStr(h, stOff);
      if (!Array.isArray(rc)) return;
      games.set(g, { rc, state });
      if (!byLen.has(rc.length)) byLen.set(rc.length, new Map());
      const m = byLen.get(rc.length);
      for (const v of rc) m.set(v, (m.get(v) ?? 0) + 1);
    } catch { /* not rowConfig-shaped */ }
  });
  process.stderr.write(`  ...${Math.min(i + 40, gids.length)}/${gids.length}\r`);
}
process.stderr.write("\n");

console.log("tile values grouped by rowConfig length:");
for (const L of [...byLen.keys()].sort((a, b) => a - b)) {
  const m = byLen.get(L);
  const vals = Object.fromEntries([...m.entries()].sort((a, b) => a[0] - b[0]));
  const oob = Object.fromEntries(Object.entries(vals).filter(([v]) => Number(v) < 2 || Number(v) > 7));
  const nGames = Math.round([...m.values()].reduce((a, b) => a + b, 0) / L);
  console.log(`  len=${String(L).padEnd(3)} ~${String(nGames).padEnd(4)} games  values=${JSON.stringify(vals)}`);
  console.log(`        out-of-[2,7]: ${Object.keys(oob).length ? JSON.stringify(oob) : "NONE"}`);
}

const bad25 = [...games.entries()].filter(([, { rc }]) => rc.length === 25 && rc.some((v) => v < 2 || v > 7));
console.log(`\n*** out-of-range tile inside a 25-row (death_race) config: ${bad25.length}`);
for (const [g, { rc, state }] of bad25.slice(0, 8)) console.log(`  gid=${g} rc=${JSON.stringify(rc)} state=${state.slice(0, 90)}`);

const zero = [...games.entries()].filter(([, { rc }]) => rc.includes(0));
console.log(`*** tile value exactly 0 anywhere: ${zero.length}`);
for (const [g, { rc }] of zero.slice(0, 5)) console.log(`  gid=${g} rc=${JSON.stringify(rc)}`);

const outFile = new URL("./rowconfig-scan-results.json", import.meta.url).pathname;
fs.writeFileSync(outFile, JSON.stringify({ counter, sampled: games.size, counts: [...games].map(([g, v]) => ({ gid: g, ...v })) }, null, 0));
console.log(`\nwrote ${outFile}`);
