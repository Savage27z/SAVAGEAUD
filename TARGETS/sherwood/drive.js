#!/usr/bin/env node
// CDP driver — zero-dep (native WebSocket, node >=22)
// Usage:
//   node drive.js open                    -> create target, print id
//   node drive.js setup <url>             -> register stub + navigate in ONE session
//   node drive.js eval <expr>             -> evaluate in page, print JSON result
//   node drive.js click <selector> [text] -> click matching element
//   node drive.js alltext                 -> dump innerText of body
//   node drive.js shot <path>             -> screenshot png
//   node drive.js wait <ms>
const fs = require("fs");
const path = require("path");

const CDP = "http://127.0.0.1:9222";
const TARGET_FILE = path.join(__dirname, "cdp_target");
const STUB = fs.readFileSync(path.join(__dirname, "stub.js"), "utf8").replace(
  "__SIGNER_ADDR__",
  "0x21fc67258Dd145C0C39bd87B3ECa9C2508A48F65"
);

async function targets() {
  const r = await fetch(CDP + "/json/list");
  return r.json();
}
async function newTarget(url) {
  const r = await fetch(CDP + "/json/new?url=" + encodeURIComponent(url || "about:blank"), { method: "PUT" });
  return r.json();
}

class CDPConn {
  constructor(wsUrl) {
    this.ws = new WebSocket(wsUrl);
    this.id = 0;
    this.pending = new Map();
    this.ws.onmessage = (ev) => {
      const m = JSON.parse(ev.data);
      if (m.id && this.pending.has(m.id)) {
        const { resolve, reject } = this.pending.get(m.id);
        this.pending.delete(m.id);
        if (m.error) reject(new Error(JSON.stringify(m.error)));
        else resolve(m.result);
      }
    };
  }
  open() {
    return new Promise((res) => (this.ws.onopen = res));
  }
  send(method, params = {}) {
    const id = ++this.id;
    return new Promise((resolve, reject) => {
      this.pending.set(id, { resolve, reject });
      this.ws.send(JSON.stringify({ id, method, params }));
    });
  }
  close() {
    try { this.ws.close(); } catch (e) {}
  }
}

async function connect(targetId) {
  const list = await targets();
  const t = list.find((x) => x.id === targetId) || list[0];
  if (!t) throw new Error("no target");
  const c = new CDPConn(t.webSocketDebuggerUrl);
  await c.open();
  return { conn: c, t };
}

async function main() {
  const [cmd, arg1, arg2] = process.argv.slice(2);
  let conn;
  switch (cmd) {
    case "open": {
      const t = await newTarget("about:blank");
      fs.writeFileSync(TARGET_FILE, t.id);
      console.log("target", t.id);
      break;
    }
    case "setup": {
      const targetId = fs.readFileSync(TARGET_FILE, "utf8").trim();
      ({ conn } = await connect(targetId));
      await conn.send("Page.enable");
      await conn.send("Runtime.enable");
      await conn.send("Page.addScriptToEvaluateOnNewDocument", { source: STUB });
      await conn.send("Page.navigate", { url: arg1 });
      await new Promise((r) => setTimeout(r, 4000));
      const evalr = await conn.send("Runtime.evaluate", {
        expression: `({ hasEthereum: typeof window.ethereum === 'object', addr: window.ethereum ? window.ethereum.selectedAddress : null, title: document.title, url: location.href })`,
        returnByValue: true,
      });
      console.log(JSON.stringify(evalr.result.value));
      conn.close();
      break;
    }
    case "eval": {
      const targetId = fs.readFileSync(TARGET_FILE, "utf8").trim();
      ({ conn } = await connect(targetId));
      const r = await conn.send("Runtime.evaluate", {
        expression: arg1,
        returnByValue: true,
        awaitPromise: true,
      });
      if (r.exceptionDetails) console.log("EXC", JSON.stringify(r.exceptionDetails).slice(0, 300));
      else console.log(JSON.stringify(r.result.value));
      conn.close();
      break;
    }
    case "click": {
      const targetId = fs.readFileSync(TARGET_FILE, "utf8").trim();
      ({ conn } = await connect(targetId));
      const sel = JSON.stringify(arg1);
      const r = await conn.send("Runtime.evaluate", {
        expression: `(() => { const el = document.querySelector(${sel}); if (!el) return 'NOELEM'; el.click(); return 'CLICKED'; })()`,
        returnByValue: true,
      });
      console.log(JSON.stringify(r.result.value));
      conn.close();
      break;
    }
    case "alltext": {
      const targetId = fs.readFileSync(TARGET_FILE, "utf8").trim();
      ({ conn } = await connect(targetId));
      const r = await conn.send("Runtime.evaluate", {
        expression: `document.body ? document.body.innerText.slice(0, 4000) : 'NOBODY'`,
        returnByValue: true,
      });
      console.log(JSON.stringify(r.result.value));
      conn.close();
      break;
    }
    case "shot": {
      const targetId = fs.readFileSync(TARGET_FILE, "utf8").trim();
      ({ conn } = await connect(targetId));
      const r = await conn.send("Page.captureScreenshot", { format: "png" });
      fs.writeFileSync(arg1, Buffer.from(r.data, "base64"));
      console.log("shot", arg1, r.data.length);
      conn.close();
      break;
    }
    case "wait": {
      await new Promise((r) => setTimeout(r, parseInt(arg1, 10) || 1000));
      console.log("waited");
      break;
    }
    default:
      console.log("unknown cmd", cmd);
  }
  process.exit(0);
}

main().catch((e) => {
  console.error("ERR", e.message);
  process.exit(1);
});
