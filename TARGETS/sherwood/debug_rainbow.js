#!/usr/bin/env node
// Connect via RAINBOW entry (injected connector path after isRainbow patch)
const fs = require("fs");
const path = require("path");
const CDP = "http://127.0.0.1:9222";
const TARGET_FILE = path.join(__dirname, "cdp_target");

async function main() {
  const list = await (await fetch(CDP + "/json/list")).json();
  const targetId = fs.readFileSync(TARGET_FILE, "utf8").trim();
  const t = list.find((x) => x.id === targetId);
  if (!t) { console.log("NOTARGET"); process.exit(1); }
  const ws = new WebSocket(t.webSocketDebuggerUrl);
  await new Promise((res) => (ws.onopen = res));
  let id = 0;
  const pending = new Map();
  ws.onmessage = (ev) => {
    const m = JSON.parse(ev.data);
    if (m.method === "Runtime.consoleAPICalled") {
      const args = m.params.args.map((a) => a.value ?? a.description ?? a.type ?? "").join(" ");
      if (args.includes("[stub.req]") || args.toLowerCase().includes("error")) console.log("[console]", args.slice(0, 250));
    } else if (m.method === "Network.requestWillBeSent") {
      const url = m.params.request.url;
      if (url.includes("sherwood") && !url.includes(".js")) console.log("[net]", m.params.request.method, url.slice(0, 130));
    } else if (m.id && pending.has(m.id)) {
      pending.get(m.id)(m.result);
      pending.delete(m.id);
    }
  };
  const send = (method, params = {}) => new Promise((res) => {
    const i = ++id; pending.set(i, res); ws.send(JSON.stringify({ id: i, method, params }));
  });
  const evalv = async (expr) => {
    const r = await send("Runtime.evaluate", { expression: expr, returnByValue: true, awaitPromise: true });
    return r?.result?.value;
  };
  await send("Runtime.enable");
  await send("Network.enable");

  console.log("[click-connect]", await evalv(`(() => { const els = [...document.querySelectorAll('button')]; const b = els.find(e => /connect/i.test(e.innerText)); if (b) { b.click(); return 'CLICKED'; } return 'NOBTN'; })()`));
  await new Promise((r) => setTimeout(r, 2000));
  console.log("[click-rainbow]", await evalv(`(() => { const els = [...document.querySelectorAll('button, [role=button]')]; const b = els.find(e => /rainbow/i.test(e.innerText || e.textContent)); if (b) { b.click(); return 'CLICKED:'+(b.innerText||'').trim(); } return 'NO:' + [...els].map(e=>(e.innerText||'').trim()).filter(Boolean).join('|').slice(0,300); })()`));
  await new Promise((r) => setTimeout(r, 8000));

  console.log("[wagmi]", await evalv(`(() => { try { return JSON.stringify(JSON.parse(localStorage.getItem('wagmi.store')||'null')); } catch(e){ return 'ERR'; } })()`));
  console.log("[conn-status]", await evalv(`localStorage.getItem('@appkit/connection_status')`));
  console.log("[body]", (await evalv(`document.body.innerText.slice(0, 500)`)));
  ws.close();
  process.exit(0);
}
main().catch((e) => { console.error("ERR", e.message); process.exit(1); });
