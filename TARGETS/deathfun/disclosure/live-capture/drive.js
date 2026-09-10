/**
 * drive.js — step the UI forward and report what's on screen, so the login path can be
 * driven without guessing. Prints visible interactive elements + all frame URLs, and
 * screenshots each step.
 */
import fs from "node:fs";
import puppeteer from "puppeteer-core";
import { Wallet, JsonRpcProvider, getBytes } from "ethers";

const args = process.argv.slice(2);
const opt = (n, d) => { const i = args.indexOf(n); return i >= 0 && args[i + 1] ? args[i + 1] : d; };
const OUT = opt("--out", "/tmp/df-drive");
const CLICKS = (opt("--click", "") || "").split("|").filter(Boolean);
const CHROME = "/usr/bin/google-chrome-stable";
fs.mkdirSync(OUT, { recursive: true });

const wallet = new Wallet(fs.readFileSync("/root/.keys/df-test.key", "utf8").trim());
const provider = new JsonRpcProvider("https://api.mainnet.abs.xyz/", undefined, { staticNetwork: true });

const browser = await puppeteer.launch({
  executablePath: CHROME, headless: "new",
  args: ["--no-sandbox", "--disable-setuid-sandbox", "--disable-dev-shm-usage", "--window-size=1440,900"],
  defaultViewport: { width: 1440, height: 900 },
});
const page = await browser.newPage();
await page.setUserAgent("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36");

async function nodeCall(op, payload) {
  if (op === "accounts") return [wallet.address];
  if (op === "rpc") return provider.send(payload.method, payload.params);
  if (op === "personal_sign") {
    const raw = payload[0];
    const bytes = typeof raw === "string" && raw.startsWith("0x") ? getBytes(raw) : raw;
    const sig = await wallet.signMessage(bytes);
    console.log("   >>> SIGNED personal_sign:\n" + String(raw).slice(0, 600));
    return sig;
  }
  if (op === "signTypedData") {
    let td = payload[0]; if (typeof td === "string") td = JSON.parse(td);
    const { domain, types, message } = td; delete types.EIP712Domain;
    console.log("   >>> SIGNED typed data");
    return wallet.signTypedData(domain, types, message);
  }
  return null;
}
await page.exposeFunction("__nodeCall", nodeCall);
await page.evaluateOnNewDocument(fs.readFileSync(new URL("./wallet-shim.js", import.meta.url), "utf8"));

async function report(label) {
  const info = await page.evaluate(() => {
    const vis = (el) => el.offsetParent !== null && el.getBoundingClientRect().width > 0;
    const els = [...document.querySelectorAll("button,a,[role=button],input,[data-testid]")].filter(vis);
    return {
      url: location.href,
      texts: els.map((e) => ({
        tag: e.tagName.toLowerCase(),
        t: (e.textContent || e.getAttribute("aria-label") || e.placeholder || "").trim().slice(0, 70),
        id: e.id || e.getAttribute("data-testid") || "",
      })).filter((x) => x.t),
      iframes: [...document.querySelectorAll("iframe")].map((f) => f.src).filter(Boolean),
      hasEth: typeof window.ethereum !== "undefined",
    };
  });
  console.log(`\n=== ${label} ===`);
  console.log("  url:", info.url, "| window.ethereum:", info.hasEth);
  console.log("  MAIN FRAME visible clickable:");
  for (const t of info.texts.slice(0, 24)) console.log(`     [${t.tag}] ${t.t}${t.id ? "  {" + t.id + "}" : ""}`);

  // every frame, because the Privy login options live in a cross-origin iframe
  for (const f of page.frames()) {
    if (f === page.mainFrame()) continue;
    let els = [];
    try {
      els = await f.evaluate(() => {
        const vis = (el) => el.offsetParent !== null && el.getBoundingClientRect().width > 0;
        return [...document.querySelectorAll("button,a,[role=button],input")]
          .filter(vis)
          .map((e) => ({
            tag: e.tagName.toLowerCase(),
            t: (e.textContent || e.getAttribute("aria-label") || e.placeholder || e.type || "").trim().slice(0, 70),
          }))
          .filter((x) => x.t);
      });
    } catch (e) { els = [{ tag: "?", t: `<cross-origin or detached: ${String(e).slice(0, 60)}>` }]; }
    console.log(`  FRAME ${f.url().slice(0, 80)}`);
    for (const t of els.slice(0, 20)) console.log(`     [${t.tag}] ${t.t}`);
  }
  await page.screenshot({ path: `${OUT}/${label.replace(/[^a-z0-9]+/gi, "_")}.png` });
  return info;
}

/** Click by text in the main frame OR any iframe. */
async function clickAnywhere(needle) {
  for (const f of page.frames()) {
    try {
      const hit = await f.evaluate((n) => {
        const vis = (el) => el.offsetParent !== null;
        const els = [...document.querySelectorAll("button,a,[role=button],input")].filter(vis);
        const hit = els.find((e) => {
          const s = (e.textContent || e.getAttribute("aria-label") || e.placeholder || "").toLowerCase();
          return s.includes(n.toLowerCase());
        });
        if (hit) { hit.click(); return (hit.textContent || "").trim().slice(0, 60); }
        return null;
      }, needle);
      if (hit) return { where: f.url().slice(0, 60), text: hit };
    } catch { /* cross-origin/detached */ }
  }
  return null;
}

await page.goto("https://death.fun", { waitUntil: "domcontentloaded", timeout: 60000 });
await new Promise((r) => setTimeout(r, 9000));
await report("01-loaded");

for (const c of CLICKS) {
  console.log(`\n>>> clicking: "${c}"`);
  const res = await clickAnywhere(c);
  console.log("   clicked:", res ? `${res.text}  (in ${res.where})` : "NOT FOUND");
  await new Promise((r) => setTimeout(r, 6000));
  await report(`after-${c.replace(/[^a-z0-9]+/gi, "_")}`);
}

console.log("\nwallet address:", wallet.address);
await browser.close();
