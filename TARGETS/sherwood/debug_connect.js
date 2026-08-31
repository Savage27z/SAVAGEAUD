#!/usr/bin/env node
// Debug: capture console + network during connect flow
const fs = require("fs");
const path = require("path");
const CDP = "http://127.0.0.1:9222";
const TARGET_FILE = path.join(__dirname, "cdp_target");

async function main() {
  const list = await (await fetch(CDP + "/json/list")).json();
  const targetId = fs.readFileSync(TARGET_FILE, "utf8").trim();
  const t = list.find((x) => x.id === targetId);
  const ws = new WebSocket(t.webSocketDebuggerUrl);
  await new Promise((res) => (ws.onopen = res));
  let id = 0;
  const pending = new Map();
  ws.onmessage = (ev) => {
    const m = JSON.parse(ev.data);
    if (m.method === "Runtime.consoleAPICalled") {
      const args = m.params.args.map((a) => a.value ?? a.description ?? "").join(" ");
      console.log("[console]", args.slice(0, 200));
    } else if (m.method === "Runtime.exceptionThrown") {
      console.log("[EXC]", JSON.stringify(m.params.exceptionDetails).slice(0, 300));
    } else if (m.method === "Network.requestWillBeSent") {
      const url = m.params.request.url;
      if (url.includes("sherwood") || url.includes("relay")) {
        console.log("[net]", m.params.request.method, url.slice(0, 140));
      }
    } else if (m.id && pending.has(m.id)) {
      pending.get(m.id)(m.result);
      pending.delete(m.id);
    }
  };
  const send = (method, params = {}) =>
    new Promise((res) => {
      const i = ++id;
      pending.set(i, res);
      ws.send(JSON.stringify({ id: i, method, params }));
    });

  await send("Runtime.enable");
  await send("Network.enable");
  // Click Connect
  await send("Runtime.evaluate", {
    expression: `(() => { const els = [...document.querySelectorAll('button')]; const b = els.find(e => /connect/i.test(e.innerText)); if (b) b.click(); return 'ok'; })()`,
    returnByValue: true,
  });
  await new Promise((r) => setTimeout(r, 1500));
  // Click MetaMask
  await send("Runtime.evaluate", {
    expression: `(() => { const els = [...document.querySelectorAll('button, [role=button]')]; const b = els.find(e => /metamask/i.test(e.innerText || e.textContent)); if (b) b.click(); return b ? 'mm-clicked' : 'no-mm'; })()`,
    returnByValue: true,
  });
  await new Promise((r) => setTimeout(r, 10000));
  ws.close();
  process.exit(0);
}
main().catch((e) => { console.error(e.message); process.exit(1); });
