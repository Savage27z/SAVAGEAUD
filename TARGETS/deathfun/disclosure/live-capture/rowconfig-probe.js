/* rowConfig validation probe — run in the death.fun console while logged in.
 *
 * WHY: the client POSTs /api/abstract/games/create with a body it builds itself:
 *        body: JSON.stringify({ betAmount, rowConfig: rows.map(e => e.tiles) })
 *      The only bounds check we can see is CLIENT-SIDE, in a UI input
 *      ("Tile count must be between ${MIN_TILES} and ${MAX_TILES}" -> 2..7).
 *      If the server does not re-validate, a direct request can set tiles per row to
 *      anything, and the death tile is computed as `sha256(seed-rowN) % tiles`.
 *
 *   tiles = 0  ->  `x % 0` is NaN in JS -> deathTileIndex NaN -> `pick === NaN` is
 *                 ALWAYS false -> the player can never land on a skull.
 *   tiles = 1  ->  index is always 0 -> the single tile is always the skull.
 *
 * WHAT THIS DOES: sends ONE create request with a board of 25 zero-tile rows and prints
 * the raw response. It does NOT pick a tile, does NOT cash out, and does NOT touch any
 * other player's game. Cost if accepted: our own 0.001 ETH stake.
 *
 * READING THE RESULT:
 *   400 / an error body  -> the server validates. No bug. Done, tell nobody.
 *   200 + preliminaryGameId -> NOT validated. Re-read /api/games/active and look at the
 *      rows: tiles=0 and a NaN/null death tile confirms the arithmetic is reachable.
 *      STOP THERE and report — do not play it out, do not cash out.
 */
(async () => {
  const MIN = "1000000000000000"; // 0.001 ETH = the ~$2.44 minimum
  const ROWS = 25;                // DEATH_RACE_TOTAL_ROWS

  async function send(label, rowConfig, betAmount = MIN) {
    const url = "/api/abstract/games/create?gameType=death_race";
    const body = JSON.stringify({ betAmount, rowConfig });
    console.log(`%c[PROBE] ${label} -> POST ${url}`, "color:#0af;font-weight:bold");
    console.log("        body:", body);
    let res, text;
    try {
      res = await fetch(url, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        credentials: "include",
        body,
      });
      text = await res.text();
    } catch (e) {
      console.log("        fetch threw:", e); return null;
    }
    let parsed = null; try { parsed = JSON.parse(text); } catch {}
    console.log(`        HTTP ${res.status} ${res.statusText}`);
    console.log("        response:", text.slice(0, 600));

    const accepted = res.ok && parsed && (parsed.preliminaryGameId || parsed.gameId || parsed.id);
    console.log(accepted
      ? `        => %cACCEPTED (${parsed.preliminaryGameId ?? parsed.gameId ?? parsed.id}) — server did NOT reject this board`
      : "        => rejected / no game id returned");
    return accepted ? (parsed.preliminaryGameId ?? parsed.gameId ?? parsed.id) : null;
  }

  console.log("=== rowConfig validation probe ===");
  // 1) the honest control: a legal board, to prove the probe itself works
  const legal = Array(ROWS).fill(3);
  await send("CONTROL legal board [3 x25]", legal);

  // 2) the test: 25 zero-tile rows
  const zero = Array(ROWS).fill(0);
  const got = await send("TEST zero-tile board [0 x25]", zero);

  if (got) {
    console.log("\n%c*** ACCEPTED A ZERO-TILE BOARD ***", "color:#f00;font-weight:bold");
    console.log("Now reading the resulting game state (read-only):");
    try {
      const r = await fetch("/api/games/active?gameType=death_race", { credentials: "include" });
      const j = await r.json();
      const g = j?.currentGame;
      console.log("  status:", g?.status, " bet:", g?.betAmount);
      console.log("  rows:", JSON.stringify(g?.rows?.slice(0, 5)));
      const tiles = (g?.rows ?? []).map((x) => x.tiles);
      console.log("  tiles per row:", JSON.stringify(tiles));
      console.log("  any NaN/null death tile:",
        (g?.rows ?? []).some((x) => x.deathTileIndex === null || Number.isNaN(x.deathTileIndex)));
      console.log("  seed present while active:", !!(g?.gameSeed));
      console.log("\n  STOP. Do not pick a tile. Do not cash out. Screenshot this and report back.");
    } catch (e) { console.log("  read failed:", e); }
  } else {
    console.log("\n%cServer rejected the illegal board — rowConfig IS validated server-side.",
                "color:#0a0;font-weight:bold");
    console.log("This path is closed. Nothing to report.");
  }
})();
