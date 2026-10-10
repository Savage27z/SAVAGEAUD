# Daemon (obol.sh) — Findings

Target: `obol.sh` Daemon collection + sale, **Robinhood Chain (4663)**.
Audited **live** — sale opened 2026-10-10 18:00 UTC, `sold = 329` at block 85218989.
Source: Sourcify v2 `exact_match` on all three project contracts; none is a proxy.
(Front door for this chain's explorer is Cloudflare-walled — Sourcify was the route.)

**Verdict: no permissionless fund-theft found. Three real defects, all reached by
reasoning from the deployed bytecode + live state, none needing a privileged key to
observe.** The money layer is unusually careful — I verified the eight claims it makes
about itself on-chain rather than reading them off the page (see *Verified clean* below).

---

## F1 — A daemon's agent can drain the wallet's ETH past the daily limit the holder set

**Impact: Medium · Likelihood: Medium · Class: accounting / trust asymmetry**

The whole point of the constitution is that a holder can leave an agent key running
without trusting it: *"an agentfile it runs, can propose changes to, but can never use to
loosen what it's allowed to do."* The contract's own comment states the invariant:

> *"every agent call is measured: the account's outflow of the tracked dollar (USDG) **and
> of ETH** must stay inside the **per-call and per-day caps**"* — `DaemonAccount.sol:32-34`

The code implements only half of that. `Constitution` (`DaemonAccount.sol:45-51`) has
`maxPerCall`, `maxPerDay` and `maxEthPerCall` — **there is no `maxEthPerDay` field**, and
the ETH path never touches the daily counter:

```solidity
// DaemonAccount.sol:151-157  (agent path, general calls)
if (!targetAllowed[c.configuredBy][to]) revert TargetNotAllowed(to);
if (value > c.maxEthPerCall) revert EthOverCap(value, c.maxEthPerCall);   // per-call only
uint256 before = IERC20(dollar).balanceOf(address(this));
++state;
result = _call(to, value, data);
uint256 afterBal = IERC20(dollar).balanceOf(address(this));
if (afterBal < before) _spend(before - afterBal, c);                      // USDG only
```

`_spend` (`:118-124`) is the only thing that writes `spentToday`, and the ETH figure is
never passed to it. So a compromised agent key can send `maxEthPerCall` per call and
repeat until the wallet's ETH is empty — the daily cap is never reached because ETH is
never counted. The same shape applies to the `approve` branch (`:142-149`), which is
per-call capped for the dollar but does not increment `spentToday` either, so the daily
dollar bound is also reachable in `maxPerCall`-sized steps.

**Reachable by an outsider? No —** it needs the holder to have constituted an agent and
allowlisted a target, *and* the agent key to be compromised. That is exactly the scenario
the limits exist to bound, so the defect is that the declared protection is weaker than
the holder is told: the loss ceiling is the wallet's whole ETH balance, not `maxPerDay`.

**Evidence**
- `Targets/obol/src/account__src__DaemonAccount.sol:45-51, 118-124, 142-158` (verified source).
- Live `constitution()` on both sold wallets returns all-zero limits with `state = 1`, i.e.
  the agent path is not yet armed (activation is 24h after the sale). The gap is in the
  code that will run.
- No `maxEthPerDay` exists in the ABI: `constitution() -> (address,address,uint128,uint128,uint128)`.

**Fix** — add `maxEthPerDay` and accumulate ETH outflow into `spentToday`, and run
`_spend` on the approve path. Or state the weaker guarantee in the docs.

---

## F2 — `price()` and `buy()` panic once the collection sells out

**Impact: Low · Likelihood: High (certain at sellout) · Class: boundary / numerical**

```solidity
function currentBand() public view returns (uint256) {
    return (sold * BANDS) / supply;          // :63-65  -> can return BANDS (10)
}
function price() public view returns (uint256) {
    return bandPrice[currentBand()];         // :67-69  -> bandPrice[10]
}
```

`bandPrice` is `uint256[BANDS]` (`:27`), i.e. indices 0..9. When the last daemon sells,
`sold == supply`, so `currentBand()` returns `10` and `bandPrice[10]` is an
out-of-bounds read → `Panic(0x32)`. `price()` is the function the site and any integrator
read, so it reverts permanently after sellout; `buy()` reverts with a panic instead of the
intended `NotForSale`. No funds are at risk — it is a broken view + a rude error.

**Reachable by an outsider? Yes** — trivially: it triggers automatically at the 10,048th sale
and then anyone calling `price()` gets a revert.

**Evidence** — `DaemonSale.sol:20, 27, 63-69`; band boundaries verified (`1005×9 + 1003 = 10048`).

**Fix** — `sold >= supply ? BANDS - 1 : (sold * BANDS) / supply`, or a separate sold-out flag.

---

## F3 — The rarity promise is not enforceable: the commitments live in a mutable web page

**Impact: Medium · Likelihood: Medium · Class: trust / off-chain provenance**

The page sells the look as a fair lottery:

> *"Top, colours, shoes, casing, phosphor, face, hat — fixed and committed before the mint.
> Until a number sells it shows the same unrevealed spin, so nobody can pick the rare ones."*
> trait table `sha256 0e3d7907…` · seed `sha256 db9c5f24…`

None of that is anchored anywhere the publisher cannot change:

- `tokenURI` → `https://obol.sh/d/<n>/os` (`DaemonNFT.baseUri`). The art, and therefore
  every daemon's rarity, is served from a domain the publisher controls and can change at
  any time, for any token, after the sale.
- The two `sha256` strings exist **only** as text on that same page. Neither the collection
  nor the sale stores a hash — I read both contracts' full storage/immutable sets
  (`supply`, `owner`, `baseUri`, `collectionUri` for the NFT) and there is no commitment.
- Because the seed is chosen by the publisher *before* its hash is published, the publisher
  can grind candidate seeds off-chain, pick the one that makes chosen tokenIds rare, then
  publish that hash. The commitment stops anyone changing the seed *after* publication; it
  does not stop the publisher selecting it.

So *"nobody can pick the rare ones"* reduces to trusting SHYGUY LLC. A buyer cannot verify
it, before or after the sale.

**Reachable by an outsider?** Not applicable — this is buyer-facing trust, not a theft.

**Evidence** — `DaemonNFT.sol:14, 31-37` (baseUri, no setters); `sourcify_summary.json` +
`meta/collection.json` storage/immutables; site text captured in `site/index.html`.

**Fix** — anchor the trait-table hash and (later) the seed hash on-chain before the sale
(one `bytes32` setter that freezes at `opensAt`), pin the art to content-addressed storage,
or derive the seed from a future block hash.

---

## F4 — The 90% is the buyer's to withdraw, so the effective price is 10%

**Impact: informational · Class: economic design**

Every daemon wallet is owned by the NFT holder (`owner()` = `ownerOf()` live), and
`execute` gives the holder unrestricted control. Live proof: the wallets for tokens 0 and 1
— both sold — hold **0 ETH** with `state = 1`, i.e. the buyer already withdrew. This is
correct behaviour (`"Whoever holds the NFT is the owner and can do anything"`), but it means
*"90% of what you pay goes into it"* describes a balance the buyer can empty one
transaction later. Anything built on the premise that a daemon "has money" (marketplaces
pricing the endowment, the agent's own budget) should treat the balance as decorative.
Same for the agent limits: they are only as durable as the holder leaving funds in place.

**Evidence** — `DaemonAccount.sol:127-131, 89-93`; live `eth_getBalance` on
`0x0490414a…`/`0x049b7975…` = 0, `state() = 1`.

---

## F5 — Exact-price match means band-boundary races revert instead of selling

**Impact: Low · Likelihood: Medium · Class: UX / MEV**

`if (msg.value != p) revert WrongPrice(msg.value, p)` (`:80`). This is the *safe* direction —
a buyer can never be charged more than they sent, which is better than the usual slippage
bug — but a band flip between signing and mining (1,005 sales per band) reverts the
purchase. Frames it as a design note, not a defect: consider `price <= maxPrice` with a
refund, plus a deadline.

**Evidence** — `DaemonSale.sol:79-80`.

---

## Verified clean (the eight claims the project makes, checked against chain state)

| Claim | How it was checked | Result |
|---|---|---|
| Prices fixed at deployment, 1.3× per band | read `bandPrice[0..9]` | **exact**: 0.01 → 0.10604499373 ETH; no rounding drift |
| 90% to the daemon's wallet, 10% to the treasury | decoded 92 real `Bought` logs | **exact** on every one; `toWallet+toTreasury == price` |
| "The sale holds nothing between purchases" | `eth_getBalance(sale)` | **0.000000000000 ETH** |
| Nobody can change the split or the treasury | constructor args + immutables decoded from runtime bytecode | all immutable; `treasury` = the Safe, `walletBps` = 9000 |
| Each daemon's wallet follows the NFT | `account.owner()` vs `nft.ownerOf()` for tokens 0,1 | **match** (impl reads `ownerOf` live) |
| A daemon cannot be bought twice / sold without moving | `balanceOf(sale) == supply - sold` | **9719 == 9719**, drift 0 |
| Treasury receives exactly 10% | treasury balance vs `sold` | **0.329 ETH == 329 × 0.001** |
| No admin over the collection | full ABI + source | no mint, burn, pause, or metadata setter after deploy |

Also confirmed: the sale's `EIP-3009` typehash matches the canonical
`TransferWithAuthorization` keccak (`cast keccak`), USDG on RHC implements 3009
(`authorizationState` responds), and `isValidSignature` correctly refuses a signature that
recovers to `address(0)` — a guard implementations of this pattern often miss.

## Fork attack phase — run on an anvil fork of chain 4663

`anvil --fork-url https://rpc.mainnet.chain.robinhood.com --chain-id 4663 --auto-impersonate`
(`TARGETS/_obol_fork.py`). The chain-id is not cosmetic: `DaemonAccount.owner()` returns
`address(0)` unless `block.chainid` matches the id baked into the account's ERC-6551 footer,
so a fork on any other id would silently "prove" the wallet has no owner.

| # | Attack | Result |
|---|---|---|
| A | **F2 sellout panic** — set `sold = supply` (slot 11) and read `price()` | **REPRODUCED.** `sold=10047` → `currentBand=9`, `price=0.10604499373 ETH`; `sold=10048` → `currentBand=10`, `price()` reverts **panic: array out-of-bounds access (0x32)** |
| B | **F1 agent ETH drain** — holder arms agent with `maxPerCall=1 USDG`, `maxPerDay=1 USDG`, `maxEthPerCall=0.005 ETH`; agent calls `execute` 5× | **REPRODUCED.** wallet **1.000 → 0.975 ETH**, payee **+0.025 ETH**, and **`spentToday()` stayed `0`**. 0.025 ETH moved against a stated 1-USDG/day ceiling — the daily cap does not exist for ETH |
| B2 | approve path vs the daily counter — 3 × `execute(dollar, approve(spender, 1 USDG))` | **`spentToday` still 0** — approvals never reach `_spend` |
| C | **wallet takeover** — pre-create an unsold daemon's account from an arbitrary EOA, then use it | **BLOCKED.** `account.owner()` = the sale, `nft.ownerOf()` = the sale; attacker `execute()` reverts |
| D | gates — wrong value / already sold / before `opensAt` | **ALL BLOCKED** (`WrongPrice`, `NotForSale`, `NotOpen`) |
| E | **x402: does USDG consult ERC-1271?** (open question 1) | **YES — the mechanism is real.** See below |

### E is a real result, not a formality

The account's whole "selling skills over x402" story needs USDG to ask the *account*
(a contract) to sign. Tested with a **zero-filled signature**, which no ECDSA check can
accept:

- digest **pre-approved** by the account → USDG reverts **`InsufficientFunds()` (0x356680b7)** —
  i.e. it passed the signature gate and failed only on balance (the account holds no USDG);
- same call, nonce **never approved** → USDG reverts **`InvalidSignature()` (0x8baa579f)**.

Two outcomes from the same garbage signature, decided only by the account's approval, is
exactly the behaviour of an ERC-1271 check on a contract signer. It also independently
confirms the account's `paymentDigest` is correct — USDG's own digest matched the approved
one, or we would have seen `InvalidSignature()` in the first case.

**Consequence for severity:** because x402 genuinely works, the agent's caps are load-bearing
— which is what makes F1 (a bypassable daily ceiling) worth fixing rather than cosmetic.

## Open questions

1. ~~Does USDG honour ERC-1271 for EIP-3009?~~ **RESOLVED — yes, proven on the fork (E). The
   USDG verified sources contain no `isValidSignature`/`SignatureChecker` at all and the
   proxy dispatches unknown selectors with `0x800ab12c`, so the 3009 facet is not in the
   published source set; the behavioural test is the evidence.**
2. **Not yet exercised: the agent path on a *live* daemon.** Activation is 24h after the
   sale (Sun 11 Oct 18:00 UTC) and every daemon wallet I sampled has an empty constitution.
   F1 was therefore proven on a fork with the holder acting exactly as the UI would.
3. **Reentrancy through `buy()` was reasoned, not run.** The buyer never gets control during
   the transaction (the NFT move has no hook, the wallet's `receive()` is empty, the treasury
   is a Safe), so there is no callback to reenter from — but a contract-buyer harness was not
   written. Low value: `sold` increments before any external call and each `buy` demands its
   own full payment, so even a successful reentry gains nothing.
4. Name collision worth a buyer's attention: this is **not** Obol Network (the DVT project at
   obol.tech). Different entity — `SHYGUY LLC`, design credited to Chad Neal.
