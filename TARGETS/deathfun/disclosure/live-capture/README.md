# F01 reachability capture — does a player ever receive a signature?

One question, one test. **Does the death.fun backend ever hand a player a signature?**

Everything else about F01 is already settled: the two missing checks are confirmed on a fork of the
real deployed contract, and the backend is the only party that can produce a valid note. This test
answers the remaining question — whether an ordinary player can obtain one.

## The rule, fixed before the test runs

Stated up front so the result can't be reinterpreted after the fact:

| Outcome | Meaning |
|---|---|
| A 65-byte signature, a death.fun function selector, or a `signature`-shaped field appears **in any response** | **F01 is LIVE.** The retraction was wrong. Escalate to Critical, re-issue the disclosure, notify the team immediately. |
| Nothing appears across a full game lifecycle | Reachability conclusion holds. ~95% → ~99%. Report ships as written. |

`analyze.js` implements that rule mechanically — it searches only data the client *received*, and
flags the three shapes above. It is written to be able to find us wrong; the detection patterns
include a plain 65-byte hex match, so a signature under any field name is still caught.

## Files

| File | Role |
|---|---|
| `capture.js` | launches Chrome, injects the wallet shim, records every request/response/WS frame to `capture.jsonl` |
| `wallet-shim.js` | injected EIP-1193 provider backed by the test key, so the app's normal connect/SIWE path works |
| `analyze.js` | the search + the verdict, written mechanically per the rule above |
| `package.json` | `puppeteer-core` + `ethers` |

## Why a browser, and why a wallet shim

Auth is 100% Privy — the app's own `/api/v1/auth/nonce|verify|token` routes 404, and the bundle
uses `loginWithSiwe`, `getAccessToken`, `addSessionSigners`, `createDelegatedAction`. Privy
embedded wallets are created inside the app, so we cannot log in as one with a raw key. What we
*can* do is present ourselves as an **external wallet** user, which is a first-class Privy path:
`wallet-shim.js` installs a MetaMask-shaped `window.ethereum` before any app script runs, the app's
"connect wallet" flow drives it, and SIWE signs with the test key.

The key never enters the page. The shim forwards signing to Node via `page.exposeFunction`, so the
private key stays in one file on disk (`/root/.keys/df-test.key`, `chmod 600`, **outside the repo**).

Installing the shim *after* page scripts start does not work — the app caches its provider early.
`evaluateOnNewDocument` is what makes this reliable.

## Run

```bash
export LD_LIBRARY_PATH=/opt/chrome-libs/usr/lib/x86_64-linux-gnu   # Chrome on this box needs it

node capture.js --out /tmp/df-capture --browse-only   # dry run: no wallet, just prove interception works
node capture.js --out /tmp/df-capture --observe       # load as a wallet user, record, click nothing
node capture.js --out /tmp/df-capture --connect       # + connect wallet (SIWE)
node analyze.js --in /tmp/df-capture
```

## What this test can and cannot prove

**Can:** that no signature reaches the client on any path a player can trigger — across every
request, response and websocket frame of a real session.

**Cannot:** that the server never signs for some path no user can reach. The backend is closed
source; this test observes the wire, not the server. ~99% is the ceiling for outside-in evidence
and the writeup says so rather than rounding up to certainty.

## Risk

None to the protocol. This is normal use of a public app with our own funds. No exploit is
attempted; if an increase-bet control appears it is logged and the run stops before pressing it
unless explicitly told otherwise. Only gas is spent — stakes return on cash-out.
