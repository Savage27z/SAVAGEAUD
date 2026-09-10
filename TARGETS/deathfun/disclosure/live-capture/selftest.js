/**
 * Self-test for analyze.js.
 *
 * A detector that never fires is as useless as one that always fires, so this checks BOTH:
 *   negative control — a clean capture must NOT be reported live
 *   positive control — a capture with a planted 65-byte signature MUST be reported live
 *   regression       — the log's own "note" key must NOT trip the field-name detector
 *
 * Usage: node selftest.js
 */
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { execFileSync } from "node:child_process";

const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "df-selftest-"));
const sig = "0x" + "ab".repeat(65);          // a 65-byte ECDSA-shaped blob
const cases = [];

// 1. clean capture: nothing that should fire
cases.push({
  name: "negative control (clean capture)",
  expect: "not-player-reachable",
  lines: [
    { seq: 1, kind: "res", url: "https://death.fun/api/games/active", body: JSON.stringify({ currentGame: { status: "pending_onchain" } }) },
    { seq: 2, kind: "note", note: "a benign log line" },
    { seq: 3, kind: "req", url: "https://death.fun/api/games/create", postData: JSON.stringify({ betAmount: "1000000000000000" }) },
  ],
});

// 2. regression: the capture format's own key names must not fire the detector
cases.push({
  name: "regression (own log keys: note)",
  expect: "not-player-reachable",
  lines: [
    { seq: 1, kind: "res", url: "https://death.fun/api/settings", body: '{"theme":"dark"}' },
    { seq: 2, kind: "note", note: '{"note":"should not trip signature detector"}' },
    { seq: 3, kind: "console", note: "note: hello" },
  ],
});

// 3. positive control: a planted signature must fire
cases.push({
  name: "positive control (planted 65-byte signature)",
  expect: "LIVE",
  lines: [
    { seq: 1, kind: "res", url: "https://death.fun/api/games/create", body: JSON.stringify({ preliminaryGameId: "x", serverSignature: sig }) },
  ],
});

// 4. positive control: a planted function selector must fire
cases.push({
  name: "positive control (planted increaseBet selector)",
  expect: "LIVE",
  lines: [
    { seq: 1, kind: "res", url: "https://death.fun/api/games/1/increase-bet", body: JSON.stringify({ calldata: "0x0b669290deadbeef" }) },
  ],
});

// 5. positive control: a websocket frame carrying a signature must fire
cases.push({
  name: "positive control (signature via websocket frame)",
  expect: "LIVE",
  lines: [
    { seq: 1, kind: "ws-in", url: "wss://death.fun/ws", note: JSON.stringify({ type: "increase_bet", signature: sig }) },
  ],
});

// 6. own-RPC reads must be excluded, not counted as live
cases.push({
  name: "own-RPC exclusion (our eth_call output)",
  expect: "not-player-reachable",
  lines: [
    { seq: 1, kind: "res", url: "https://api.mainnet.abs.xyz/", body: JSON.stringify({ jsonrpc: "2.0", result: "0x" + "cd".repeat(65) }) },
  ],
});

// ---- F03 pre-reveal detector -----------------------------------------------------------
// 7. POSITIVE: active game carrying a populated seed -> the skull is computable
cases.push({
  name: "pre-reveal positive (active game + populated gameSeed)",
  expect: "PRE_REVEAL",
  lines: [
    { seq: 1, kind: "res", url: "https://death.fun/api/games/active", body: JSON.stringify({
      currentGame: { id: "g1", status: "active", currentRowIndex: 0, selectedTiles: [],
                     gameSeed: "0x1ce72fdf7009baf827f108a38f586f4f13269ae9856b1ef387ceed5fc2cf83a0",
                     commitmentHash: "0x4f1220e5" } }) },
  ],
});

// 8. POSITIVE: active game carrying populated death tiles in rows
cases.push({
  name: "pre-reveal positive (active game + populated deathTileIndex)",
  expect: "PRE_REVEAL",
  lines: [
    { seq: 1, kind: "res", url: "https://death.fun/api/games/active", body: JSON.stringify({
      currentGame: { status: "active", rows: [{ tiles: 4, deathTileIndex: 2, multiplier: 1.14 }] } }) },
  ],
});

// 9. NEGATIVE: the SAME seed on a FINISHED game is expected behaviour, must NOT flag
cases.push({
  name: "pre-reveal negative (finished game + seed is legitimate)",
  expect: "not-player-reachable",
  lines: [
    { seq: 1, kind: "res", url: "https://death.fun/api/games/history", body: JSON.stringify({
      games: [{ id: "g1", status: "won", gameSeed: "0x1ce72fdf7009baf827f108a38f586f4f13269ae9856b1ef387ceed5fc2cf83a0",
                rows: [{ tiles: 4, deathTileIndex: 2, multiplier: 1.14 }] }] }) },
  ],
});

// 10. NEGATIVE: active game with deathTileIndex explicitly null (the intended design)
cases.push({
  name: "pre-reveal negative (active game, deathTileIndex nulled)",
  expect: "not-player-reachable",
  lines: [
    { seq: 1, kind: "res", url: "https://death.fun/api/games/active", body: JSON.stringify({
      currentGame: { status: "active", gameSeed: null, currentRowIndex: 1,
                     rows: [{ tiles: 4, deathTileIndex: null, multiplier: 1.14 },
                            { tiles: 2, deathTileIndex: null, multiplier: 2.28 }] } }) },
  ],
});

let pass = 0, fail = 0;
for (const c of cases) {
  const dir = path.join(tmp, c.name.replace(/[^a-z0-9]+/gi, "_"));
  fs.mkdirSync(dir, { recursive: true });
  fs.writeFileSync(path.join(dir, "capture.jsonl"), c.lines.map((l) => JSON.stringify(l)).join("\n") + "\n");
  execFileSync(process.execPath, ["analyze.js", "--in", dir], { cwd: path.dirname(new URL(import.meta.url).pathname), stdio: "pipe" });
  const res = JSON.parse(fs.readFileSync(path.join(dir, "analysis.json"), "utf8"));
  const ok = res.verdict === c.expect;
  console.log(`${ok ? "PASS" : "FAIL"}  ${c.name}\n       expected ${c.expect}, got ${res.verdict}`);
  ok ? pass++ : fail++;
}
console.log(`\n${pass} passed, ${fail} failed`);
fs.rmSync(tmp, { recursive: true, force: true });
process.exit(fail ? 1 : 0);
