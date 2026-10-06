#!/usr/bin/env node
/**
 * Lagos Life - let the REAL client build a genuine save, then hand me the object.
 *
 * Why: the server returns 400 {"error":"Bad save"} for hand-made game objects,
 * so it validates structure. To test money cleanly I need a save the server
 * itself considers legitimate, then change ONE field.
 *
 * Zero deps: Node 24 global WebSocket + Chrome DevTools Protocol.
 * Auth: same-origin fetch to /api/auth/login (the app's own path) - no form poking.
 */
import fs from "node:fs";
import http from "node:http";

const PORT = 9222;
const BASE = "https://lagoslife.eliysites.com";
const creds = JSON.parse(fs.readFileSync("/tmp/ll_probe_creds.json", "utf8"));

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

function httpJson(path) {
  return new Promise((resolve, reject) => {
    http.get({ host: "127.0.0.1", port: PORT, path }, (res) => {
      let d = "";
      res.on("data", (c) => (d += c));
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
        const { res, rej } = c.pending.get(m.id);
        c.pending.delete(m.id);
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
  async evalJs(expr, awaitPromise = true) {
    const r = await this.send("Runtime.evaluate", {
      expression: expr, awaitPromise, returnByValue: true, userGesture: true,
    });
    if (r.exceptionDetails) return { error: JSON.stringify(r.exceptionDetails).slice(0, 400) };
    return { value: r.result && r.result.value };
  }
}

const HELPERS = `
window.__ll = {
  click: function(txt){
    var t = txt.toLowerCase();
    var els = [].slice.call(document.querySelectorAll('button,a,[role=button],div[tabindex]'));
    var el = els.find(function(e){ return e.offsetParent !== null && (e.textContent||'').trim().toLowerCase().indexOf(t) !== -1; });
    if (!el) return null;
    el.click(); return (el.textContent||'').trim().slice(0,60);
  },
  setInput: function(sel, val){
    var i = document.querySelector(sel);
    if (!i) return 'no input: ' + sel;
    var setter = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value').set;
    setter.call(i, val);
    i.dispatchEvent(new Event('input', { bubbles: true }));
    i.dispatchEvent(new Event('change', { bubbles: true }));
    return i.value;
  },
  buttons: function(){
    return [].slice.call(document.querySelectorAll('button,a,[role=button]'))
      .filter(function(e){ return e.offsetParent !== null; })
      .map(function(e){ return (e.textContent||'').trim().slice(0,40); }).filter(Boolean).slice(0,40);
  },
  inputs: function(){
    return [].slice.call(document.querySelectorAll('input')).map(function(e){
      return { id: e.id||null, aria: e.getAttribute('aria-label'), ph: e.placeholder||null, type: e.type };
    });
  },
  body: function(){ return (document.body.innerText||'').slice(0,400); }
};
'ok'`;

(async () => {
  let targets = await httpJson("/json");
  let page = targets.find((t) => t.type === "page");
  if (!page) throw new Error("no page target");
  const cdp = await CDP.attach(page.webSocketDebuggerUrl);
  await cdp.send("Page.enable");
  await cdp.send("Runtime.enable");

  console.log("== navigate ==");
  await cdp.send("Page.navigate", { url: BASE + "/" });
  await sleep(6000);
  await cdp.evalJs(HELPERS);

  console.log("\n== login via the app's own endpoint (sets the session cookie) ==");
  const login = await cdp.evalJs(`
    fetch("/api/auth/login", {method:"POST", headers:{"Content-Type":"application/json"},
      body: JSON.stringify({username:${JSON.stringify(creds.username)}, password:${JSON.stringify(creds.password)}})
    }).then(r=>r.text()).then(t=>"login: "+t).catch(e=>"login ERR "+e)`);
  console.log("  ", JSON.stringify(login));

  const me = await cdp.evalJs(`fetch("/api/auth/me").then(r=>r.json()).then(j=>JSON.stringify(j)).catch(e=>"ERR "+e)`);
  console.log("   me:", me.value);

  console.log("\n== reload into the game ==");
  await cdp.send("Page.navigate", { url: BASE + "/" });
  await sleep(7000);
  await cdp.evalJs(HELPERS);

  let state = await cdp.evalJs(`JSON.stringify({inputs: window.__ll.inputs(), buttons: window.__ll.buttons(), body: window.__ll.body()})`);
  console.log("  screen:", (state.value || "").slice(0, 900));

  console.log("\n== onboarding: start a new life ==");
  for (const label of ["Start a new life", "New life", "Start over", "Continue"]) {
    const r = await cdp.evalJs(`window.__ll.click(${JSON.stringify(label)})`);
    if (r.value) { console.log(`  clicked "${label}" -> ${r.value}`); await sleep(2500); break; }
  }
  await cdp.evalJs(HELPERS);
  state = await cdp.evalJs(`JSON.stringify({inputs: window.__ll.inputs(), buttons: window.__ll.buttons()})`);
  console.log("  screen:", (state.value || "").slice(0, 700));

  // step 0: name
  await cdp.evalJs(`window.__ll.setInput('input[aria-label="Your name"]', 'ProbeSim')`);
  await sleep(400);
  let n = await cdp.evalJs(`window.__ll.click("Next")`);
  console.log(`  step0 name -> Next: ${n.value}`);
  await sleep(2000); await cdp.evalJs(HELPERS);

  // step 1: pick 2 traits (TRAITS buttons), then Next
  let tr = await cdp.evalJs(`
    (function(){
      var els=[].slice.call(document.querySelectorAll('button')).filter(function(e){return e.offsetParent!==null && e.querySelector('div')});
      var picked=[];
      for (var i=0;i<els.length && picked.length<2;i++){
        var t=(els[i].textContent||'').trim();
        if(t.length>3 && t.length<60 && !/next|back/i.test(t)){ els[i].click(); picked.push(t.slice(0,32)); }
      }
      return JSON.stringify(picked);
    })()`);
  console.log("  traits picked:", tr.value);
  await sleep(1200); await cdp.evalJs(HELPERS);
  n = await cdp.evalJs(`window.__ll.click("Next")`);
  console.log(`  step1 -> Next: ${n.value}`);
  await sleep(2000); await cdp.evalJs(HELPERS);

  // step 2: aspiration (first button), then Next
  let asp = await cdp.evalJs(`
    (function(){
      var els=[].slice.call(document.querySelectorAll('button')).filter(function(e){return e.offsetParent!==null});
      for (var i=0;i<els.length;i++){ var t=(els[i].textContent||'').trim();
        if(t.length>4 && !/next|back|randomise/i.test(t)){ els[i].click(); return t.slice(0,40); } }
      return null; })()`);
  console.log("  aspiration:", asp.value);
  await sleep(1200); await cdp.evalJs(HELPERS);
  n = await cdp.evalJs(`window.__ll.click("Next")`);
  console.log(`  step2 -> Next: ${n.value}`);
  await sleep(3500); await cdp.evalJs(HELPERS);

  // step 3: origin spin (auto after ~1.8s), then Next
  n = await cdp.evalJs(`window.__ll.click("Next")`);
  console.log(`  step3 -> Next: ${n.value}`);
  await sleep(3000); await cdp.evalJs(HELPERS);

  // step 4: home, then Move in
  let hm = await cdp.evalJs(`
    (function(){
      var els=[].slice.call(document.querySelectorAll('button')).filter(function(e){return e.offsetParent!==null});
      for (var i=0;i<els.length;i++){ var t=(els[i].textContent||'').trim();
        if(/₦|area|Hall|Lekki|Yaba|Mushin|Surulere|Ikeja/i.test(t) && t.length>8){ els[i].click(); return t.slice(0,60); } }
      return null; })()`);
  console.log("  home picked:", hm.value);
  await sleep(1200); await cdp.evalJs(HELPERS);
  let mi = await cdp.evalJs(`window.__ll.click("Move in")`);
  console.log(`  Move in: ${mi.value}`);

  console.log("\n== waiting for the client to PUT a real save ==");
  let game = null;
  for (let i = 0; i < 20; i++) {
    await sleep(3000);
    const r = await cdp.evalJs(`fetch("/api/save").then(r=>r.json()).then(j=>JSON.stringify({had:!!j.game, money:j.game&&j.game.money, updatedAt:j.updatedAt, keys:j.game?Object.keys(j.game).length:0})).catch(e=>"ERR "+e)`);
    console.log(`  poll ${i + 1}: ${r.value}`);
    const s = String(r.value || "");
    if (s.indexOf('"had":true') !== -1) { game = s; break; }
  }

  console.log("\n== dump the genuine save to disk ==");
  const dump = await cdp.evalJs(`fetch("/api/save").then(r=>r.json()).then(j=>JSON.stringify(j)).catch(e=>"ERR "+e)`);
  fs.writeFileSync("/tmp/ll_genuine_save.json", String(dump.value || ""));
  console.log("  bytes:", (dump.value || "").length);

  const screens = await cdp.evalJs(`JSON.stringify({buttons: window.__ll.buttons(), body: window.__ll.body()})`);
  console.log("  final screen:", (screens.value || "").slice(0, 500));
  console.log("\nDONE");
  process.exit(0);
})().catch((e) => { console.error("FATAL", e); process.exit(1); });
