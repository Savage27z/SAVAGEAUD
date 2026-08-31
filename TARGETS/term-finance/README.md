# Term Finance Governance Takeover — Case Study (Aug 23, 2026)

**Lesson:** Governance layers are the new attack surface. A $951 takeover of an empty electorate drained ~$8.5M — no contract bug, no reentrancy, no oracle. The "veto gate" and "7-day timelock" were both real and both bypassed by the person who bought the vote.

## The story in one breath

Term Finance (Ethereum fixed-rate lending) built **Meta Vaults** on Yearn V3 infrastructure. Each vault's governor is a **Gnosis Safe → Zodiac Roles → Zodiac Delay** chain, driven by an **Aragon OSx DAO** with TokenVoting. The voting token is a `GovernanceWrappedERC20`: **holding LP shares gives you no vote unless you wrap them**. The DAO was designed as a *veto gate* over parameter changes, so in 16 months almost nobody wrapped.

- 5 USDC strategy vaults: **zero** wrapped supply. Attacker deposited **$5 each**, wrapped → **100.000% of the vote**.
- ETH Meta Vault: exactly **one** voter (0.05 shares wrapped on launch day, Apr 2025). Attacker bought **0.485216 shares for 0.5 ETH**, wrapped → **90.66%**.
- Governance settings: `supportThreshold 50%`, `minParticipation 5%` — **of wrapped supply** — `minDuration 49h`, **`minProposerVotingPower 0` (anyone can propose)**, `votingMode 2` (early execution).

Quorum of 5% of nothing is nothing. One wrapped share is both quorum and majority.

## The permission loop (root cause)

Term's own risk-curator proposals each carry ONE action: `callTargetFunctionWithRole(delay, setTxNonce(...), 1)` — the LP veto cancels a queued change. The attacker's proposal carried **seventeen actions** through the same pathway, and the first three rewrote the Delay itself:

```
Roles.callTargetFunctionWithRole(delay, Delay.setTxCooldown(0),   1);  // 608,400s → 0
Roles.callTargetFunctionWithRole(delay, Delay.setTxExpiration(0), 1);
Roles.callTargetFunctionWithRole(delay, Delay.enableModule(dao),  1);  // DAO becomes module
```

`DELAY.owner() == ROLES`, and Role 1 was granted to the DAO → the attacker-controlled DAO could call **any** function on the Delay — including the Delay's own admin functions. The thing protecting governance was governed by the thing it protected. The 7.04-day `txCooldown` that would have given depositors a week to exit became 0 instantly.

## On-chain receipts (verified via eth.blockscout.com)

**Attacker op1:** `0xa908b3472d76e7744bab0a5911768a4a6300612b` (EOA)
**Exploit contract:** `0x184f2e57b4ce135181fa2a2166ac394339016338` — name on-chain: **"Fixed Recipient WETH Exit Strategy"**, creator = op1, deployed tx `0x595fe955...` 6 days before the attack
**Aragon plugin (proposal/vote/execute target):** `0x64E477800051EFb06Ae4086f4b258b270668b4dF`
**Consolidation address:** `0xD5183d8BfC65a50863C62aF2538198A8288FFc13` — still holds 1,679,642 DAI (the USDC→DAI swap) as of Aug 29
**Funding:** ~2 ETH from Tornado Cash (two 1-ETH notes, one day apart)

Timeline (all blocks/txs verified):
| When | Tx | What |
|---|---|---|
| Aug 17 05:19:11 | `0x595fe955...` | CREATE "Fixed Recipient WETH Exit Strategy" |
| Aug 17 05:21:47 | `0x724e377f...` | `swapAndForwardEth(0.5 ETH)` → buy 0.485216 tmvETH |
| Aug 17 05:25:35 | `0x284fc544...` | `propose()` on Aragon plugin (17 actions) |
| Aug 17 05:26:47 | `0x6e735333...` | `voteFor()` (100% self-vote) |
| Aug 23 06:25:47 | `0xd354a15b...` | `executeProposal()` → zero delay, recall debt, push 2,841.74 WETH into exit strategy |
| Aug 23 06:27:23 | `0x0b4fb183...` | `withdraw()` on WETH — pull the loot |
| Aug 23 06:31:47 | `0xb3971dcb...` | **2,841.237 ETH → consolidation** |
| Aug 23 ~06:47 | `0x9f273f9a...` | second tx: 5 USDC vault proposals → 1,679,639 USDC |
| Aug 24 | multiple | consolidation peels 100 ETH chunks to `0xC140...`-prefixed addresses |

Drain mechanics (ETH vault): `update_debt(strategy, 0)` on all 4 strategies (unwound Aave V3 + MetaMorpho positions, returned 44/44/1,446/1,308 WETH), then `add_strategy(EXIT_STRATEGY)`, `update_max_debt_for_strategy(EXIT, max)`, `update_debt(EXIT, max, 10000)` → all WETH into the exit strategy which forwards it out. Vault kept reporting `pricePerShare 1.030751` while holding zero WETH.

**Response irony:** Term revoked DAO roles on 6 of 8 vaults — but on those 6 the attacker had already zeroed `txCooldown`, so the fix inherited no delay. On the 2 undrained ETH vaults the original 262,800s cooldown is intact → **Term's own revocation is still queued behind the timelock that is now protecting the attacker's position**. Depositors wrapped shares to fight back (pushed attacker below majority in 2 of 5 USDC DAOs) but the ETH proposals had already closed.

## Audit checklist additions (how to catch this class)

1. **Measure the electorate, not the token**: for any TokenVoting/governance-token system, check *wrapped/active voting supply* vs total supply. `minParticipation` based on a wrapper with 0 supply = quorum is free.
2. **`minProposerVotingPower = 0` + empty electorate = game over**. Any cheaply-acquirable majority = takeover.
3. **The permission loop**: who owns the timelock/delay? Can the governed entity call the delay's own admin functions (`setTxCooldown`, `setTxExpiration`, `enableModule`, `updateDelay`)? A timelock is only a delay if **nothing inside the system can shorten it**.
4. **Broad "role" on a generic executor**: `callTargetFunctionWithRole(target, arbitrary calldata, role)` — check what the role actually gates. A "veto" path implemented as "call any function" is not a veto, it's a backdoor.
5. **Attack-cost economics**: if control of the vault costs < $1K and vault holds $8M+, that's the finding — severity by cost-to-takeover, not just by code bug.
6. **When a safeguard looks "idle by design"** (zero vetoes in 16 months), ask what happens when the FIRST person to use it is an attacker.
