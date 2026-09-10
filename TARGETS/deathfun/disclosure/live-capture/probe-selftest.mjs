/**
 * Offline test of console-probe.js: does it correctly call the pre-reveal in both directions?
 *
 * Fixtures 1 and 2 are the REAL payloads captured live from death.fun on 2026-09-10.
 * Fixtures 3 and 4 are synthetic leaks — they exist to prove the probe is not merely
 * agreeing with us, i.e. that it WOULD fire if a future row's skull were revealed.
 */
import fs from "node:fs";
import { fileURLToPath } from "node:url";
import path from "node:path";

const here = path.dirname(fileURLToPath(import.meta.url));
const PROBE = path.join(here, "console-probe.js");
const src = fs.readFileSync(PROBE, "utf8");

function runCase(label, payloads, expected) {
  const lines = [];
  const win = {
    fetch: async (url) => ({ clone: () => ({ text: async () => payloads[url] ?? "" }) }),
    XMLHttpRequest: function () {},
  };
  win.XMLHttpRequest.prototype = { open() {}, send() {}, addEventListener() {} };
  win.console = { log: (...a) => lines.push(a.map(String).join(" ")) };

  // run the snippet verbatim — it is a self-contained IIFE that only needs window + console
  new Function("window", "console", src)(win, win.console);

  return (async () => {
    for (const url of Object.keys(payloads)) { try { await win.fetch(url); } catch {} }
    await new Promise((r) => setTimeout(r, 30));
    const verdict = win.__df_dump();
    const ok = verdict === expected;
    console.log(`${ok ? "PASS" : "FAIL"}  ${label}\n       expected ${expected}, got ${verdict}`);
    return ok;
  })();
}

// ---- fixture 1: REAL polled active game (captured live) ----
const realActivePoll = JSON.stringify({
  currentGame: {
    id: "145794c1-e83e-4258-a8d9-b5ea184f2f08",
    walletAddress: "0x318f5353bab917b5243d78825875a247c90c8646",
    status: "active",
    betAmount: "1000000000000000",
    rows: [
      { tiles: 7, multiplier: 1.12, deathTileIndex: null },
      { tiles: 3, multiplier: 1.68, deathTileIndex: null },
      { tiles: 3, multiplier: 2.52, deathTileIndex: null },
    ],
  },
});

// ---- fixture 2: REAL select-tile response (captured live) ----
const realSelectTile = JSON.stringify({
  isDeathTile: false, currentRowIndex: 1, finalMultiplier: 1.12, status: "active",
  currentRow: { tiles: 7, multiplier: 1.12, deathTileIndex: 5 },   // the row just played
  nextRow: { tiles: 3, multiplier: 1.68, deathTileIndex: null },   // the row not yet played
  version: 2, animationTag: null,
});

// ---- fixture 3: SYNTHETIC leak — next (unplayed) row's skull sent ----
const leakNextRow = JSON.stringify({
  isDeathTile: false, currentRowIndex: 1, status: "active",
  currentRow: { tiles: 7, deathTileIndex: 5 },
  nextRow: { tiles: 3, deathTileIndex: 2 },                        // <-- leak
});

// ---- fixture 4: SYNTHETIC leak — whole board + seed on a live game ----
const leakWholeBoard = JSON.stringify({
  currentGame: {
    id: "g9", status: "active",
    gameSeed: "0x1ce72fdf7009baf827f108a38f586f4f13269ae9856b1ef387ceed5fc2cf83a0",
    rows: [{ tiles: 4, deathTileIndex: 2, multiplier: 1.14 }],
  },
});

// ---- fixture 5: finished game carrying a seed (normal, must stay quiet) ----
const finished = JSON.stringify({
  games: [{ id: "g3", status: "won", gameSeed: "0x1ce72fdf7009baf827f108a38f586f4f13269ae9856b1ef387ceed5fc2cf83a0",
            rows: [{ tiles: 4, deathTileIndex: 2, multiplier: 1.14 }] }],
});

// ---- fixture 6: unrelated response (must not even be captured) ----
const unrelated = JSON.stringify({ effectiveBalance: "123", gameType: "death_race" });

let pass = 0, fail = 0;
const cases = [
  ["REAL active poll, all death tiles null      -> should NOT flag", { "/api/games/active?gameType=death_race": realActivePoll }, false],
  ["REAL select-tile, nextRow null              -> should NOT flag", { "/api/games/1/select-tile": realSelectTile }, false],
  ["SYNTHETIC nextRow carries a skull           -> SHOULD flag",     { "/api/games/1/select-tile": leakNextRow }, true],
  ["SYNTHETIC active game sends seed + board    -> SHOULD flag",     { "/api/games/active?gameType=death_race": leakWholeBoard }, true],
  ["FINISHED game with seed (normal)            -> should NOT flag", { "/api/games/history": finished }, false],
  ["unrelated response                          -> should NOT flag", { "/api/game-balance/death_race": unrelated }, false],
];
for (const [label, payloads, expected] of cases) {
  const ok = await runCase(label, payloads, expected);
  ok ? pass++ : fail++;
}
console.log(`\n${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
