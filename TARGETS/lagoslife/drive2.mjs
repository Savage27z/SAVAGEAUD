#!/usr/bin/env node
/**
 * Lagos Life - scripted onboarding (explicit steps, index-based option picks).
 * The traits/aspiration buttons TOGGLE, so the same click twice = deselect.
 * Hence: click option 0, then option 1 (never the same one twice).
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
      if (m.id && c.p.has(m.id)) {
        const { res, rej } = c.p.get(m.id); c.p.delete(m.id);
        m.error ? rej(new Error(JSON.stringify(m.error))) : res(m.result);
      }
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
    if (r.exceptionDetails) return { error: String(r.exceptionDetails.text || "").slice(0, 200) };
    return { value: r.result && r.result.value };
  }
}

const PRELUDE = `
window.__x = {
  opts: function(){
    return [].slice.call(document.querySelectorAll('button')).filter(function(e){
      var t=(e.textContent||'').trim();
      return e.offsetParent!==null && !e.disabled && t.length>4 && t.length<120 &&
        !/^(next|continue|move in|privacy|essential only|accept|back|log out|sign up|log in|close|drag to spin)/i.test(t);
    });
  },
  clickOpt: function(i){
    var a=window.__x.opts(); if(i<0||i>=a.length) return 'idx '+i+' of '+a.length;
    var t=(a[i].textContent||'').trim(); a[i].click(); return t.slice(0,50);
  },
  clickText: function(re){
    var r=new RegExp(re,'i');
    var el=[].slice.call(document.querySelectorAll('button,a,[role=button]')).find(function(e){
      return e.offsetParent!==null && !e.disabled && r.test((e.textContent||'').trim()); });
    if(!el) return null; el.click(); return (el.textContent||'').trim().slice(0,50);
  },
  nextEnabled: function(){
    var el=[].slice.call(document.querySelectorAll('button')).find(function(e){
      return /^(next|move in)$/i.test((e.textContent||'').trim()); });
    return el ? !el.disabled : null;
  },
  step: function(){ var b=document.body.innerText||''; var m=b.match(/^(Look|Personality|Dream|Birth lottery|Home)$/m); return m?m[1]:null; },
  choose: function(){ var m=(document.body.innerText||'').match(/Choose (\\d) more/); return m?m[1]:null; },
  body: function(){ return (document.body.innerText||'').replace(/\\n+/g,' | ').slice(0,200); }
};
'ok'`;

(async () => {
  const page = (await httpJson("/json")).find((t) => t.type === "page");
  const cdp = await CDP.attach(page.webSocketDebuggerUrl);
  await cdp.send("Runtime.enable");
  await cdp.send("Page.enable");

  const u = await cdp.js(`location.href`);
  if (!String(u.value || "").includes("lagoslife")) {
    await cdp.send("Page.navigate", { url: BASE + "/" }); await sleep(7000);
  }
  await cdp.js(PRELUDE);

  const report = async (tag) => {
    const s = await cdp.js(`JSON.stringify({step:window.__x.step(), choose:window.__x.choose(), next:window.__x.nextEnabled(), n:window.__x.opts().length, body:window.__x.body()})`);
    let o = {}; try { o = JSON.parse(s.value || "{}"); } catch {}
    console.log(`  [${tag}] step=${o.step} chooseMore=${o.choose} nextEnabled=${o.next} opts=${o.n}`);
    console.log(`         ${String(o.body || "").slice(0, 140)}`);
    return o;
  };

  // dismiss cookie banner if present
  let a = await cdp.js(`window.__x.clickText("^Accept$")`); if (a.value) { console.log("banner:", a.value); await sleep(1500); }
  a = await cdp.js(`window.__x.clickText("^(Continue|Start a new life|New life)$")`); if (a.value) { console.log("entry:", a.value); await sleep(2500); }

  await report("start");

  // ---- step: Personality -> pick TWO DISTINCT traits ----
  console.log("\n== Personality: pick 2 distinct traits ==");
  let pre = await report("pre");
  if (pre.step === "Personality") {
    for (const i of [0, 1]) {
      const r = await cdp.js(`window.__x.clickOpt(${i})`);
      console.log(`  clickOpt(${i}) -> ${r.value}`);
      await sleep(1400);
    }
    await report("after-traits");
  }

  // advance through any remaining steps
  console.log("\n== advance ==");
  for (let i = 0; i < 14; i++) {
    const st = await report("loop" + i);
    if (st.step === null && st.next === null) { console.log("  (no more steps)"); break; }
    if (st.next === true) {
      const r = await cdp.js(`window.__x.clickText("^(Next|Move in)$")`);
      console.log(`  -> advanced: ${r.value}`);
      await sleep(2600);
      // origin step auto-spins ~1.8s after arrival
      continue;
    }
    // next disabled: satisfy the step
    if (st.choose) {
      const need = parseInt(st.choose, 10);
      const before = st.n;
      for (let k = 0; k < need; k++) {
        const r = await cdp.js(`window.__x.clickOpt(0)`);
        console.log(`  trait pick -> ${r.value}`);
        await sleep(1300);
      }
    } else {
      const r = await cdp.js(`window.__x.clickOpt(0)`);
      console.log(`  option pick -> ${r.value}`);
      await sleep(1500);
    }
  }

  console.log("\n== poll for a genuine server-side save ==");
  let ok = false;
  for (let i = 0; i < 14; i++) {
    const r = await cdp.js(`fetch("/api/save").then(r=>r.json()).then(j=>JSON.stringify({had:!!j.game, money:j.game&&j.game.money, updatedAt:j.updatedAt, keys:j.game?Object.keys(j.game).length:0})).catch(e=>"ERR "+e)`);
    console.log(`  poll ${i + 1}: ${r.value}`);
    if (String(r.value || "").includes('"had":true')) { ok = true; break; }
    await sleep(3000);
  }

  const dump = await cdp.js(`fetch("/api/save").then(r=>r.json()).then(j=>JSON.stringify(j)).catch(e=>"ERR "+e)`);
  fs.writeFileSync("/tmp/ll_genuine_save.json", String(dump.value || ""));
  console.log("\n  bytes:", String(dump.value || "").length, "| save present:", ok);
  await report("final");
  process.exit(0);
})().catch((e) => { console.error("FATAL", e); process.exit(1); });
