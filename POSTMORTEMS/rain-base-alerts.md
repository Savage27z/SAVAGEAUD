# Fresh Alerts — Rain $1M + Base Wallet Drain (Aug 30-31, 2026)

## Rain — $1M exploit, attacker traced to KYC'd services (0xVishnya)

0xVishnya's on-chain investigation (x.com/0xVishnya/status/2094019313980039305) traced
the Rain exploit (~$1M) and the attacker's funding trail, wallet by wallet:

- **13:38 UTC** — 0.0794667 ETH leaves `0x775028B2CE02844e8947905E4d655940a76cf559`
- **13:40** — lands on a fresh, one-job address `0xa1a15f1b0d4878873f2933573e4385ab1e4df25c`
- **13:40** — bridged into 1.78855 SOL → attacker wallet
  `FVNFzqAny8spWdPmYw6RQ9TkYa29ueFFiqCFD1gQnCEj`
- **16:56** — draining of the contract starts

The funding address has direct deposits/withdrawals with **seven KYC'd services**:
Binance, Bybit, HTX, MEXC, Cryptomus, BitPanda, Heleket — each with exact tx IDs in the
note. Lesson: for attribution work, the funding trail through regulated/CEX rails is
what turns "an address" into "a name" — same playbook we used for Sherwood/Drift
funding analysis. (Technical root cause of the Rain exploit itself wasn't in the note —
attribution-focused.)

## Base personal-wallet drain — victim's on-chain negotiation (Defimon Alerts)

DefimonAlerts flagged an on-chain message from a victim whose wallet was hacked on Base
(x.com/DefimonAlerts/status/2094182874220032067): asks the attacker to return 50%,
curious how it was done ("I did follow all security practices"). Relevant tx:
`0xfda9a2237ead9c72c05e580193506a1d0bf0c2ecb6ee4e9dcb9b109ac897c156` (basescan).

Lesson: personal-wallet drains (approve phishing, seed compromise, signature
requests) keep happening to people who "follow best practices" — and the on-chain
negotiation message pattern (like Drift's `0x0934faC4...` message) is now standard
recovery theater. For our work this is a reminder that the **app surface** (phishing,
approvals, malicious dApps) is the #1 vector for individual losses even when
protocols are sound.
