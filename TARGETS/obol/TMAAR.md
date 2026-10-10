# TMAAR — Daemon (obol.sh)

**Phase 0.5 artifact. Written from the deployed bytecode + live chain state, not from the docs.**
Chain: Robinhood Chain 4663 · RPC `https://rpc.mainnet.chain.robinhood.com`
Status at time of writing: sale LIVE (opened 2026-10-10 18:00 UTC), `sold = 329 / 10048`, band 0, price 0.01 ETH.

## Trust model

What you are trusting, and how much of it is enforced by code rather than by a promise:

- **The three contracts are self-contained and immutable.** No proxy, no owner, no pause, no
  upgrade path in `DaemonSale` / `DaemonNFT` / `DaemonAccount`. Parameters (prices, bands,
  split, treasury, opening time, `accountImpl`) are constructor immutables — I decoded them
  out of the runtime bytecode rather than reading the website's claims.
- **The one privileged act is already spent.** `setNft` can be called once, by the deployer
  `0x76c4eEE7…`, and is dead now that `nft` is set — there is no admin surface left.
- **The daemon wallet is genuinely the holder's.** `owner()` reads
  `IERC721(tokenContract).ownerOf(tokenId)` live, so the wallet (and its balance and its
  agent limits) travels with the NFT. This is the single most important design question for
  an ERC-6551 collection and it is implemented correctly.
- **The agent is the only untrusted party the design tries to contain** — and the container
  has a hole in the ETH path (F1).
- **The look/rarity layer is entirely off-chain and trusted** (F3). This is where the
  project's headline promise is weakest: trait table and seed are website strings, art is
  served from a mutable domain.

## Actors

| Actor | Address | Authority | Can | Cannot |
|---|---|---|---|---|
| Buyer | anyone | none | buy any unsold daemon at exactly the current band price; withdraw everything from the wallet it then holds | choose the price; take two daemons for one payment |
| Deployer | `0x76c4eEE7…` (EOA, 0 bytes) | one-shot | `setNft` **once, before it was set** | change price/split/treasury/opening; re-point the NFT; hold or move funds; touch metadata |
| Daemon holder | `nft.ownerOf(tokenId)` | full | `execute` anything from that daemon's wallet; `constitute` the agent + limits | reach another daemon's wallet |
| Daemon agent | holder-chosen key | bounded | call allowlisted targets within caps; approve allowlisted spenders; send tokens back to the holder; pre-approve one EIP-3009 payment | act after the NFT moves (`InertAfterTransfer`); `transferFrom`; delegatecall; exceed `maxPerCall` on the dollar — **but see F1 for ETH** |
| Treasury (SHYGUY LLC) | `0xA7DC540d…` (Safe) | none over the protocol | receive 10% | anything else |
| ERC-6551 registry | `0x0000…5758` | permissionless | create any account (idempotent) | substitute code at an existing account address |

## Assumptions

| # | Assumption | Breaks if | Status |
|---|---|---|---|
| ASM-1 | Look rarity is committed before mint and nobody can pick rares | seed ground off-chain before its hash is published / hashes not anchored / art mutable | **not enforced** (F3) |
| ASM-2 | `accountImpl` resolves the owner from the NFT, forever | a different implementation were wired | holds — verified live |
| ASM-3 | An agent cannot exceed the holder's stated limits | daily accounting misses an outflow path | **breaks for ETH** (F1) |
| ASM-4 | USDG honours ERC-1271 so approved digests are usable | USDG validates 3009 by ecrecover only | OPEN |
| ASM-5 | The agent runtime (agentfile, x402 serving) is run by the holder | it is run centrally by the publisher | OPEN (off-chain, out of scope) |

## Accepted risks (by design, stated by the project)

- **The holder can do anything**, including emptying the wallet immediately — "90% goes into
  it" is a balance the buyer can withdraw at will (F4). Not a defect; material for anyone
  pricing the endowment.
- **USDG is the only tracked asset** for agent spending; other ERC-20s an agent can move are
  not metered (the contract's own comment says so).
- **Look, log, inbox, repo, market screens and the agent's autonomy are off-chain.** Only the
  look/wallet are on-chain at launch; "autonomy follows."

## Failure modes ranked by what an attacker gains

1. **Nothing permissionless.** Price gates, ownership gate and the `sold` counter all sit
   before any value moves; the sale never holds funds; the wallet's owner check reads the NFT
   live. I could not construct a path for an outsider to obtain a daemon without paying the
   current band price, or to move ETH out of the sale or out of someone else's daemon wallet.
2. **Bounded agent abuse** (F1) — a compromised agent key empties the ETH, ignoring the daily
   ceiling the holder believed they set.
3. **Sellout view panic** (F2) — permanent `price()` revert after the 10,048th sale.
4. **Provenance trust** (F3) — a buyer cannot verify rarity, before or after.

## Verification notes (what made this auditable)

- Explorer is Cloudflare-walled; **Sourcify v2 `?fields=all` resolved all three contracts**
  (`exact_match`, non-proxy) — the pre-vet oracle that worked.
- Immutable constructor values were recovered from
  `runtimeBytecode.transformationValues.immutables`, so every number in this report comes from
  deployed bytecode, not from the deployer's description of it.
- Reusable scripts: `TARGETS/_obol_fetch.py`, `_obol_immutables.py`, `_obol_read.py`,
  `_obol_read2.py`, `_obol_read3.py`.
