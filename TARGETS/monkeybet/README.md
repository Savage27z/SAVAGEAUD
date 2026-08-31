# MonkeyBet / NothingGuarantees — Audit Findings

**Target:** MonkeyBet put-option sales + RaiseController family, Robinhood Chain
**Audit date:** 2026-08-30 · **State pinned:** live on-chain
**Verdict:** 🟡 Informational — vault accounting is sound. Centralization + design observations only.

---

## What was checked

- Full source: MonkeyBet V1 + V2 (bytecode-diffed), RaiseController V3 (active) + V4 (older), RaiseToken V3 + V4, AllocationNFT
- Live on-chain state: all owners (eth_getCode), reserves, liabilities, raised totals, token balances, claim activity
- Version drift: V1 vs V2 bytecode + source diff; V3 vs V4 RC design diff
- Solvency: reserve == liability verified exactly (5,334.50 == 5,334.50)
- Reentrancy: CEI ordering traced on buy/redeem/contribute/claim/finalize

## The version-drift chase (resolved)

Hypothesis: two MonkeyBet deployments with different bytecode (11,236 vs 9,821 bytes) = a V1/V2 bug fix hiding in the diff.

**Result: only metadata URI handling changed** (`setURI` → per-tier `setTier0/1/2URI`). All vault logic identical. Not a finding.

The RaiseController pair (V3 active vs V4 older) is a real design evolution: V4 mints + `revokeMintingForever` with permissionless finalize; V3 pre-funds supply + burns excess with owner-gated finalize. Both are internally consistent; the V4 token's `setMinterOnce` one-time gate and V3's `setToken` one-time gate both close the wiring window correctly.

## Findings

### F1 — Docs claim multisig, all owners are EOAs (Medium centralization, docs-vs-on-chain mismatch)
Every owner in the family is a plain EOA (verified `eth_getCode` = 0 bytes):
- MonkeyBet owner `0xa499...1097`
- Active RaiseController ($218K) owner `0x64d5...0af`
- Older RaiseController owner `0x660f...b506`
- AllocationNFT owner `0x2104...28ef`

But the docs (in both RaiseController and MonkeyBet NatSpec) state the owner is *"the same multisig that controls TaxHook's treasury timelock."* On-chain reality contradicts the docs. Impact: a single compromised key controls $218K raised + $5.3K put reserve + pass airdrops + reserve sweeps. No timelock, no multisig on any deployed contract. **Worth reporting to the team as a centralization correction — either docs are stale or the deployments used the wrong key.**

### F2 — Protocol writes naked puts on its own token (High economic exposure, by design)
MonkeyBet sells puts on the same RaiseToken the controller distributes. Buyers pay 0.10–0.20 USDG premium; if RaiseToken trades below the buyback strike (0.80–1.05) at claim time, every holder exercises and drains the reserve (5,334 USDG). The reserve is exactly collateralized (no insolvency), but the treasury loses the entire reserve plus the premium economics invert. Classic "selling insurance on your own asset" concentration risk. Not a code bug — a design risk worth flagging to the team.

### F3 — Missing nonReentrant on buy()/redeem() (Informational, defense-in-depth)
Neither `buy()` nor `redeem()` carries a reentrancy guard. Both are protected by CEI ordering (state updated before external calls), and all tokens are standard ERC20s with no hooks (RaiseToken: ERC20Burnable, no callbacks; USDG: standard). `_mint` in `buy()` invokes `onERC1155Received` on a contract buyer AFTER state is committed — a malicious buyer contract could re-enter `buy()` but gets no advantage (fresh, legitimate purchase; reserve check still binds). No exploit found; recommend adding guards for robustness.

### F4 — 48h claim window then full sweep (Design note)
Holders get exactly 48 hours (hardcoded, not owner-adjustable) after a 90-day wait to redeem; after that, `sweepUnclaimed()` sends ALL remaining USDG + RaiseToken to treasury. A holder who misses the window loses everything to the owner. Documented in NatSpec, but aggressive — the owner is both the put writer AND the beneficiary of expired puts.

### F5 — AllocationNFT owner can mint unlimited passes up to maxSupply (Centralization)
`airdrop()` is owner-only with a `maxSupply` cap. The owner can mint passes to any wallet at any time — combined with F1 (EOA), a compromised key can mint passes then contribute through them. The maxSupply bounds the damage to the raise cap, and passes are burned on contribution. Standard for airdrop-gated raises.

## Accounting verification (live numbers)

- MB V2: USDG balance 5,334.50 == totalLiability 5,334.50 == Σ(buyback × units) ✓
- MB V2: 5,091 units × avg buyback ~1.048 ≈ liability ✓ (mix of tiers 0/1/2)
- RC V3: totalRaised 218,341.09 → tokensSold 218,341.09 × 10^12 units (18 vs 6 decimals, tokensPerUsdcUnit=1) → team 15% = 32,751 → supply 251,092.26 ✓ (RC holds 1,736 residual, treasury 33,275)
- RC V3: claims occurring Aug 30 (same day as audit) ✓
- No fee-on-transfer on any token ✓
- One-time gates (`setToken`, `setMinterOnce`) correctly prevent post-deploy wiring swaps ✓

## Bottom line

The vault/reserve accounting in this family is **genuinely well-engineered** — reserve ≥ liability is enforced at every step, CEI ordering is correct everywhere, one-time wiring gates are sound, and the version bumps hide no security fixes. The real story is **centralization**: docs promise a multisig, on-chain reality is single EOAs over $218K + the put reserve, and the protocol is economically short its own token via naked puts. Worth a team conversation; **no reportable exploit found.** Marked 🟡 Informational.
