# Dice Protocol (DiceEntropy) — Robinhood Chain — Target README

**Status:** ✅ Phase 1 source review complete — 🟢/🟡 no critical findings, 4 observations

| | |
|---|---|
| Target | DiceEntropy `0xd8a0680e7699526b57140ed4eafdcc7219dc0a0c` — trustless commit-reveal randomness oracle (Pyth Entropy-derived, V2) |
| Chain | Robinhood Chain (4663) |
| Category | Randomness oracle / infra (non-DEX) |
| Source | ✅ Verified on Blockscout, **immutable** (no proxy), solc 0.8.24 — saved in `source/` |
| Activity | LIVE — ~416+ provider sequences consumed; reveals today (block 53,731,510) |
| Fees | 0.000025 ETH/request; accrued ≈ 0.006279 ETH (all held in contract) |
| stackaudit | T2 full scan 2026-07-25 (structural) |

## On-chain state (verified)
- defaultProvider = `0x8741b8a825644D9Ef18Faf2DAB5e9b47B900F2b6` (also the active revealWithCallback caller)
- admin = `0x4acd2c88a239a924e47fc4995114ca1bb0ca3cad` (slot0; separate from provider)
- vault = `0x918eaf0b2589710b0d85ef48c12a343e68263841` (slot2)
- fee 2.5e13 wei; refundDelayBlocks = 6; accruedFees == contract ETH balance
- Provider: currentCommitmentSeq 3 → endSequence ~416+ (chain mostly consumed; re-registration (admin `registerFor`) will be needed soon)

## Mechanism (Pyth Entropy model, V2-only)
Provider pre-generates a hash chain (commitment = final hash, registered/anchored). User requests randomness: sends their own secret `userRandomNumber` (only its hash stored), pays exact flat fee, gets sequence number. Reveal: user + provider reveal contributions; random = keccak(userRandomness, providerRandomness[, blockHash=0]). Contract validates both against the request-time commitment (provider value must hash N times to the anchored commitment; user value must hash to their stored commitment). Provider's commitment advances on reveal. Stuck requests refundable after `refundDelayBlocks`. Callback to consumer optional w/ gas limit + retry on failure.

**Unbiased if either party honest** — provider can't bias (user's commit hidden at request); user can't bias (provider's chain value locked).

## Findings (see findings.md)
F1 refund-vs-withdraw race on shared accruedFees pool; F2 no-retry callback path when gasLimit=0; F3 requester-only reveal (liveness); F4 single flat fee exact-payment UX.

## Verdict
🟢 Clean with 4 low/info observations. Core commit-reveal math and state machine match the Pyth-derived design; no bias/theft path found. Fee scale is tiny (~$0.06/req) so F1/F3 real-world impact is small; F2 matters for downstream apps that set gasLimit=0.
