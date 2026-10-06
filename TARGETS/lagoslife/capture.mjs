#!/usr/bin/env node
/**
 * Capture the REAL client's /api/save request.
 *
 * Every hand-rolled PUT shape gets 409 "A newer save exists", including
 * fresh:true and a bare body. So the difference is structural, not a flag.
 * Hook window.fetch in the live logged-in page, trigger in-game activity so
 * the client saves, and print the exact request + response.
 */
import fs from "node:fs";
import http from "node:http";

const PORT = 9222, BASE = "https://lagoslife.eliysites.com";
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

function httpJson(path) {
  return new Promise((resolve, reject) => {
    http.get({ host: "127.0.0.1", port: PORT, path }, (res) => {
      let d = ""; res.on("data", (c) => (d += c));
      res.on("end", () => { try { resolve(JSON.parse(d)); } catch (e) { reject(e); } });
    }).on("error", reject);
  });
}

class CDP {
  constructor(ws) { this.ws = ws; this.id = 0; this.p = new Map(); }
  static async attach(u) {
    const ws = new WebSocket(u);
    await new Promise((res, rej) => { ws.onopen = res; ws.onerror = rej; });
    const c = new CDP(ws);
    ws.onmessage = (ev) => {
      const m = JSON.parse(ev.data);
      if (m.id && c.p.has(m.id)) { const { res, rej } = c.p.get(m.id); c.p.delete(m.id);
        m.error ? rej(new Error(JSON.stringify(m.error))) : res(m.result); }
    };
    return c;
  }
  send(m, params = {}) {
    const id = ++this.id;
    return new Promise((res, rej) => {
      this.p.set(id, { res, rej });
      this.ws.send(JSON.stringify({ id, method: m, params }));
      setTimeout(() => { if (this.p.has(id)) { this.p.delete(id); rej(new Error("timeout " + m)); } }, 40000);
    });
  }
  async js(e) {
    const r = await this.send("Runtime.evaluate", { expression: e, awaitPromise: true, returnByValue: true, userGesture: true });
    if (r.exceptionDetails) return { error: String(r.exceptionDetails.text || "").slice(0, 300) };
    return { value: r.result && r.result.value };
  }
}

const HOOK = `
(function(){
  if (window.__saveHook) return 'already';
  window.__cap = [];
  var of = window.fetch;
  window.fetch = function(){
    var args = [].slice.call(arguments);
    var url = String(args[0] && args[0].url ? args[0].url : args[0]);
    var opts = args[1] || {};
    var isSave = url.indexOf('/api/save') !== -1 && String(opts.method||'GET').toUpperCase() === 'PUT';
    var rec = null;
    if (isSave) {
      rec = { at: Date.now(), url: url, method: opts.method,
              headers: JSON.stringify(opts.headers || {}),
              body: opts.body || null };
      window.__cap.push(rec);
      if (window.__cap.length > 12) window.__cap.shift();
    }
    var p = of.apply(this, args);
    if (rec) {
      p.then(function(r){ rec.status = r.status; try { r.clone().json().then(function(j){ rec.resp = JSON.stringify(j).slice(0,300); }); } catch(e){} })
       .catch(function(e){ rec.err = String(e); });
    }
    return p;
  };
  window.__saveHook = true;
  return 'hooked';
})()`;

const TAP = `
(function(){
  var els=[].slice.call(document.querySelectorAll('button,a,[role=button],div[tabindex]'));
  var cand = els.filter(function(e){ return e.offsetParent!==null && !e.disabled; });
  // prefer the action chips the HUD offers ("Eat something", "Work", etc.)
  var act = cand.find(function(e){ return /eat something|tap the|work|sleep|shower|hustle|phone/i.test((e.textContent||'')); });
  if (act) { act.click(); return 'action:'+(act.textContent||'').trim().slice(0,40); }
  var generic = cand.find(function(e){ var t=(e.textContent||'').trim(); return t.length>2 && t.length<50 && !/privacy|essential|accept/i.test(t); });
  if (generic) { generic.click(); return 'generic:'+(generic.textContent||'').trim().slice(0,40); }
  return null;
})()`;

(async () => {
  const page = (await httpJson("/json")).find((t) => t.type === "page");
  const cdp = await CDP.attach(page.webSocketDebuggerUrl);
  await cdp.send("Runtime.enable");
  await cdp.js(HOOK);

  const hooked = await cdp.js(`String(window.__saveHook)`);
  console.log("hook installed:", hooked.value);

  // also log the fetch behaviour of the app's own save helper by watching network
  console.log("\n== triggering in-game activity to force a save ==");
  for (let i = 0; i < 10; i++) {
    const r = await cdp.js(TAP);
    console.log(`  tap ${i + 1}: ${r.value}`);
    await sleep(2500);
  }

  // wait for any in-flight saves
  await sleep(4000);

  const cap = await cdp.js(`JSON.stringify(window.__cap || [])`);
  const arr = JSON.parse(cap.value || "[]");
  console.log(`\n== captured ${arr.length} PUT /api/save request(s) ==`);
  fs.writeFileSync("/tmp/ll_captured_saves.json", JSON.stringify(arr, null, 2));
  for (const [i, c] of arr.entries()) {
    console.log(`\n--- capture ${i + 1}  (${new Date(c.at).toISOString()})`);
    console.log(`    url:     ${c.url}`);
    console.log(`    method:  ${c.method}`);
    console.log(`    headers: ${c.headers}`);
    console.log(`    status:  ${c.status}`);
    if (c.resp) console.log(`    resp:    ${c.resp}`);
    if (c.err) console.log(`    err:     ${c.err}`);
    let b = null; try { b = JSON.parse(c.body); } catch {}
    if (b) {
      console.log(`    body keys: ${JSON.stringify(Object.keys(b))}`);
      console.log(`    base=${JSON.stringify(b.base)}  fresh=${JSON.stringify(b.fresh)}  replace=${JSON.stringify(b.replace)}`);
      console.log(`    game.money=${b.game && b.game.money}  game.version=${b.game && b.game.version}`);
      console.log(`    body bytes=${c.body.length}`);
    } else {
      console.log(`    body(raw, first 300): ${String(c.body).slice(0, 300)}`);
    }
  }
  process.exit(0);
})().catch((e) => { console.error("FATAL", e); process.exit(1); });
