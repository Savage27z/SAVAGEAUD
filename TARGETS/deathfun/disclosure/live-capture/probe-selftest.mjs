/**
 * Offline test of console-probe.js: does it correctly call the pre-reveal in both directions?
 * Mocks window.fetch, feeds it a few realistic payloads, and checks __df_dump()'s verdict.
 */
import fs from "node:fs";

const src = fs.readFileSync("/root/.hermes/workspace/SAVAGEAUD/TARGETS/deathfun/disclosure/live-capture/console-probe.js", "utf8");

function runCase(label, payloads, expected) {
  const listeners = [];
  const win = {
    fetch: async (url) => ({ clone: () => ({ text: async () => payloads[url] ?? "" }) }),
    XMLHttpRequest: function () {},
  };
  win.XMLHttpRequest.prototype = { open() {}, send() {}, addEventListener() {} };
  win.console = { log: (...a) => listeners.push(a.map(String).join(" ")) };

  // run the snippet verbatim — it is a self-contained IIFE that only needs window + console
  const fn = new Function("window", "console", src);
  fn(win, win.console);

  // drive the mocked fetches, then dump
  return (async () => {
    for (const url of Object.keys(payloads)) { try { await win.fetch(url); } catch {} }
    // let the .then() chain settle
    await new Promise((r) => setTimeout(r, 30));
    const verdict = win.__df_dump();
    const ok = verdict === expected;
    console.log(`${ok ? "PASS" : "FAIL"}  ${label}\n       expected ${expected}, got ${verdict}`);
    return ok;
  })();
}

const liveActive = JSON.stringify({
  currentGame: {
    id: "g1", status: "active", currentRowIndex: 1, selectedTiles: [2],
    gameSeed: "0x1ce72fdf7009baf827f108a38f586f4f13269ae9856b1ef387ceed5fc2cf83a0",
    commitmentHash: "0x4f1220e50b1c0c8b351b85158a2808cd4169f5f3399e15284f63b262d3dee361",
    rows: [{ tiles: 4, deathTileIndex: 2, multiplier: 1.14 }, { tiles: 3, deathTileIndex: 0, multiplier: 1.52 }],
  },
});
const activeNulled = JSON.stringify({
  currentGame: { id: "g2", status: "active", gameSeed: null, rows: [{ tiles: 4, deathTileIndex: null, multiplier: 1.14 }] },
});
const finished = JSON.stringify({
  games: [{ id: "g3", status: "won", gameSeed: "0x1ce72fdf7009baf827f108a38f586f4f13269ae9856b1ef387ceed5fc2cf83a0",
            rows: [{ tiles: 4, deathTileIndex: 2, multiplier: 1.14 }] }],
});
const unrelated = JSON.stringify({ effectiveBalance: "123", gameType: "death_race" });

let pass = 0, fail = 0;
const cases = [
  ["ACTIVE + seed + populated death tiles  -> should CONFIRM", { "/api/games/active?gameType=death_race": liveActive }, true],
  ["ACTIVE + nulled seed + null rows       -> should NOT flag", { "/api/games/active?gameType=death_race": activeNulled }, false],
  ["FINISHED + seed (normal behaviour)     -> should NOT flag", { "/api/games/history": finished }, false],
  ["unrelated response                     -> should NOT flag", { "/api/game-balance/death_race": unrelated }, false],
];
for (const [label, payloads, expected] of cases) {
  const ok = await runCase(label, payloads, expected);
  ok ? pass++ : fail++;
}
console.log(`\n${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
