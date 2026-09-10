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
