/* F03 pre-reveal check — paste this into your browser console at https://death.fun
 *
 * It hooks fetch + XHR and records every API response that mentions the seed, the death tiles,
 * or a game status. Nothing is sent anywhere; it only stores data in the page.
 *
 * Then: log in, start a game, make ONE pick, and run  __df_dump()  in the console.
 * Paste the output back.
 *
 * v2 (2026-09-10) — parser rewritten after the first live capture.
 *   v1 only looked at currentGame / game / games[0], so it MISSED the nested
 *   currentRow / nextRow shape returned by POST /api/games/{id}/select-tile.
 *   That shape is the one that actually matters: nextRow.deathTileIndex is the
 *   still-unplayed row, so a populated value there is the real leak signal.
 *   v1 would have reported "no leak" even if nextRow carried a death tile.
 */
(() => {
  const KEYS = ["gameSeed", "deathTileIndex", "commitmentHash", "currentRowIndex", "selectedTiles", "nextRow"];
  window.__df_capture = [];
  const seen = new Set();

  const num = (v) => (typeof v === "number" ? v : null);

  // A row whose death tile is populated == a revealed skull.
  function rowsOf(v) {
    if (!Array.isArray(v)) return null;
    return v.map((r) => (r && typeof r === "object" ? num(r.deathTileIndex) : null));
  }

  function inspect(url, text) {
    if (typeof text !== "string" || text.length < 2) return;
    if (!KEYS.some((k) => text.includes(k))) return;
    const fp = url + "|" + text.length;
    if (seen.has(fp)) return;
    seen.add(fp);

    let j = null;
    try { j = JSON.parse(text); } catch { /* not json */ }

    // shape 1: polled game state  { currentGame|game|games[0] }
    const g = j?.currentGame || j?.game || (Array.isArray(j?.games) ? j.games[0] : null) || j || {};
    // shape 2: POST /select-tile  { currentRow, nextRow } at the TOP level
    const curRow = j?.currentRow ?? g?.currentRow ?? null;
    const nextRow = j?.nextRow ?? g?.nextRow ?? null;

    const rows = Array.isArray(g?.rows) ? g.rows : null;
    const rowTiles = rowsOf(rows);
    const curDeath = curRow ? num(curRow.deathTileIndex) : null;
    const nextDeath = nextRow ? num(nextRow.deathTileIndex) : null;

    const status = g?.status ?? j?.status ?? null;
    const seed = g?.gameSeed ?? j?.gameSeed ?? null;
    const active = typeof status === "string" && /active|in_?progress|playing|started|selecting/i.test(status);

    // The leak condition, stated precisely: while the game is still live,
    // do we know the skull of a row that has NOT been played yet?
    const boardRevealed = Array.isArray(rowTiles) && rowTiles.some((d) => d !== null);
    const futureRowRevealed = nextDeath !== null;
    const leak = active && (!!seed || boardRevealed || futureRowRevealed);

    window.__df_capture.push({
      url, status, seed, active,
      rows: rows ? rows.length : null,
      deathTiles: rowTiles,
      currentRowDeathTile: curDeath,
      nextRowDeathTile: nextDeath,
      boardRevealed, futureRowRevealed, leak,
      raw: text.slice(0, 900),
    });
    console.log("%c[DF-CAPTURE] " + url, "color:#0a0",
      { status, seed, nextRowDeathTile: nextDeath, leak });
  }

  const of = window.fetch;
  window.fetch = async function (...a) {
    const res = await of.apply(this, a);
    try {
      const url = typeof a[0] === "string" ? a[0] : a[0]?.url;
      res.clone().text().then((t) => inspect(url, t)).catch(() => {});
    } catch {}
    return res;
  };

  const oo = window.XMLHttpRequest.prototype.open, os = window.XMLHttpRequest.prototype.send;
  window.XMLHttpRequest.prototype.open = function (m, u, ...r) { this.__df_url = u; return oo.call(this, m, u, ...r); };
  window.XMLHttpRequest.prototype.send = function (...r) {
    this.addEventListener("load", () => { try { inspect(this.__df_url, this.responseText); } catch {} });
    return os.apply(this, r);
  };

  window.__df_dump = () => {
    const c = window.__df_capture;
    console.log(`\n===== DF CAPTURE: ${c.length} relevant responses =====`);
    for (const e of c) {
      console.log(`\n--- ${e.url}`);
      console.log(`    status=${JSON.stringify(e.status)}  active=${e.active}  hasSeed=${!!e.seed}  seed=${e.seed}`);
      console.log(`    rows=${e.rows}  boardDeathTiles=${JSON.stringify(e.deathTiles)}`);
      console.log(`    currentRowDeathTile=${JSON.stringify(e.currentRowDeathTile)}  nextRowDeathTile=${JSON.stringify(e.nextRowDeathTile)}`);
      console.log(`    boardRevealed=${e.boardRevealed}  futureRowRevealed=${e.futureRowRevealed}`);
      console.log(`    raw: ${e.raw.slice(0, 600)}`);
    }
    const ANSWER = c.some((e) => e.leak);
    console.log(`\n===== ANSWER =====`);
    console.log(ANSWER
      ? "PRE-REVEAL CONFIRMED: a LIVE game's response carried the seed, a future row's skull, or a populated board."
      : "No live-game response carried the seed or a future row's skull. (A revealed tile on the row you just played, or a seed on a FINISHED game, is normal.)");
    return ANSWER;
  };

  console.log("%c[DF-CAPTURE] hooked. Log in, start a game, make one pick, then run:  __df_dump()",
              "color:#0af;font-weight:bold");
})();
