# TayDex — findings so far

Target: `taydex.fun` — "TAYDEX — Prediction exchange on Base"
Class: **UMA-oracle prediction market, ERC-1155 positions, ERC-4337 accounts** (NOT a casino)
Date: 2026-09-28 · Passes 1–13 · All evidence read-only (public GETs, `eth_call`, `eth_getCode`, `eth_getStorageAt`)

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

## FINDING 2 — `sweepLeftover` reached its body from an unprivileged address  **OPEN**

`pass8`: calling `sweepLeftover(uint256,uint16)` from a random address with no role did **not**
revert with `OwnableUnauthorizedAccount`; it reverted with body reasons — `"not resolved"`
(market 2) and `"no leftover"` (market 1). Auth modifiers execute *before* the function body,
so a gated function always reverts with the auth selector regardless of arguments. These did
not. `sweepLeftover` appears to be **callable by anyone**.

`LeftoverSwept(uint256 marketId, uint16 optionIndex, address dest, uint256 amount)` — the
function takes no address argument, so `dest` is derived internally (likely `msg.sender`).

**Fork result (pass17) — impact UNPROVEN, lead stays open.** On the fork I probed
`sweepLeftover(marketId, optionIndex)` for **all 27 markets × their options** as
`0x…deadbeef`. **0 succeeded. All 27 reverted with body reasons: 24 × `"no leftover"`,
3 × `"not resolved"`.** No market currently holds sweepable dust, so no payout could be
demonstrated. The absent guard is established; the *impact* is not. **Not a reportable finding
in this state.** To close it: instrument a fork market into a leftover state (or obtain source
to read what `dest` is), then re-run.

## FINDING 3 — the signed structs bind an address, but never the actor  **OPEN**

Live signing domain (`eip712Domain()`, decoded):
`fields=0x0f  name="TaydexMarket"  version="1"  chainId=8453  verifyingContract=0x3ade22fa…`
Cached domain separator recovered **directly from the runtime code** and confirmed:
`0xa4b938fc46dcb5ce581218f2adcdc0fd3284b0cf8eecdf218bab38407c061598`
= `keccak(TYPE_HASH ‖ keccak("TaydexMarket") ‖ keccak("1") ‖ chainId ‖ address)` — all five
components independently found in the bytecode. (An earlier "MISS" was my own mislabel: I had
prepended `\x19\x01`, which belongs to the *digest*, not the domain.)

So signatures are correctly bound to *(name, version, chainId, contract)* — no cross-chain or
cross-contract replay. The gap is in the structs:

```
createMarket((uint64 endDate, uint128[] fundingPerOption, uint16 creatorFeeShareBps, uint256 nonce, uint256 deadline), bytes sig)
buy ((uint256 marketId, uint16 optionIndex, uint8 outcome, uint256 usdcIn, uint256 sharesOut, uint256 fee, address referrer, uint256 referralFee, uint256 nonce, uint256 deadline), bytes sig)
sell((uint256 marketId, uint16 optionIndex, uint8 outcome, uint256 sharesIn, uint256 usdcOut, uint256 fee, address referrer, uint256 referralFee, uint256 nonce, uint256 deadline), bytes sig)
```

`referrer` is someone else. **No field is the actor**, so the only thing binding a signature to
the wallet that submits it is the `nonce`. Live reads: `nonces(<fresh random>)` = 0 for both
sampled addresses, `nonces(signer)` = 3, `nonces(owner)` = 0. A per-address nonce starting at 0
means every fresh wallet shares the same nonce value on its first action — the binding is a
collision class, not an identity.

Also by design: the server dictates the fill (`sharesOut`/`usdcOut`/`fee`) and even
`creatorFeeShareBps`; there is **no on-chain AMM**, so pricing integrity rests entirely on the
signer key `0xb5932a150f48dcd5b299702dd0091670368ea4c9`.

**OPEN:** exploitability cannot be settled without the contract source or a fork test — whether
the on-chain check is `nonces[msg.sender] == p.nonce` decides it. Fork test is the next step.
Exploitability also depends on observing a victim's signature before it lands (Base's mempool
is not freely observable, which cuts against the practical severity). **Do not report this as a
vulnerability until the fork test runs.**

**Fork result (pass16/17) — partially probed, still OPEN, and here is exactly what is now known:**

- **`nonces` is a per-address mapping at storage slot 14.** Established by probing
  `storage[keccak(address ‖ slot)]` across slots 0–15: slot 14 returns 3 for the signer and 0
  for fresh addresses. So the mapping is keyed by *address* — but I could not read the bytecode
  well enough to prove the key is `msg.sender` rather than the recovered signer.
- **The deployed `createMarket` has no typehash constant.** All 48 32-byte immediates in the
  runtime are now accounted for: event topics (matched against the ABI's event signatures —
  `MarketCreated`, `MarketResolved`, `DisputeResolved`, `Disputed`, `Claimed`,
  `CreatorFeesClaimed`, `ConfigUpdated`, `FeeRecipientUpdated`, `SignerUpdated`, `TradeExecuted`,
  ERC-1155 transfers), internal error strings (`"no leftover"`, `"pool invariant"`,
  `"funding<min"`, `"fee>in"`, `"bad bps"`, `"endDate past"`, `"not single binary"`,
  `"already disputed"`, `"nothing to claim"`, …), the domain components, addresses and the
  secp256k1 bound. **Nothing is left to be a `CreateMarket(...)` typehash**, and a 105-candidate
  brute-force over plausible struct names found nothing either.
- **Therefore I cannot honestly resolve the actor-binding question from the bytecode.** Either
  the contract binds via `nonces[msg.sender]` — in which case a signature is valid for *any*
  address sharing that nonce value, which is certain for two fresh wallets (both 0) — or it
  binds through a scheme that is not visible as a typehash constant. **Which one it is remains
  undetermined, and I am not guessing.**
- Also established by the probe: **`signer` is a storage variable (slot 6), not an immutable**
  (`usdc` *is* immutable, present at 16 sites in the code). So the signer key is rotatable by
  the owner without a contract migration, and the fork can have its signer overridden.

**To close Finding 3:** obtain the source (ask the team — this is a cooperative audit), or
locate the `ecrecover` path in the disassembly and read what feeds the digest. Note the
frontend cannot help: **the server builds and signs these EIP-712 messages**, not the client, so
the struct definition is nowhere in the bundle. That is itself worth recording — the client
relays an opaque signature it cannot verify.

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
| signature replay / actor impersonation | override `signer` (slot 6) on the fork with a controlled key, then submit a signed `createMarket` from a second address | **BLOCKED** — the signing scheme could not be reconstructed: no `CreateMarket` typehash constant exists in the runtime, so I cannot build a digest the contract will accept. Recorded as blocked, not as "secure". |
| replay across nonce-colliding addresses | needs a valid signature to exist at all | **BLOCKED** by the same constraint |
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
