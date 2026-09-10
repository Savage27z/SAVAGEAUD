/* F03 pre-reveal check — paste this into your browser console at https://death.fun
 *
 * It hooks fetch + XHR and records every API response that mentions the seed, the death tiles,
 * or a game status. Nothing is sent anywhere; it only stores data in the page.
 *
 * Then: log in, start a game, make ONE pick, and run  __df_dump()  in the console.
 * Paste the output back.
 */
(() => {
  const KEYS = ["gameSeed", "deathTileIndex", "commitmentHash", "currentRowIndex", "selectedTiles"];
  window.__df_capture = [];
  const seen = new Set();

  function inspect(url, text) {
    if (typeof text !== "string" || text.length < 2) return;
    if (!KEYS.some((k) => text.includes(k))) return;
    const fp = url + "|" + text.length;
    if (seen.has(fp)) return;
    seen.add(fp);

    let status = null, seed = null, rows = null, deathTiles = null, gameState = null;
    try {
      const j = JSON.parse(text);
      const g = j?.currentGame || j?.game || (Array.isArray(j?.games) ? j.games[0] : j) || {};
      status = g?.status ?? null;
      seed = g?.gameSeed ?? null;
      gameState = g?.gameState ?? null;
      rows = Array.isArray(g?.rows) ? g.rows : null;
      if (rows) deathTiles = rows.map((r) => r?.deathTileIndex);
    } catch { /* not json */ }

    window.__df_capture.push({
      url, status, seed, rows: rows ? rows.length : null, deathTiles,
      hasPopulatedDeathTile: Array.isArray(deathTiles) ? deathTiles.some((d) => typeof d === "number") : null,
      hasSeed: !!seed, gameState,
      raw: text.slice(0, 900),
    });
    console.log("%c[DF-CAPTURE] " + url, "color:#0a0", { status, seed, deathTiles });
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
      console.log(`    status=${JSON.stringify(e.status)}  hasSeed=${e.hasSeed}  seed=${e.seed}`);
      console.log(`    rows=${e.rows}  deathTiles=${JSON.stringify(e.deathTiles)}  populatedDeathTile=${e.hasPopulatedDeathTile}`);
      console.log(`    raw: ${e.raw.slice(0, 600)}`);
    }
    const ANSWER = c.some((e) =>
      typeof e.status === "string" &&
      /active|in_?progress|playing|started|selecting/i.test(e.status) &&
      (e.hasSeed || e.hasPopulatedDeathTile));
    console.log(`\n===== ANSWER =====`);
    console.log(ANSWER
      ? "PRE-REVEAL CONFIRMED: an ACTIVE game's response carried the seed and/or death tiles."
      : "No active-game response carried the seed or death tiles. (A seed on a FINISHED game is normal.)");
    return ANSWER;
  };

  console.log("%c[DF-CAPTURE] hooked. Log in, start a game, make one pick, then run:  __df_dump()",
              "color:#0af;font-weight:bold");
})();
