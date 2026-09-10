/**
 * probe-privy.js — what is the Privy iframe actually showing, and is Turnstile blocking?
 */
import fs from "node:fs";
import puppeteer from "puppeteer-core";

const CHROME = "/usr/bin/google-chrome-stable";
const OUT = "/tmp/df-probe";
fs.mkdirSync(OUT, { recursive: true });

const browser = await puppeteer.launch({
  executablePath: CHROME, headless: "new",
  args: ["--no-sandbox", "--disable-setuid-sandbox", "--disable-dev-shm-usage"],
  defaultViewport: { width: 1440, height: 900 },
});
const page = await browser.newPage();
await page.setUserAgent("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36");

// log console + failed requests so we can see rejections
page.on("console", (m) => { const t = m.text(); if (/privy|captcha|turnstile|blocked|403|cloudflare/i.test(t)) console.log("  CONSOLE:", t.slice(0, 300)); });
page.on("requestfailed", (r) => console.log("  REQFAIL:", r.url().slice(0, 110), r.failure()?.errorText));
page.on("response", (r) => { if (r.status() >= 400) console.log("  HTTP", r.status(), r.url().slice(0, 110)); });

await page.goto("https://death.fun", { waitUntil: "domcontentloaded", timeout: 60000 });
await new Promise((r) => setTimeout(r, 8000));

// click the real Sign in button (main frame)
await page.evaluate(() => {
  const els = [...document.querySelectorAll("button")].filter((e) => e.offsetParent !== null);
  const hit = els.find((e) => (e.textContent || "").trim() === "Sign in");
  if (hit) hit.click();
});
console.log("clicked Sign in; waiting 15s for privy modal + captcha...");
await new Promise((r) => setTimeout(r, 15000));

for (const f of page.frames()) {
  if (f.url().startsWith("about:")) continue;
  console.log("\n" + "=".repeat(90));
  console.log("FRAME:", f.url().slice(0, 120));
  try {
    const dump = await f.evaluate(() => {
      const txt = (document.body?.innerText || "").trim();
      const inputs = [...document.querySelectorAll("input")].map((i) => ({
        type: i.type, ph: i.placeholder, name: i.name, vis: i.offsetParent !== null,
      }));
      const btns = [...document.querySelectorAll("button,[role=button],a")].map((b) => ({
        t: (b.textContent || "").trim().slice(0, 50), vis: b.offsetParent !== null,
      })).filter((b) => b.t);
      const cf = !!document.querySelector('iframe[src*="challenges.cloudflare"], [id*="turnstile"], .cf-turnstile');
      return { txt: txt.slice(0, 1500), inputs, btns, turnstile: cf, title: document.title };
    });
    console.log("  title:", dump.title, "| turnstile element present:", dump.turnstile);
    console.log("  visible text:\n" + dump.txt.split("\n").map((l) => "     " + l).join("\n"));
    console.log("  inputs:", JSON.stringify(dump.inputs));
    console.log("  elements:", JSON.stringify(dump.btns.slice(0, 25)));
  } catch (e) {
    console.log("  <cannot evaluate frame>:", String(e).slice(0, 200));
  }
}
await page.screenshot({ path: `${OUT}/privy.png`, fullPage: true });
console.log("\nscreenshot:", `${OUT}/privy.png`);
await browser.close();
