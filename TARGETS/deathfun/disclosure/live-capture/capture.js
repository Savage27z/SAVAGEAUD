/**
 * death.fun F01 — reachability capture.
 *
 * Purpose: log in as an ordinary user with the throwaway test key, play one real game
 * end-to-end, and record EVERY request/response/websocket frame. Then hand the log to
 * analyze.js, which searches for any server signature handed to the client.
 *
 * Pre-committed falsification rule (see README): if a 65-byte signature or a raw calldata
 * blob appears in any response, the finding is LIVE and F01's retraction was wrong.
 *
 * Usage:
 *   node capture.js --out /tmp/df-capture --observe          # load page, record, do not click
 *   node capture.js --out /tmp/df-capture --connect          # + connect wallet (SIWE)
 *   node capture.js --out /tmp/df-capture --play             # + create/advance/cash out a game
 *   node capture.js --out /tmp/df-capture --browse-only      # no wallet shim (interception dry run)
 */

import fs from "node:fs";
import path from "node:path";
import puppeteer from "puppeteer-core";
import { Wallet, JsonRpcProvider, getBytes, hexlify } from "ethers";

const RPC = process.env.DF_RPC || "https://api.mainnet.abs.xyz/";
const CHAIN_ID = 2741;
const CHROME = process.env.CHROME_BIN || "/usr/bin/google-chrome-stable";

const args = process.argv.slice(2);
const flag = (n, d = false) => (args.includes(n) ? true : d);
const opt = (n, d) => {
  const i = args.indexOf(n);
  return i >= 0 && args[i + 1] ? args[i + 1] : d;
};

const OUT = opt("--out", "/tmp/df-capture");
const KEY_FILE = opt("--key", "/root/.keys/df-test.key");
const OBSERVE = flag("--observe");
const CONNECT = flag("--connect");
const PLAY = flag("--play");
const BROWSE_ONLY = flag("--browse-only");
const HEADFUL = flag("--headful");
const NAV_TIMEOUT = Number(opt("--nav-timeout", "60000"));

fs.mkdirSync(OUT, { recursive: true });
const LOG = path.join(OUT, "capture.jsonl");
const TRACE = path.join(OUT, "trace.log");
const out = fs.createWriteStream(LOG, { flags: "a" });
const trace = fs.createWriteStream(TRACE, { flags: "a" });

let seq = 0;
function record(kind, obj) {
  const entry = { seq: ++seq, t: new Date().toISOString(), kind, ...obj };
  out.write(JSON.stringify(entry) + "\n");
  const brief = obj.url || obj.method || obj.note || "";
  trace.write(`[${entry.seq}] ${kind} ${String(brief).slice(0, 160)}\n`);
  return entry;
}
function note(msg) {
  record("note", { note: msg });
  console.log(`  · ${msg}`);
}

const trunc = (v, n = 20000) =>
  typeof v === "string" && v.length > n ? v.slice(0, n) + `…[TRUNCATED ${v.length}]` : v;

async function main() {
  console.log(`death.fun F01 reachability capture`);
  console.log(`  out:      ${OUT}`);
  console.log(`  chrome:   ${CHROME}`);
  console.log(`  mode:     ${BROWSE_ONLY ? "browse-only (no wallet)" : "wallet shim"}`
    + `${CONNECT ? " + connect" : ""}${PLAY ? " + play" : ""}`);

  let wallet = null;
  let keyHex = null;
  if (!BROWSE_ONLY) {
    if (!fs.existsSync(KEY_FILE)) {
      console.error(`\n!! key file not found: ${KEY_FILE}`);
      console.error(`   create it (chmod 600, OUTSIDE the repo) with the throwaway key, or pass --browse-only.`);
      process.exit(2);
    }
    keyHex = fs.readFileSync(KEY_FILE, "utf8").trim();
    if (!keyHex.startsWith("0x")) keyHex = "0x" + keyHex;
    wallet = new Wallet(keyHex);
    console.log(`  wallet:   ${wallet.address}`);
    console.log(`  balance:  ${(Number(await new JsonRpcProvider(RPC).getBalance(wallet.address)) / 1e18).toFixed(6)} ETH`);
  }

  const browser = await puppeteer.launch({
    executablePath: CHROME,
    headless: HEADFUL ? false : "new",
    args: [
      "--no-sandbox", "--disable-setuid-sandbox", "--disable-dev-shm-usage",
      "--window-size=1440,900", "--disable-blink-features=AutomationControlled",
      `--lang=en-US`,
    ],
    defaultViewport: { width: 1440, height: 900 },
  });
  note("browser launched");

  const page = await browser.newPage();
  await page.setUserAgent(
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36");

  // ---- node-side signing + RPC so no key ever enters the page
  if (!BROWSE_ONLY) {
    const provider = new JsonRpcProvider(RPC, undefined, { staticNetwork: true });
    await page.exposeFunction("__nodeCall", async (op, payload) => {
      try {
        if (op === "accounts") return [wallet.address];
        if (op === "rpc") {
          const { method, params } = payload;
          const r = await provider.send(method, params);
          record("rpc", { method, params: trunc(JSON.stringify(params), 2000), result: trunc(JSON.stringify(r), 4000) });
          return r;
        }
        if (op === "personal_sign") {
          // params: [message, address]  (message is hex)
          const raw = payload[0];
          const bytes = raw.startsWith("0x") ? getBytes(raw) : raw;
          const sig = await wallet.signMessage(bytes);
          record("wallet-sign", { what: "personal_sign", message: trunc(String(raw), 4000), signature: sig });
          return sig;
        }
        if (op === "eth_sign") {
          const sig = await wallet.signMessage(getBytes(payload[1]));
          record("wallet-sign", { what: "eth_sign", message: trunc(String(payload[1]), 4000), signature: sig });
          return sig;
        }
        if (op === "signTypedData") {
          let td = payload[0];
          if (typeof td === "string") td = JSON.parse(td);
          const { domain, types, message } = td;
          delete types.EIP712Domain;
          const sig = await wallet.signTypedData(domain, types, message);
          record("wallet-sign", { what: "signTypedData", typedData: trunc(JSON.stringify(td), 6000), signature: sig });
          return sig;
        }
        if (op === "sendTransaction") {
          const tx = { ...payload[0] };
          if (tx.gas) tx.gasLimit = tx.gas;
          delete tx.gas;
          if (!tx.chainId) tx.chainId = CHAIN_ID;
          const sent = await wallet.sendTransaction({ ...tx, provider: null, ...(await provider.getFeeData()).toJSON?.() || {} });
          record("wallet-send", { tx: trunc(JSON.stringify(tx), 4000), hash: sent.hash });
          return sent.hash;
        }
        return null;
      } catch (e) {
        record("wallet-error", { op, error: String(e).slice(0, 500) });
        throw new Error(String(e));
      }
    });
    const shim = fs.readFileSync(new URL("./wallet-shim.js", import.meta.url), "utf8");
    await page.evaluateOnNewDocument(shim);
    note("wallet shim injected (key stays on the node side)");
  }

  // ---- network interception: request + response bodies
  page.on("request", (req) => {
    const rt = req.resourceType();
    if (rt === "font" || rt === "image" || rt === "media") return;
    record("req", {
      method: req.method(), url: req.url(), resourceType: rt,
      postData: trunc(req.postData(), 20000),
      headers: req.headers(),
    });
  });
  page.on("response", async (res) => {
    const url = res.url();
    const ct = (res.headers()["content-type"] || "");
    const interesting = /json|text\/plain|javascript/.test(ct) && !/\.js(\?|$)/.test(url);
    if (!interesting) return;
    let body = null;
    try { body = await res.text(); } catch (e) { body = `<unreadable: ${e}>`; }
    record("res", { status: res.status(), url, contentType: ct, body: trunc(body) });
  });
  page.on("console", (m) => {
    const t = m.text();
    if (t.length < 2000) record("console", { note: `${m.type()}: ${t}` });
  });
  page.on("pageerror", (e) => record("pageerror", { note: String(e).slice(0, 1000) }));

  // websocket frames via CDP
  try {
    const cdp = await page.createCDPSession();
    await cdp.send("Network.enable");
    cdp.on("Network.webSocketFrameReceived", (e) =>
      record("ws-in", { note: trunc(e.response?.payloadData, 20000) }));
    cdp.on("Network.webSocketFrameSent", (e) =>
      record("ws-out", { note: trunc(e.response?.payloadData, 20000) }));
    cdp.on("Network.webSocketCreated", (e) => record("ws-open", { url: e.url }));
    note("websocket frame capture enabled");
  } catch (e) {
    note(`ws capture unavailable: ${e}`);
  }

  // ---- go
  note("navigating to https://death.fun");
  await page.goto("https://death.fun", { waitUntil: "domcontentloaded", timeout: NAV_TIMEOUT });
  await new Promise((r) => setTimeout(r, 8000));
  note(`loaded, title=${JSON.stringify(await page.title())}`);

  const shimState = await page.evaluate(() => ({
    hasEthereum: typeof window.ethereum !== "undefined",
    ready: !!window.__walletReady,
    chainId: window.ethereum?.chainId ?? null,
    walletLog: (window.__walletLog || []).length,
  })).catch(() => ({}));
  record("shim-state", { note: JSON.stringify(shimState) });
  note(`shim state: ${JSON.stringify(shimState)}`);

  if (CONNECT || PLAY) {
    note("attempting connect-wallet");
    // click anything that looks like a connect / login button
    const clicked = await page.evaluate(() => {
      const rx = /connect|log ?in|sign ?in|sign ?up|wallet/i;
      const els = [...document.querySelectorAll("button,a,[role=button]")];
      const hit = els.find((e) => rx.test((e.textContent || "").trim()) && e.offsetParent !== null);
      if (hit) { hit.click(); return (hit.textContent || "").trim().slice(0, 60); }
      return null;
    });
    note(`connect button: ${clicked ?? "none found"}`);
    await new Promise((r) => setTimeout(r, 10000));
    record("url-after-connect", { url: page.url() });
  }

  if (PLAY) {
    note("PLAY not yet implemented — see README; needs a human-confirmed selector pass first");
  }

  await page.screenshot({ path: path.join(OUT, "final.png"), fullPage: true }).catch(() => {});
  await new Promise((r) => setTimeout(r, 2000));

  const walletLog = await page.evaluate(() => window.__walletLog || []).catch(() => []);
  for (const w of walletLog) record("wallet-shim-log", { note: JSON.stringify(w).slice(0, 4000) });

  await browser.close();
  out.end(); trace.end();
  console.log(`\ncapture written: ${LOG}`);
  console.log(`human-readable:  ${TRACE}`);
  console.log(`now run:  node analyze.js --in ${OUT}`);
}

main().catch((e) => {
  console.error("\nFATAL:", e);
  record("fatal", { note: String(e).slice(0, 2000) });
  out.end(); trace.end();
  process.exit(1);
});
