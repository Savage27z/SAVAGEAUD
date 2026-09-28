# TayDex — findings so far

Target: `taydex.fun` — "TAYDEX — Prediction exchange on Base"
Class: **UMA-oracle prediction market, ERC-1155 positions, ERC-4337 accounts** (NOT a casino)
Date: 2026-09-28 · Passes 1–24 · All evidence read-only (public GETs/explorer APIs, `eth_call`,
`eth_getCode`, `eth_getStorageAt`, plus local anvil-fork simulation). Nothing broadcast, no key used.

## Verdict

**CLOSED — no exploitable vulnerability found.** Four leads raised, all resolved:

| # | lead | outcome |
|---|---|---|
| 1 | app ABI vs deployed bytecode | **PROVEN** — real integration/version divergence (24 functions; `cancelMarket`→`voidMarket`; `buy` 8 fields vs 10) |
| 2 | `sweepLeftover` ungated | **CLOSED, not a vuln** — `dest` is the fixed feeRecipient; no theft possible |
| 3 | signature not bound to the actor | **FALSIFIED** — replay test: original actor passes, foreign addresses rejected `"bad sig"` |
| 4 | deployed trade path `buy`/`sell` | **NOT A VULN** — actor-bound by the same mechanism |

The signature scheme is **consistently correct**: a proper EIP-712 domain
(`TaydexMarket` / v1 / chainId 8453 / bound to the contract address), a `msg.sender`-keyed nonce
gate, and caller-bound signatures on both `createMarket` and `buy`. Privileged setters are
correctly `Ownable`-gated. On the reachable surface this contract is **well built**; the problems
are on the deployment/versioning side, not in the crypto.

**Not assessed** (behind the unverified source): the resolution/dispute economics, the payout
math, and `sell`/`claimRefund` (same signer+nonce pattern as `buy`, so likely bound, but not
tested — stated as an inference, not a result). **Explorer verification status remains
UNCONFIRMED, not "unverified"** — the check is broken (positive control USDC→`is_verified=None`).

**Centralisation properties worth stating in any report** (design, not bugs): no on-chain AMM —
every fill and every market parameter is server-signed, so pricing integrity rests entirely on the
signer key; `owner()` is a bare EOA with no multisig or timelock, and it can rotate the signer
(storage slot 6, not immutable) and `rescueToken`-style sweep leftovers.

---

## 0. Addresses

| role | address | note |
|---|---|---|
| core market contract | `0x3ade22fa1ef5ac75437a3734d91ba588e54875dd` | **hardcoded in the live bundle**, 20,788 B runtime |
| AA account factory | `0x4be0ddfebca9a5a4a617dee4dece99e7c862dceb` | 8,469 B |
| AA account factory (twin) | `0x85e23b94e7f5e9cc1ff78bce78cfb15b81f0df00` | 8,469 B, byte-identical to the above |
| ERC-4337 EntryPoint v0.7 | `0x0000000071727de22e5e9d8baf0edac6f37da032` | 16,035 B |
| ERC-4337 EntryPoint v0.6 | `0x5ff137d4b0fdcd49dca30c7cf57e578a026d2789` | 23,689 B |
| USDC (Base) | `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` | matches `usdc()` |

**`0x3ade22fa…` is NOT a proxy.** EIP-1967 impl/beacon/admin, EIP-1822 and the OZ-v4 slot are all
zero; first runtime bytes are a plain Solidity dispatcher
(`608060405234801561000f575f80fd5b…`, `PUSH0` present → solc ≥ 0.8.20). **Logic is in the contract.**

---

## FINDING 1 — the live frontend targets a contract version that is not deployed

**Severity: HIGH (product does not function; users can be charged a creation fee for
markets that cannot then be traded).** Not a Solidity vulnerability — a deployment/integration
divergence.

### Evidence

**(a) The address and ABI are bound together in the shipped client bundle**
(`_next/static/chunks/84326-ab0d74cd4f455ba0.js`, module `59652`):

```js
l = "0x3ade22fa1ef5ac75437a3734d91ba588e54875dd"      // hardcoded literal
T = () => !!l
function c(){ if(!l) throw Error("NEXT_PUBLIC_TAYDEX_CONTRACT_ADDRESS is not set…");
              return getContract({ client, chain, address: l, abi: o }) }
```
`chain` = Base (8453); `usdc` in the same module = `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913`.
The ABI `o` is the same array saved to `abi_core.json` (118 entries). **This is not a testnet
artifact** — it is the live contract's address, on mainnet, with a live USDC reference.

**(b) 24 of the ABI's 69 functions do not exist in the deployed bytecode.** Method:
linear EVM disassembly (PUSH4 immediates) of the runtime, and independently a raw-byte search.
Both agree.

Absent: `buy(...)`, `sell(...)`, `pause()`, `unpause()`, `paused()`, `pendingOwner()`,
`acceptOwnership()`, `pushReferral`, `pushReferralBatch`, `claimReferral`,
`claimReferralBatch`, `getReferralAccrued`, `marketReferralAccrued`, `rescueToken`,
`setMarketCreatorFeeShare`, `voidMarket`, `resolutionKind`, `KIND_*`, `OUTCOME_DRAW`.
Present (45): `createMarket`, `claim`, `claimCreatorFees`, `dispute`, `resolveMarket`,
`resolveSingleBinary`, `resolveDispute`, `sweepLeftover`, `setSigner`, `setFeeRecipient`,
`setConfig`, `setDisputeFee`, `userShares`, `markets`, `getMarket`, `getOption`, `nonces`,
`eip712Domain`, Ownable, ERC-1155 transfers.

**(c) Falsifiable control — 34/35 predictions correct** (`pass11`). I predicted, per view
function, `present ⇒ returns` and `missing ⇒ reverts`, then called them:

- all 23 predicted-present views returned;
- 11 of 12 predicted-missing views reverted (`KIND_*`, `OUTCOME_DRAW`, `OUTCOME_UNRESOLVED`,
  `paused`, `pendingOwner`, `resolutionKind`, referral accruals);
- the single mismatch, `balanceOf(address,uint256)`, is a **known limitation of my census**:
  its selector `0x00fdd58e` has a leading zero byte, so solc emits a `PUSH3`+shift comparison
  rather than `PUSH4`. It returns 0 → it exists. Blind spot identified, not a contract anomaly.

**(d) Direct live call test with an internal control** (`pass13`). Same encoder, same call
style: `claim` and `dispute` (known-present) revert with a **body reason** ("no shares",
"resolved") → the selector decoded and the body ran. `buy(...)`, `sell(...)`, `pause()`,
`pushReferral(...)`, `rescueToken(...)` all revert **empty, with no data** → the selector
matched nothing and there is no permissive fallback. The contrast isolates function existence
from any flaw in my encoder.

**(e) Version-rename smoking gun.** Deployed-only selector `0x7c16cd9e` resolves to
`cancelMarket(uint256)`; calling it live returns `OwnableUnauthorizedAccount(address)`
(0x118cdaa7) → **the deployed contract implements `cancelMarket`, owner-gated.** The app's ABI
instead declares `voidMarket(uint256)`, which is absent from the bytecode. Same function,
renamed between versions.

### Why it matters
The app's trade path (`buy`/`sell`) is sent to `0x3ade22fa…`, which does not implement it, and
the call reverts. Market **creation** does work on the deployed version (markets 1–27 exist),
and creation costs **5 USDC** (`marketCreationFee()` = 5,000,000) plus ≥50 USDC per option of
creator liquidity (`minLiquidityPerOption()` = 50,000,000). So a user can pay to create a market
and fund it with real USDC, on a contract where **nobody can ever take the other side**.
`marketCreatorFees(1)` = 0 is consistent with no trading having ever settled.

### Caveats (honest)
- I cannot see the team's intent: this is equally explainable as "frontend deployed ahead of a
  contract upgrade" or "stale hardcoded address". Both leave the **live** product unable to
  trade.
- Requires confirmation that no updated deployment exists elsewhere; the bundle contains no
  second core address (only the two AA factories and the two EntryPoints).
- **Not yet verified on the team's own site as a user** — I have not funded a wallet or
  attempted a trade from the UI. Do not overstate: the claim is "as coded, this call cannot
  succeed against this address", which is proven; "trading is broken for every user" is a
  strong inference from it.

### CORRECTION (fork phase, pass16) — the contract *can* trade, the app just can't call it
`TradeExecuted(uint256,uint16,address,bool,uint8,uint256,uint256,uint256,uint256)` **is present
as a live event topic** in the deployed code, and `SignerUpdated(address)` with it. So the
deployed version does support trading through its own entry point(s) — it simply does not expose
`buy`/`sell`. The precise claim is therefore:

> the app's trade calls target functions absent from the deployed contract, **and** the app's
> ABI is not the deployed contract's ABI (they differ on 24 functions and rename
> `cancelMarket` → `voidMarket`).

That is a real integration/version divergence. It is **not** the same as "the contract cannot
trade", and the earlier "users pay 5 USDC for a market nobody can trade" line must be softened:
the contract's own interface could trade the market; the shipped UI cannot reach it. Nobody is
calling that interface directly in practice — 17 of 27 markets were created by a single address
and 3 by the signer key itself — but that is an observation about adoption, not a proven loss.

---

## FINDING 2 — `sweepLeftover` is callable by anyone  **CLOSED — NOT A VULNERABILITY**

`pass8`: calling `sweepLeftover(uint256,uint16)` from a random address with no role did **not**
revert with `OwnableUnauthorizedAccount`; it reverted with body reasons (`"not resolved"`,
`"no leftover"`). Auth modifiers execute *before* the function body, so a gated function always
reverts with the auth selector regardless of arguments. These did not — so `sweepLeftover` really
is unguarded.

**But the guard is unnecessary, and the impact is nil.** The function takes no address argument,
and the sweep transactions show where the money actually goes:

```
market 1 sweep (0xc46c02d0…): 40.279064 USDC  0x3ade22fa… -> 0xc0b085c1… (feeRecipient)
market 3 sweep (0xfa5acd42…): 50.000000 USDC  0x3ade22fa… -> 0xc0b085c1… (feeRecipient)
```

`dest` is the **fixed `feeRecipient`**, not `msg.sender`. An unprivileged caller can therefore
only push leftover dust to the project's own fee address. **No theft is possible.**
(All 24 sweeps in the contract's history were made by the owner, which is also why my pass17 probe
found "no leftover" on every market — he had already swept them all.)

Severity if reported: **informational / nuisance** at most. Closed.

## FINDING 3 — "the signed structs don't bind the actor"  **FALSIFIED — the signature IS bound**

Original hypothesis: the calldata tuple for `createMarket`/`buy`/`sell` contains no address field
(`referrer` is someone else), and `nonces` is a per-address mapping starting at 0, so every fresh
wallet shares nonce 0 — making a signature usable by any address in that collision class.

Live signing domain (`eip712Domain()`, decoded):
`fields=0x0f  name="TaydexMarket"  version="1"  chainId=8453  verifyingContract=0x3ade22fa…`
Cached domain separator recovered **directly from the runtime code** and confirmed:
`0xa4b938fc46dcb5ce581218f2adcdc0fd3284b0cf8eecdf218bab38407c061598`
= `keccak(TYPE_HASH ‖ keccak("TaydexMarket") ‖ keccak("1") ‖ chainId ‖ address)` — all five
components independently found in the bytecode. (An earlier "MISS" was my own mislabel: I had
prepended `\x19\x01`, which belongs to the *digest*, not the domain.)

### How it was resolved — a real signed payload, replayed from foreign addresses

I did **not** need to reconstruct the signing scheme. Markets 7/8/9 were created by the signer key
itself, so real `createMarket` transactions exist carrying genuine signatures from the live
signer. I pulled one off-chain (`0xc2d946af…`, nonce=0) and replayed it on my fork, after
discovering that anvil can wind the clock backward (`anvil_setTime` + `evm_mine`) so the
`endDate past` / `expired` gates stop masking the deeper checks:

| caller | caller's nonce | result |
|---|---|---|
| original sender, nonce **restored** to the payload's value | 0 | `Error("ERC20: transfer amount exceeds balance")` |
| original sender, nonce **left advanced** (control) | 5 | `Error("bad nonce")` |
| fresh address A | 0 | `Error("bad sig")` |
| fresh address B | 0 | `Error("bad sig")` |

The original actor passes **both** the nonce gate and the signature check — it reaches the token
transfer. The two fresh addresses carry the *same nonce value* as the payload, so the nonce gate
passes for them as well, and they are rejected **at the signature check**.

**Same payload, same nonce, only the caller differs → the accepted caller is the one the signature
was issued to. The signature is bound to the actor. The hypothesis is falsified.**

Two things learned:
- The `nonce` gate **is** keyed on `msg.sender` (the control row proves it: same signer, wrong
  nonce → `"bad nonce"`). My per-address-nonce observation was correct.
- **The ABI parameter list is not the full set of signed inputs.** `createMarket`'s tuple carries
  no address, yet verification is caller-specific — so `msg.sender` enters the digest outside the
  struct. Reading the calldata tuple and concluding "no actor binding" was the flaw in the
  original reasoning. **A missing field in the calldata is not evidence that the actor is unbound.**

Check order observed: param/date validation (`endDate past`, `expired`) → `bad nonce` →
`bad sig` → token transfer.

So signatures are correctly bound to *(name, version, chainId, contract)* — no cross-chain or
cross-contract replay — **and** to the caller, as the replay above shows.

The signed structs (from the app ABI; the calldata tuples are authoritative for shape):

```
createMarket((uint64 endDate, uint128[] fundingPerOption, uint16 creatorFeeShareBps, uint256 nonce, uint256 deadline), bytes sig)
buy ((uint256 marketId, uint16 optionIndex, uint8 outcome, uint256 usdcIn, uint256 sharesOut, uint256 fee, address referrer, uint256 referralFee, uint256 nonce, uint256 deadline), bytes sig)
sell((uint256 marketId, uint16 optionIndex, uint8 outcome, uint256 sharesIn, uint256 usdcOut, uint256 fee, address referrer, uint256 referralFee, uint256 nonce, uint256 deadline), bytes sig)
```

`referrer` is a third party; no field is the actor — yet the caller is bound. So `msg.sender` is
mixed into the digest separately from the struct. **The original flaw in this analysis was
inferring the binding from the parameter list alone.**

Retained observations, all confirmed rather than assumed:
- **`nonces` is a per-address mapping at storage slot 14** — probed via
  `storage[keccak(address ‖ slot)]`: 3 for the signer, 0 for fresh addresses. The gate keys on
  `msg.sender` (proven by the control row).
- **`signer` is a storage variable (slot 6), not an immutable** (`usdc` *is* immutable, 16 sites in
  code) — so the owner can rotate the signing key without a migration. Still a real centralisation
  property, and still the key that authorises every signed action on the money path.
- **No `CreateMarket` typehash constant exists in the runtime.** All 48 32-byte immediates are
  accounted for: event topics (matched against the ABI's event signatures — `MarketCreated`,
  `MarketResolved`, `DisputeResolved`, `Disputed`, `Claimed`, `CreatorFeesClaimed`,
  `ConfigUpdated`, `FeeRecipientUpdated`, `SignerUpdated`, `TradeExecuted`, ERC-1155 transfers),
  internal error strings, domain components, addresses, and the secp256k1 bound. A 105-candidate
  brute-force over plausible struct names also found nothing. Consistent with a custom digest
  rather than a standard `keccak256("Name(...)")` typehash — and the thing that hid `msg.sender`
  from a params-only reading.

**Centralisation note (not a bug):** the server dictates the fill (`sharesOut`/`usdcOut`/`fee`)
and even `creatorFeeShareBps`; there is **no on-chain AMM**, so pricing integrity rests entirely
on the signer key `0xb5932a150f48dcd5b299702dd0091670368ea4c9` and on the bare-EOA owner that can
rotate it. Worth stating in any report; it is a design property, not a vulnerability.

**Client-side note:** because the *server* builds and signs these messages, the struct definition
is nowhere in the bundle — the frontend relays an opaque signature it cannot verify or explain to
the user. Recorded as a trust/UX observation.

## FINDING 4 — the deployed trade path (`buy`/`sell`/`claimRefund`)  **NOT A VULNERABILITY — actor-bound**

The deployed contract *does* trade, through entry points the app ABI does not declare. Named from
openchain.xyz and confirmed by decoded calldata + logs:

```
0x9aa63277  buy((uint256,uint16,uint8,uint256,uint256,uint256,uint256,uint256),bytes)       x12
0x285204f0  sell((uint256,uint16,uint8,uint256,uint256,uint256,uint256,uint256),bytes)
0x7c9aea76  claimRefund((uint256,uint256,uint256,uint256),bytes)                             x4
```

Decoded `buy` fields: `(marketId, optionIndex, outcome, usdcAmount, shares, fee, nonce, deadline)`.
**Note: 8 fields, where the app's ABI declares 10** (`referrer`, `referralFee` were added in the
newer version) — a third independent confirmation of the version divergence in Finding 1, and a
reason the app's trade calldata would be mis-shaped even if the selector existed.

`TradeExecuted(uint256 marketId, uint16 optionIndex, address user, bool isBuy, uint8 outcome,
uint256 usdcAmount, uint256 shares, uint256 fee, uint256 nonce)` — every economics field
(`usdcAmount`, `shares`, `fee`) is **server-signed**, so the fill is entirely off-chain, as with
`createMarket`.

### Actor-binding test on buy()

The first attempt was inconclusive for a stateful reason worth recording: `createMarket` and `buy`
both check `require(!resolved, "resolved")` **before** the nonce/signature gates, and every market
is now resolved — so every real `buy` payload bounced with `"resolved"` regardless of caller.
Fixed by making a market live again on the fork:

1. **Located the `markets` mapping** by exact packing fingerprint rather than guessing.
   `markets` base slot = **12**; `storage[keccak(pad(1)‖pad(12))]` =
   `0x09c4 0001 0000000069f13998 729939ac…80a4` = `feeBps | numOptions | endDate | creator`
   — an exact match, so the layout is **verified**. (Note: Solidity packs the **first-declared**
   variable into the **lowest-order** bytes; my first attempt had it high-first and found nothing.)
2. **The flag slot is struct slot + 1**, and read `0x…ffff01` = `winningOptionIndex(-1 → 0xffff) << 8
   | resolved(1)` — which independently confirms the `int16` flag packing and that market 2's
   `-1` means *voided*, not *unresolved*.
3. Cleared `resolved` → `getMarket(2)` then read `resolved=False, winning=0`.

Then, same 2×2 at the same nonce value (3):

| caller | nonce | result |
|---|---|---|
| original actor, nonce restored | 3 | `Error("ERC20: transfer amount exceeds balance")` |
| original actor, nonce advanced | 10 | `Error("bad nonce")` |
| fresh address A | 3 | `Error("bad sig")` |
| fresh address B | 3 | `Error("bad sig")` |

The original actor clears both gates and reaches the token transfer; the fresh addresses carry the
payload's own nonce, pass the nonce gate, and are rejected at the **signature** check.

**`buy()` is bound to its actor, by the same mechanism as `createMarket`. No replay.**

Also established: `encodeTokenId(marketId, optionIndex, outcome) = marketId << 16 | optionIndex << 8
| outcome` (verified against real logs: `1638401` = 25<<16|1, `1769472` = 27<<16|0).

### One genuine third-party trade exists
Of the 12 `buy` calls, 11 are from operator addresses, but **one is from `0x22845bd1…`** — a real
outside buyer, market 25, 1.3 USDC in. Worth noting as the sole evidence of non-operator use.

---

## FORK-ATTACK PHASE (mandatory per `CLAUDE.md`) — what was run

Fork: `anvil --fork-url https://base-rpc.publicnode.com --fork-block-number 51923920 --port 8546
--chain-id 8453`. Confirmed as mine via `anvil_nodeInfo` (chainId 8453, correct fork URL) and by
the runtime size matching the live contract byte-for-byte at 20,788 B.

> Process pitfall hit and worth keeping: two **other** forks already held ports (a Robinhood
> Chain fork on :8545, a Monad fork on :8555). My first anvil silently failed to bind and I spent
> a pass reading *a stranger's fork* — `eth_getCode` returned "historical state … is not
> available", which was the only clue. **Always confirm with `anvil_nodeInfo` that
> `chainId`/`forkUrl` are yours before trusting a single read.**

### Storage layout (recovered, not guessed)

| slot | holds |
|---|---|
| 2 | `69` (packed flag / small counter) |
| 3 | `owner` |
| 6 | **`signer`** — mutable, so rotatable by the owner |
| 7 | `feeRecipient` |
| 8 | `marketCreationFee` = 5,000,000 |
| 9 | `minLiquidityPerOption` = 50,000,000 |
| 10 | `disputeFee` = 20,000,000 |
| 11 | `nextMarketId` = 28 |
| 14 | **`nonces` mapping** (per-address) |
| — | `usdc` is **immutable** (in code, 16 sites) |

### Attacks attempted

| attack | method | result |
|---|---|---|
| `sweepLeftover` ungated payout | probe all 27 markets × options from `0x…deadbeef`; execute a success if any | **0/27 succeeded** — all body-revert (`no leftover` ×24, `not resolved` ×3). Impact unproven. |
| signature replay / actor impersonation | replay a **real** signer-signed `createMarket` payload (lifted from chain, from the signer's own market creation) on the fork from foreign addresses, with the clock rewound via `anvil_setTime` + `evm_mine` so the date gates don't mask deeper checks | **RAN — hypothesis FALSIFIED.** Original actor passes nonce + signature (reaches the token transfer); two fresh addresses at the *same* nonce value are rejected `"bad sig"` → the signature is bound to the caller. See Finding 3. |
| replay across nonce-colliding addresses | fresh address with nonce 0, payload nonce 0 | **nonce gate PASSED** (0 == 0) then rejected at the signature check → the collision class is real but harmless |
| nonce gate keying | original actor with the payload's nonce vs an advanced nonce | `"bad nonce"` when advanced → the gate keys on `msg.sender` |
| unprivileged calls on privileged setters | `eth_call` from a random address on `setSigner`, `setFeeRecipient`, `setConfig`, `setDisputeFee`, `resolveMarket`, `resolveSingleBinary`, `resolveDispute` | correctly revert `OwnableUnauthorizedAccount` |
| `cancelMarket` | live call | owner-gated (`0x118cdaa7`) — confirms the deployed version's name |

### Market activity (real on-chain state)

27 markets, **all resolved**. Creators: `0xfe6a5322…` created **17**, `0x729939ac…` 2,
`0xd4a8716d…` 1, and **`0xb5932a15…` — the signer key itself — created 3** (markets 7, 8, 9).
Markets 2, 7, 8 carry `winningOptionIndex = -1` (never finalised). `marketCreatorFees(1)` = 0.
This profile — one address and the operator's own signer key creating nearly all markets — reads
as test/operator activity, not user adoption. It is evidence about adoption, **not** a charge.

---

## Live configuration (read-only)

| field | value |
|---|---|
| `owner()` | `0xef869234bb919bbde0f44d98912e87d1ce0463f8` — **single EOA**, no multisig, no timelock |
| `signer()` | `0xb5932a150f48dcd5b299702dd0091670368ea4c9` — hot session key |
| `feeRecipient()` | `0xc0b085c1a5514d8541adcb105aa7e6e8e5bc74ed` |
| `usdc()` | `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` |
| `nextMarketId()` | 28 → 27 markets created |
| `MAX_OPTIONS()` | 32 |
| `OUTCOME_YES/NO` | 0 / 1 |
| `marketCreationFee()` | 5,000,000 (5 USDC) |
| `minLiquidityPerOption()` | 50,000,000 (50 USDC) |
| `disputeFee()` | 20,000,000 (20 USDC) — matches the site's "staking 20 USDC" |

**Privilege surface:** `setSigner`, `setFeeRecipient`, `setConfig`, `setDisputeFee`,
`resolveMarket`, `resolveSingleBinary`, `resolveDispute` all revert
`OwnableUnauthorizedAccount` from an unprivileged caller → correctly owner-gated.
`claim` → `"no shares"`, `claimCreatorFees` → `"not creator"`, `dispute` → `"resolved"` → body
gates present.

**`setSigner()` is the master key**: it authorises every signed action on the money path, and
the owner that can call it is a bare EOA. Centralisation note, not a bug.

---

## Method / tooling notes (for reuse)

- **`urllib`'s default User-Agent is WAF-blocked (`HTTP 403`) by these public Base RPCs while
  `curl` succeeds.** Silent, total failure that looks like "the chain returned nothing". Always
  send a browser UA; always read `HTTPError.read()` so the JSON-RPC error surfaces.
- **Selector censuses must use linear EVM disassembly, and even then have one blind spot:**
  selectors with a leading zero byte are emitted as `PUSH3`+shift, not `PUSH4`. Verify with a
  behavioural prediction, not just code scanning.
- **Prove a function is absent by contrast, not by absence:** call a known-present function with
  the same encoder and show it decodes (body reason) while the subject reverts empty.
- **`4byte.directory` resolutions are guesses** — confirm with a live call. `cancelMarket` was
  confirmed by its `OwnableUnauthorizedAccount` revert.
- **Explorer verification status remains UNCONFIRMED, not "unverified"**: the check is broken —
  the positive control (USDC on Base) also reads `is_verified=None`. No verdict used.

## Artifacts
`abi_core.json` (118 entries) · `pass8_guards.json` · `pass9_selectors.json` ·
`pass12_deployed_iface.json` · `deployed_only_selectors.json` · `pass1_bundle.json` ·
`pass2_contracts.json` · `raw/` (21 chunks, 1,479,512 B — primary evidence) ·
scripts `_taydex_pass3.py` … `_taydex_pass13.py`
