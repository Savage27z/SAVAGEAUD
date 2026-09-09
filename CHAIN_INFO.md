# Chain Info

## Local Tooling

**Foundry (forge/cast/anvil) works natively on Windows** — `curl -L https://foundry.paradigm.xyz
| bash` then `foundryup` (both run fine in Git Bash, no WSL needed). Installs to
`~/.foundry/bin` — add to `PATH` each session (`export PATH="$PATH:/c/Users/<user>/.foundry/bin"`
on Windows/Git Bash). Once installed it persists across sessions (checked — no need to
reinstall, just re-export PATH). This means Phase 4 (fork tests) is doable directly, not only by
𝖲𝖠𝖵𝖠𝖦𝖤 — `forge test --match-contract <Name> -vvv` against a `vm.createSelectFork(<rpc>)`
targeting the REAL deployed contract (no redeployment needed for read/write calls against
already-live contracts) is enough to move a finding from Unverified to Confirmed. First used:
Run Money F01 (see `TARGETS/run-money/fork-test/`).

**`forge-std`'s `makeAddr("label")` can collide with a real deployed contract on a mainnet
fork** — it's a deterministic keccak-derived address, not guaranteed empty. Hit this on Run
Money (an attacker test address landed on a live contract, causing a confusing
`ERC721InvalidReceiver` revert). Prefer explicit low vanity addresses
(`address(0x00000000000000000000000000000000BEEF01)`) for fork PoC test actors and verify
`cast codesize` is 0 first if in doubt.

**Etherscan V2 unified API** (`https://api.etherscan.io/v2/api?chainid=<id>&...`) works across
all Etherscan-family explorers (Basescan, Arbiscan, etc.) with ONE API key — the V1
per-chain-domain endpoints are deprecated and return `NOTOK`. Real keys for this account are in
various project `.env` files under `~/Desktop/*/`(grep `ETHERSCAN_API_KEY`/`BASESCAN_API_KEY`)
— reuse rather than re-requesting from the user. `action=getsourcecode` returns the full
Solidity Standard JSON Input (multi-file) — parse `result[0].SourceCode` (strip a leading/
trailing extra `{`/`}` wrapper if present) to get every source file, not just the flattened
main contract.


## Robinhood Chain (RH)

| Property | Value |
|----------|-------|
| Chain ID | 4663 |
| RPC | `https://rpc.mainnet.chain.robinhood.com` |
| Explorer | `https://robinhoodchain.blockscout.com` |
| Explorer API | `https://robinhoodchain.blockscout.com/api` |
| Native Token | ETH (wrapped: `0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73`) |
| USDG | `0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168` |
| Type | Arbitrum Orbit L2 |
| Launched | July 1, 2026 |

### Key Contracts

| Contract | Address |
|----------|---------|
| WETH | `0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73` |
| USDG | `0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168` |
| Uniswap V3 Factory | `0x1f7d7550B1b028f7571E69A784071F0205FD2EfA` |
| Uniswap V3 SwapRouter02 | `0xCaf681a66D020601342297493863E78C959E5cb2` |
| Uniswap V4 PoolManager | `0x8366a39CC670B4001A1121B8F6A443A643e40951` |

### RPC Notes
- Rate limit on `eth_call` — add `sleep(2)` between calls
- Use `keccak256` from `pycryptodome` (NOT `hashlib.sha3_256`) for correct selectors

---

## Monad

| Property | Value |
|----------|-------|
| Chain ID | 143 |
| RPC | `https://testnet-rpc.monad.xyz` (testnet) / `https://rpc.mainnet.monad.xyz` (mainnet) |
| Explorer | `https://explorer.monad.xyz` |
| Native Token | MON |
| USDC | Deployed per standard |
| Type | EVM L1 |
| Launched | May 2026 |

### RPC Notes
- Monad testnet RPC is rate-limited. Use `sleep(1)` between calls.
- Mainnet RPC may require API key — check docs.
- Used for: OBSDN audit (Perpetual DEX, $220K TVL)

---

## Ethereum

| Property | Value |
|----------|-------|
| Chain ID | 1 |
| RPC | Standard public RPC per provider |
| Explorer | `https://etherscan.io` |
| Explorer API | `https://api.etherscan.io/api` |
| Native Token | ETH |
| Type | EVM L1 |

### RPC Notes
- Use forked node (Anvil) for testing — do not test on mainnet
- Used for: Cleave audit (Options splitting protocol, $76 TVL)

---

## Arbitrum One

| Property | Value |
|----------|-------|
| Chain ID | 42161 |
| RPC | `https://arb1.arbitrum.io/rpc` |
| Explorer | `https://arbiscan.io` |
| Native Token | ETH |
| Type | EVM L2 (Optimistic rollup) |

### RPC Notes
- Arbitrum RPC is unreliable for `anvil --fork-url` — timeouts are common
- If fork fails, rely on static analysis + manual review
- Used for: Basalt Vault audit ($119K TVL, delta-neutral yield)

---

## Base

| Property | Value |
|----------|-------|
| Chain ID | 8453 |
| RPC | `https://mainnet.base.org` |
| Explorer | `https://basescan.org` |
| Native Token | ETH |
| Type | EVM L2 (Optimism stack) |

### RPC Notes
- Coinbase L2 — good RPC reliability
- Growing ecosystem with early-stage protocols
- Used for: openOracle, Arcis Protocol, Run Money (ClubPool, F01 confirmed on fork)

---

## Solana

| Property | Value |
|----------|-------|
| RPC | `https://api.mainnet-beta.solana.com` (public, rate-limited — expect 429s, retry with backoff) |
| Explorer | `https://solscan.io` (note: instruction-name decoding can be WRONG/generic for unverified programs — always cross-check against raw `getTransaction` `logMessages`, not Solscan's guessed labels) |
| Native Token | SOL |
| Type | L1, Sealevel runtime (BPF/SBF programs, not EVM) |

### RPC Notes
- No Etherscan-equivalent verified-source guarantee — most small/new programs are **not**
  source-verified. Check `solana program show <id>` or Solscan's "Verification" tab first.
- No Slither/Foundry/anvil equivalent tooling. Local fork testing = `solana-test-validator`
  with `--clone` of the target program + its state accounts. Not yet used in this repo — first
  Solana target (Moocon) only reached recon/TMAAR.
- **No source, no IDL is common and not itself a redflag alone** — but blocks Phase 1 (code
  read) entirely. Recon workaround that worked well: pull the program's executable data account
  raw bytes via `getAccountInfo` (owner = `BPFLoaderUpgradeab1e11111111111111111111111`, address
  = the `programData` field off the program account), then extract printable ASCII runs. Anchor/
  Borsh compile every instruction name, account name, and `require!()` error string as a literal
  — this recovers the full instruction/account/error surface without any decompilation. Does
  NOT recover control flow / line-level logic — that still needs real BPF disassembly (Ghidra +
  Solana loader, or similar).
- Anchor IDL, if published, lives at a deterministic PDA
  (`createWithSeed(findProgramAddress([], programId)[0], "anchor:idl", programId)`) — check this
  before assuming a program is unreverseable; many DO publish IDL on-chain even without a public
  repo.
- `getProgramAccounts` without a `dataSlice`/`filters` can be slow/rate-limited on public RPC for
  programs with many accounts — fine for Moocon (only 3 accounts owned directly; most state is
  delegated to MagicBlock's ephemeral rollup program between rounds).
- Used for: Moocon audit (no-loss lottery on Jupiter Lend, $14K TVL, in progress)

---

## Berachain

| Property | Value |
|----------|-------|
| Chain ID | 80094 |
| RPC | `https://rpc.berachain.com` |
| Explorer | `https://berascan.com` |
| Native Token | BERA |
| HONEY | Berachain stablecoin |
| Type | EVM L1 (Polkadot SDK + EVM) |

### RPC Notes
- Reliable public RPC
- Growing DeFi ecosystem — many unaudited protocols
- Used for: SukukFi audit (RWA Lending, $54 TVL)
