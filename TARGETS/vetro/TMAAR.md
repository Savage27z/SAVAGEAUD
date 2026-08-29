# VETRO — TMAAR (Trust Model, Actors, Assumptions, Accepted Risks)

**Target:** VETRO — CDP / pegged-asset issuance (VUSD, vetBTC) on Ethereum mainnet
**Date:** 2026-08-29
**Deployed commit:** main @ 3c063a0394 (repo pushed 2026-08-18)
**Audited commit:** b0507cb46a4b87cde9087e2954b4575ca24ce7c7 (Quantstamp, Hemi-chain VUSD, Feb-Mar 2026)
**Drift:** 1,436 insertions / 774 deletions across Gateway, Treasury, StakingVault, YieldDistributor, PeggedToken + 4 NEW files (YieldManager, ChainlinkFeedAdapter, DerivedPriceFeedAdapter, FixedPriceFeedAdapter)

## Protocol shape

VETRO mints pegged tokens (VUSD, vetBTC) backed by collateral (USDC/USDT). Users deposit
collateral → Gateway → Treasury (reserve). The Treasury deploys excess collateral into
external yield strategies. Yield is harvested by keepers and distributed to stakers who lock
pegged tokens in a StakingVault (ERC-4626). AMO (algorithmic market operations) can mint
unbacked pegged tokens for liquidity provisioning.

Per-asset stack (zero shared state between VUSD and vetBTC deployments):
`PeggedToken → Gateway → Treasury → StakingVault → YieldDistributor` + `YieldManager` (keeper periphery) + price feed adapters.

## Actors

| Actor | Address / Role | Powers | Trust |
|---|---|---|---|
| **Owner (Safe multisig)** | ProxyAdmin owner, DEFAULT_ADMIN_ROLE | Upgrade proxies, set roles, set fees/params, whitelist tokens, sweep | High — presumably multisig (verify on-chain) |
| **Keeper** | KEEPER_ROLE on Treasury/YieldManager | Calls harvestAndDistribute() to chain harvest→mint→distribute | Low — timing control only |
| **UMM (AMO manager)** | UMM_ROLE on Treasury/Gateway | Mint unbacked pegged tokens, deploy to AMMs | High — can print unbacked supply |
| **Distributor** | DISTRIBUTOR_ROLE on YieldDistributor | Push yield into the drip schedule | Medium |
| **Users** | anyone | Deposit collateral → mint pegged tokens; burn → withdraw; stake pegged → earn yield; redeem | — |
| **Oracle** | ChainlinkFeedAdapter / DerivedPriceFeedAdapter / FixedPriceFeedAdapter | Provide collateral prices to Treasury | Critical — price source |
| **External yield strategies** | whitelisted vaults | Hold Treasury collateral deployed for yield | High — off-chain/venue risk |

## Assumptions (and what-if)

- **Oracle prices are honest and current** — what if a feed goes stale, gets stuck, or the
  derived feed (vetBTC = BTC price × conversion) has a rounding/scale bug? HV-4 in QS audit:
  oracle tolerance assumes pegged assets are $1 — acknowledged, and **reworked post-audit**
  (peg-band fix 2026-07-14).
- **Keeper is honest about timing** — harvestAndDistribute re-spreads remaining yield over a
  fresh period; an open call could stretch the drip (per YieldManager dev comment, keeper-gated).
  What if keeper is compromised or griefed?
- **AMO supply invariant holds** — HV-3: AMO-minted tokens burned directly break
  `totalSupply - amoSupply` underflow. Fixed in audited code; check the rewritten PeggedToken.
- **Yield distribution is not orphaned** — HV-1: distribute() with unpulled accrued yield
  permanently orphans tokens. Fixed in audited code; **YieldManager is a NEW call path into
  distribute()** — does it re-introduce or bypass the fix?
- **Withdrawals are delay-protected** — tiered withdrawal delays prevent bank runs (HV-7
  acknowledged). Deployed code has withdrawal delay logic — check the rewritten StakingVault.
- **Collateral tokens are standard** — whitelist gates which tokens; fee-on-transfer or
  rebasing collateral could break reserve accounting (Gap: Trust).

## Accepted risks (documented)

- QS HV-4 (oracle tolerance assumes $1 peg) — acknowledged → verify the peg-band fix didn't
  just paper over it
- QS HV-5 (re-lock of matured claimable tokens) — acknowledged Low
- QS HV-7 (depeg bank-run dynamic) — acknowledged Low
- Off-chain/venue risk in yield strategies

## Key on-chain facts (2026-08-29)

- VUSD: 0xCa83DDE9c22254f58e771bE5E157773212AcBAc3
- Gateway (proxy): 0xDaD503f8B9d42bb7af3AfC588358D30163e4416F, impl 0x07Ee70DFd5a74d4a038Ff6AAE1d31Ca2C71F4DF1
- Treasury: 0xC8317A10385BE07901A4c9ee3d06E1D83AE378c9
- StakingVault (proxy): 0x476310E34D2810f7d79C43A74E4D79405bd7a925, impl 0x91EDc1F7b0ab6357A85b4D228A00CA68fd2B0661
- YieldDistributor (proxy): 0x55745265Ba172378cf45d224F09F0673cB470cef, impl 0x4a6e1AcA9fB0A5d428dFac5127C511a9d5723080
- YieldManager: 0x964d0E0C1fc7eCB2061A4e7e011e3F2406daC33e
- ChainlinkFeedAdapter: 0x1db2a56ee11b87e2f4a0efbe3f5ccf2551019db6
- VetBTC: 0xf196C68233464A16CFDa319a47c21f4cECa62001
- VetBTCGateway (proxy): 0xCBA2Ffa0AC52d7871a4221a871793Eb788013faB
- VetBTCTreasury: 0xd25a7b0b817fD816d0995eC67fb70e75EE65Bd7F
- SVetBTC (proxy): 0x0cB9D84d4bcEc8d3D5B2d99a6F07f4605325987e
- VetBTCYieldDistributor (proxy): 0xd74bcf1299176E98899bA2e86dD2C9aE089F5276
- VetBTCYieldManager: 0x7E8Ca0594457C944C7b07dF7b9ba1C06360994ba
- DerivedPriceFeedAdapter: 0x33F1E44DB47400C9BD6221962712D882Adb8fFA6
- FixedPriceFeedAdapter: 0x032A35daDA672B394525881f789a3B4E7734C76C
- ProxyAdmins: Gateway 0x83B2435d9A30b7463B3Ba997ba47a14B73149e2A, StakingVault 0x3912505880b9b8F0Ac2531cde9428994a7728aa3, YieldDistributor 0xDd751f2B4FA3445C7befa39cf981b6bEc1FeB1B1

## Verify on-chain before reading (TODO)

- [ ] Owner of each ProxyAdmin — multisig or EOA?
- [ ] Treasury owner / DEFAULT_ADMIN_ROLE holder
- [ ] KEEPER_ROLE holders (Treasury + YieldManager)
- [ ] UMM_ROLE holder
- [ ] Whitelisted collateral tokens per Treasury
- [ ] Actual TVL per Treasury (withdrawable())
- [ ] Oracle addresses live on the Treasury
