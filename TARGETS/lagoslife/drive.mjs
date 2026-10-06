#!/usr/bin/env node
/**
 * Lagos Life - adaptive onboarding walker.
 *
 * The create flow gates "Next" until each step is satisfied (name -> 2 traits ->
 * aspiration -> origin spin -> home -> Move in). So the rule is simple:
 *   if a NEXT-ish button is ENABLED, click it; otherwise click the first option.
 * Repeat until the client has PUT a genuine save, then dump it.
 */
import fs from "node:fs";
import http from "node:http";

const PORT = 9222;
const BASE = "https://lagoslife.eliysites.com";

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
  constructor(ws) { this.ws = ws; this.id = 0; this.pending = new Map(); }
  static async attach(wsUrl) {
    const ws = new WebSocket(wsUrl);
    await new Promise((res, rej) => { ws.onopen = res; ws.onerror = rej; });
    const c = new CDP(ws);
    ws.onmessage = (ev) => {
      const m = JSON.parse(ev.data);
      if (m.id && c.pending.has(m.id)) {
        const { res, rej } = c.pending.get(m.id); c.pending.delete(m.id);
        m.error ? rej(new Error(JSON.stringify(m.error))) : res(m.result);
      }
    };
    return c;
  }
  send(method, params = {}) {
    const id = ++this.id;
    return new Promise((res, rej) => {
      this.pending.set(id, { res, rej });
      this.ws.send(JSON.stringify({ id, method, params }));
      setTimeout(() => { if (this.pending.has(id)) { this.pending.delete(id); rej(new Error("timeout " + method)); } }, 45000);
    });
  }
  async js(expr) {
    const r = await this.send("Runtime.evaluate", { expression: expr, awaitPromise: true, returnByValue: true, userGesture: true });
    if (r.exceptionDetails) return { error: String(r.exceptionDetails.text || "").slice(0, 300) };
    return { value: r.result && r.result.value };
  }
}

// Screen reader + one adaptive action, all in page context.
const SCAN = `
(function(){
  function vis(e){ return e.offsetParent !== null && !e.disabled; }
  var all = [].slice.call(document.querySelectorAll('button,a,[role=button]'));
  var visibles = all.filter(vis);
  return JSON.stringify({
    nextish: visibles.filter(function(e){ return /^(next|continue|move in|sign up|log in|accept)$/i.test((e.textContent||'').trim()); })
                     .map(function(e){ return {t:(e.textContent||'').trim(), dis:e.disabled}; }),
    disabledNext: all.filter(function(e){ return /^(next|move in)$/i.test((e.textContent||'').trim()) && e.disabled; })
                     .map(function(e){ return (e.textContent||'').trim(); }),
    opts: visibles.filter(function(e){ var t=(e.textContent||'').trim(); return t.length>4 && t.length<90 && !/next|continue|move in|privacy|essential|accept|log out|sign up|log in/i.test(t); })
                  .map(function(e){ return t2((e.textContent||'').trim()).slice(0,48); }),
    body: (document.body.innerText||'').slice(0,220),
    money: (document.body.innerText||'').indexOf('\\u20a6')
  });
  function t2(s){ return s; }
})()`;

const ACT = (label) => `
(function(){
  var t = ${JSON.stringify(label)}.toLowerCase();
  var els = [].slice.call(document.querySelectorAll('button,a,[role=button]'));
  var el = els.find(function(e){ return e.offsetParent !== null && !e.disabled && (e.textContent||'').trim().toLowerCase() === t; })
        || els.find(function(e){ return e.offsetParent !== null && !e.disabled && (e.textContent||'').trim().toLowerCase().indexOf(t) !== -1; });
  if (!el) return null;
  el.click();
  return (el.textContent||'').trim().slice(0, 60);
})()`;

const CLICK_FIRST_OPTION = `
(function(){
  var els = [].slice.call(document.querySelectorAll('button'));
  for (var i=0;i<els.length;i++){
    var e = els[i], t=(e.textContent||'').trim();
    if (e.offsetParent === null || e.disabled) continue;
    if (t.length < 4 || t.length > 90) continue;
    if (/^(next|continue|move in|privacy|essential only|accept|back|log out|sign up|log in|close)$/i.test(t)) continue;
    if (/drag to spin|your sim/i.test(t)) continue;
    e.click(); return t.slice(0, 55);
  }
  return null;
})()`;

(async () => {
  const targets = await httpJson("/json");
  const page = targets.find((t) => t.type === "page");
  if (!page) throw new Error("no page target");
  const cdp = await CDP.attach(page.webSocketDebuggerUrl);
  await cdp.send("Runtime.enable");

  const url = await cdp.js(`location.href`);
  console.log("current url:", url.value);
  if (!String(url.value || "").includes("lagoslife")) {
    console.log("navigating...");
    await cdp.send("Page.enable");
    await cdp.send("Page.navigate", { url: BASE + "/" });
    await sleep(7000);
  }

  // dismiss any cookie banner once
  const acc = await cdp.js(ACT("Accept"));
  if (acc.value) { console.log("dismissed banner:", acc.value); await sleep(1500); }

  let madeIt = false;
  for (let step = 1; step <= 45; step++) {
    const s = await cdp.js(SCAN);
    let info = {};
    try { info = JSON.parse(s.value || "{}"); } catch { info = {}; }
    console.log(`\n[${step}] next-enabled: ${JSON.stringify((info.nextish || []).map(x => x.t))}  blocked: ${JSON.stringify(info.disabledNext || [])}`);
    console.log(`     options: ${JSON.stringify((info.opts || []).slice(0, 6))}`);
    console.log(`     body: ${String(info.body || "").replace(/\n/g, " | ").slice(0, 150)}`);

    // in game? the HUD shows the money symbol and no Next button
    const bodyStr = String(info.body || "");
    if (!(info.nextish || []).some(x => /next|continue|move in/i.test(x.t)) &&
        /money|home|hustle|energy|hunger/i.test(bodyStr) && step > 8) {
      console.log("\n>> looks like we're in the game");
      madeIt = true; break;
    }

    const nxt = (info.nextish || []).find(x => /next|move in|continue/i.test(x.t));
    let did = null;
    if (nxt) {
      did = await cdp.js(ACT(nxt.t));
      console.log(`     -> clicked NEXT-ish: ${did.value}`);
    } else {
      did = await cdp.js(CLICK_FIRST_OPTION);
      console.log(`     -> clicked OPTION: ${did.value}`);
    }
    if (!did.value) { console.log("     (nothing clickable)"); }
    await sleep(1800);
    // origin step auto-spins after ~1.8s; give it room
    if (step % 6 === 0) await sleep(1500);
  }

  console.log("\n== poll for a genuine server-side save ==");
  let got = null;
  for (let i = 0; i < 15; i++) {
    const r = await cdp.js(`fetch("/api/save").then(r=>r.json()).then(j=>JSON.stringify({had:!!j.game, money:j.game&&j.game.money, updatedAt:j.updatedAt, keys:j.game?Object.keys(j.game).length:0})).catch(e=>"ERR "+e)`);
    console.log(`  poll ${i + 1}: ${r.value}`);
    if (String(r.value || "").includes('"had":true')) { got = r.value; break; }
    await sleep(3000);
  }

  const dump = await cdp.js(`fetch("/api/save").then(r=>r.json()).then(j=>JSON.stringify(j)).catch(e=>"ERR "+e)`);
  fs.writeFileSync("/tmp/ll_genuine_save.json", String(dump.value || ""));
  console.log("\n  saved bytes:", String(dump.value || "").length, "->  /tmp/ll_genuine_save.json");
  console.log("  reached in-game:", madeIt, "| save present:", !!got);
  process.exit(0);
})().catch((e) => { console.error("FATAL", e); process.exit(1); });
