/**
 * Search a capture.jsonl for anything that looks like evidence a server signature was
 * handed to the client — or that the client ever held raw calldata it could submit.
 *
 * The falsification rule this implements (pre-committed, see README):
 *   any 65-byte ECDSA-shaped blob in a RESPONSE  -> finding is LIVE, F01 retraction wrong
 *   any known death.fun function selector in a RESPONSE -> finding is LIVE
 *   a response field named sig/signature/calldata/note -> finding is LIVE
 *   nothing across a full game lifecycle -> replay path is NOT player-reachable
 *
 * Usage: node analyze.js --in /tmp/df-capture
 */

import fs from "node:fs";
import path from "node:path";

const args = process.argv.slice(2);
const opt = (n, d) => { const i = args.indexOf(n); return i >= 0 && args[i + 1] ? args[i + 1] : d; };
const IN = opt("--in", "/tmp/df-capture");

const file = path.join(IN, "capture.jsonl");
if (!fs.existsSync(file)) { console.error(`no capture at ${file}`); process.exit(2); }

const lines = fs.readFileSync(file, "utf8").split("\n").filter(Boolean).map((l) => {
  try { return JSON.parse(l); } catch { return null; }
}).filter(Boolean);

console.log(`capture: ${file}`);
console.log(`entries: ${lines.length}`);

const byKind = {};
for (const l of lines) byKind[l.kind] = (byKind[l.kind] || 0) + 1;
console.log("kinds:", JSON.stringify(byKind));

// --- signatures of interest
const SELECTORS = {
  "0x0b669290": "increaseBet(uint256,uint256,uint256,bytes)",
  "0x001308d8": "createGame(string,bytes32,string,string,uint256,bytes)",
  "0x7bfe7a43": "cashOutPrefix()",
  "0x3893c500": "createGamePrefix()",
  "0x8da5cb5b": "owner()",
};
const CONTRACT = "0x27edd16ee56958fddcba08947f12c43ddec2b20c";
const OWN_RPC = "api.mainnet.abs.xyz"; // our own eth_call reads — never app-origin data
const SIG65 = /0x[a-fA-F0-9]{130}\b/g;             // 65-byte ECDSA signature
const HEXBLOB = /0x[a-fA-F0-9]{200,}/g;            // calldata-ish

// Field names that would indicate the backend hands the client a signature.
// Deliberately NOT including "note": that is this capture format's own key, so matching it
// produced a false "FINDING IS LIVE" verdict on the first run. A detector that fires on its
// own log schema is worse than no detector.
const FIELDNAMES = /"(sig|signature|serverSignature|calldata|signedPayload|payoutSignature)"\s*:/gi;

/**
 * F03 pre-reveal check: does an ACTIVE game's payload carry the seed or the death tiles?
 *
 * Unlike the signature check, these field names are LEGITIMATE for a finished game (the seed is
 * revealed at settlement by design). So presence alone is not a finding — the test is
 * co-occurrence: an in-progress status in the same payload as a populated seed or a non-null
 * deathTileIndex.
 *
 * This matters because a plaintext seed is NOT 65 bytes of hex and contains no function
 * selector, so the generic patterns above would sail straight past it.
 */
const ACTIVE_STATUS = /"status"\s*:\s*"(active|in_?progress|playing|started|selecting|live)"/i;
const POPULATED_SEED = /"(gameSeed|seed)"\s*:\s*"(0x[0-9a-fA-F]{16,}|[0-9a-fA-F]{16,})"/i;
const POPULATED_DEATHTILE = /"deathTileIndex"\s*:\s*(?!null)\d+/i;
const ROWS_WITH_DEATH = /"rows"\s*:\s*\[[^\]]*"deathTileIndex"\s*:\s*(?!null)\d+/i;

function preRevealCheck(text, origin, seq, out) {
  const active = ACTIVE_STATUS.test(text);
  const seed = POPULATED_SEED.test(text);
  const dti = POPULATED_DEATHTILE.test(text) || ROWS_WITH_DEATH.test(text);
  if (active && (seed || dti)) {
    out.push({ url: origin, seq, activeStatus: true, populatedSeed: seed, populatedDeathTile: dti });
  }
  return { active, seed, dti };
}

/**
 * Extract ONLY what the app actually delivered to the client.
 * - `res`     -> the response body
 * - `ws-in`   -> the websocket frame payload (stored in `note`)
 * Everything else (our own wrapper fields, our own RPC reads) is excluded by construction.
 */
function incomingText(l) {
  if (l.kind === "res") return { text: String(l.body ?? ""), origin: l.url || "" };
  if (l.kind === "ws-in") return { text: String(l.note ?? ""), origin: l.url || "ws" };
  return null;
}

const findings = { sig65: [], selectors: [], fieldnames: [], bigHex: [], ownRpcNoise: [], preReveal: [] };

for (const l of lines) {
  const inc = incomingText(l);
  if (!inc) continue;
  const { text, origin } = inc;
  if (!text) continue;

  const isOwnRpc = origin.includes(OWN_RPC);
  const bucket = (arr, item) => (isOwnRpc ? findings.ownRpcNoise.push(item) : arr.push(item));

  for (const m of text.match(SIG65) || []) bucket(findings.sig65, { url: origin, seq: l.seq, value: m });
  for (const s of Object.keys(SELECTORS)) {
    if (text.includes(s)) bucket(findings.selectors, { url: origin, seq: l.seq, selector: s, fn: SELECTORS[s] });
  }
  for (const m of text.match(FIELDNAMES) || []) bucket(findings.fieldnames, { url: origin, seq: l.seq, field: m });
  for (const m of text.match(HEXBLOB) || []) bucket(findings.bigHex, { url: origin, seq: l.seq, len: m.length, head: m.slice(0, 90) });
  if (!isOwnRpc && l.kind === "res") preRevealCheck(text, origin, l.seq, findings.preReveal);
}

// --- the API responses we care about
console.log("\n=== death.fun API traffic seen ===");
const api = lines.filter((l) => l.url && /death\.fun\/api\//.test(l.url));
const seen = new Map();
for (const l of api) {
  const k = `${l.method || "?"} ${new URL(l.url).pathname}`;
  seen.set(k, (seen.get(k) || 0) + 1);
}
for (const [k, n] of [...seen.entries()].sort()) console.log(`  ${String(n).padStart(4)}x  ${k}`);
if (!seen.size) console.log("  (none — login/play may not have reached the API layer)");

// --- verdict
console.log("\n=== search results ===");
const report = (label, arr, show) => {
  console.log(`  ${label}: ${arr.length}`);
  for (const a of arr.slice(0, 25)) console.log(`      ${show(a)}`);
};
report("65-byte signature-shaped values in incoming data", findings.sig65,
  (a) => `seq ${a.seq} ${a.url} :: ${a.value.slice(0, 80)}`);
report("death.fun function selectors in incoming data", findings.selectors,
  (a) => `seq ${a.seq} ${a.url} :: ${a.selector} (${a.fn})`);
report("signature-shaped field names", findings.fieldnames,
  (a) => `seq ${a.seq} ${a.url} :: ${a.field}`);
report("large hex blobs (possible calldata)", findings.bigHex,
  (a) => `seq ${a.seq} ${a.url} :: ${a.len} chars ${a.head}`);
console.log(`  own-RPC noise excluded (our own eth_call reads): ${findings.ownRpcNoise.length}`);

// F03 pre-reveal
console.log(`\n=== F03 PRE-REVEAL CHECK (active game + seed/deathTile in the same payload) ===`);
console.log(`  hits: ${findings.preReveal.length}`);
for (const a of findings.preReveal.slice(0, 15)) {
  console.log(`      seq ${a.seq} ${a.url} :: seed=${a.populatedSeed} deathTile=${a.populatedDeathTile}`);
}
if (!findings.preReveal.length) {
  console.log("  No active-game payload carried a populated seed or deathTileIndex.");
  console.log("  (A populated seed on a FINISHED game is expected and is not flagged.)");
}

const LIVE = findings.sig65.length > 0 || findings.selectors.length > 0 || findings.fieldnames.length > 0;
const PRE_REVEAL = findings.preReveal.length > 0;
const me = lines.filter((l) => l.kind === "wallet-sign");
console.log(`\n=== wallet signing requests the CLIENT asked us to sign ===`);
console.log(`  count: ${me.length}   (these are signatures the client needed, i.e. what it expects to hold)`);
for (const w of me.slice(0, 15)) {
  let d = {};
  try { d = JSON.parse(w.note); } catch {}
  console.log(`    seq ${w.seq}  ${d.what ?? "?"}  ${String(d.message ?? d.typedData ?? "").slice(0, 120)}`);
}

console.log("\n=== VERDICT ===");
if (PRE_REVEAL) {
  console.log("  *** F03 PRE-REVEAL CONFIRMED ***");
  console.log("  An active game's payload carried the seed and/or the death tiles. The player can");
  console.log("  read the skull before picking -> Critical. Capture the exact response and report.");
} else if (LIVE) {
  console.log("  *** FINDING IS LIVE ***");
  console.log("  A server signature or raw calldata reached the client. F01's retraction was wrong;");
  console.log("  the replay path IS reachable by a player. Escalate to Critical and re-issue.");
} else {
  console.log("  F01: no server signature and no function selector reached the client.");
  console.log("  F03: no active-game payload carried a seed or death tiles.");
  console.log(`  Both conclusions hold for every ${api.length} API interactions observed.`);
  console.log("  Remaining uncertainty = the closed-source server, which this test cannot see.");
}
fs.writeFileSync(path.join(IN, "analysis.json"), JSON.stringify({
  entries: lines.length, kinds: byKind, apiPaths: [...seen.entries()], findings,
  clientSignatureRequests: me.length,
  verdict: PRE_REVEAL ? "PRE_REVEAL" : (LIVE ? "LIVE" : "not-player-reachable"),
}, null, 2));
console.log(`\nwritten: ${path.join(IN, "analysis.json")}`);
