# death.fun — auth blockade, contract trust model, and the reachable surface

**Date:** 2026-09-10
**Purpose:** record what is reachable from outside without a browser session, what was tried, and
why the last step in F04 requires one manual paste. Written so this is not re-derived.

---

## 1. The contract validates nothing — all logic is server-authoritative

`src/DeathFun.sol` read directly:

- `createGame(...)` (lines 168–215) checks **only** `block.timestamp <= deadline` and the server
  signature. `gameConfig` and `algoVersion` are opaque `string` parameters, stored verbatim into
  the struct (lines 208–209). No parsing, no bounds, no shape check.
- `cashOut(onChainGameId, payoutAmount, gameState, gameSeed, deadline, serverSignature)` takes
  **`payoutAmount` as a parameter** — the only check on it is `require(payoutAmount > 0, "PayoutZero")`
  (line 242). The amount is trusted from the server's signature.
- Full `grep` for `require|revert` across the contract shows no reference to `rowConfig`, `tiles`,
  or any board property. The `algoVersion` field is likewise never inspected.

**Consequence:** the on-chain contract is a signing/escrow shell. Every piece of game logic —
choosing the board, computing the payout, deciding whether a pick was fatal — happens off-chain
and is authorised by a signature. **There is no on-chain backstop that could catch a malformed
board.** So for F04, the server's pre-signing validation is the *only* defence, and the client is
the only place the shape of `rowConfig` is constrained at all (by a UI toast). That raises the
value of resolving F04 and is why one browser test is worth doing.

## 2. The auth blockade, precisely

Every game endpoint is cookie-authenticated — `credentials: "include"`, **no** `Authorization`
header — and returns `401 {"error":"missing jwt"}` **before any body parsing**. So the server's
`rowConfig` validation cannot be probed unauthenticated (verified: malformed bodies, `{}`, and
wrong-type bodies all return the same 401).

The session cookie is a Privy-issued JWT. Getting one without a browser was attempted five ways:

| Route | Result |
|---|---|
| Privy SIWE / wallet login over REST | **Disabled.** `POST https://auth.privy.io/api/v1/siwe/init` → `403 {"error":"Login with wallet not allowed","code":"disallowed_login_method"}`. Confirmed by the app's own public config: `wallet_auth = false`. |
| Privy email OTP over REST | **Enabled** (`email_auth = true`) but blocked: the endpoint requires a valid `privy-client-id` (a made-up one → `400 "Invalid app client ID"`), and `captcha_enabled = true` with `enabled_captcha_provider = "turnstile"` is enforced **server-side**, so a browser is required regardless. |
| Privy guest login | `guest_auth = false` |
| Privy OAuth (twitter/google/github/…) | all `false` |
| The PKCE flow in the bundle (`/api/v1/auth/nonce \| verify-signature \| token`) | Belongs to the third-party **Terminal** SDK and posts to `https://terminal-backend-six.vercel.app` with `scope: "read:stats"`. Not death.fun. (Explains the 404s previously seen on those paths.) |

Privy app config, read from the public `GET https://auth.privy.io/api/v1/apps/cm6txbwad00ikeoi9wu5wmi8p`
(requires a browser User-Agent; a plain Python UA gets Cloudflare `1010`):

```
wallet_auth = false        email_auth = true        guest_auth = false
passkey_auth = false       sms_auth = false         all *_oauth = false
captcha_enabled = true     enabled_captcha_provider = "turnstile"
embedded_wallet_config.create_on_login = "off"
external_wallets_for_signup_enabled = false
merge_accounts_by_email = true
```

**A note on the email path:** even if the captcha were cleared, `create_on_login = "off"` means an
email-only account gets **no wallet**, and with `wallet_auth = false` /
`external_wallets_for_signup_enabled = false` it could never link one — so such an account could
not place a bet at all. The email route was therefore never going to reach a playable game.

## 3. Turnstile genuinely cannot load from this environment

Root cause pinned down, because the earlier note ("needs IPv6") was right but under-evidenced:

- No global IPv6 on this host — only `::1` and a link-local `fe80::`. No default IPv6 route.
  `curl -6 https://ipv6.google.com` → `000`. Public IPv4 egress exists and works (`66.220.6.104`).
- `brunhild.challenges.cloudflare.com` (the asset host) is **IPv6-only**: AAAA
  `2606:4700::6812:1092`, no A record.
- That AAAA maps to Cloudflare IPv4 `104.18.16.146`, and the edge **does** serve a valid TLS cert
  for `brunhild` on IPv4 — but every candidate IPv4 returns **HTTP 522** (origin unreachable)
  over IPv4: `104.18.16.146`, `104.18.17.146`, `104.18.94.41`, `104.18.95.41`, `172.64.80.1`,
  `104.18.32.7`, `104.18.16.147`, `104.18.17.147`.
- Control: `challenges.cloudflare.com/turnstile/v0/api.js` works fine over IPv4 (HTTP 302).

So the origin is not dual-stacked and there is no IPv4 path. **No browser on this host can pass the
challenge, and the challenge is the app's deliberate anti-automation control — bypassing it is not
something this research should attempt.** The remaining path is a browser with IPv6: the operator's
or the reporter's own.

## 4. Other findings from probing the public surface

- **No source maps.** `/_next/static/chunks/<chunk>.js.map` → 404 for every chunk tried, including
  the app bundle, the mapper, and the constants module.
- **`/api/settings?key=<k>` is a public key-value store.** Only `banner_config` holds a value;
  `game_config`, `rowConfig`, `house_edge`, `min_tiles`, `max_tiles`, `death_race_config`, etc. all
  return `{"value":null}`. It does not expose server config, so **it yields no evidence about
  server-side validation** — the F04 question stays open.
- **Operational note (2026-09-10):** the `banner_config` value reads
  *"we are experiencing rpc issue causing game creation…"* — the operator currently has game
  creation degraded and has flagged it. Relevant to timing: a live create-game test may fail for
  reasons unrelated to `rowConfig`. Retry later if the probe returns an RPC/creation error rather
  than a validation error.
- Public without auth: `/api/game-balance/<gameType>` (pot balance), `/api/leaderboard`,
  `/api/challenges`, `/api/settings`. Authenticated: `/api/games/*`, `/api/users/*`,
  `/api/abstract/games/create` (401).

## 5. What this leaves

F04 cannot be closed from outside. The single remaining action is one console paste of
`disclosure/live-capture/rowconfig-probe.js` in a logged-in browser — **a `400` closes it, a `200`
opens it.** Everything else in this target is either verified (§F03) or already reported.

No mainnet state modified — every call was `eth_call` or a public `GET`. No funds moved.
