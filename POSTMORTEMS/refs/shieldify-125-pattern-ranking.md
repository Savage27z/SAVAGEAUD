# Shieldify 125-report corpus — pattern ranking (grep-able)

Source: `github.com/shieldify-security/audits-portfolio` (125 PDFs, 408 MB).
**1022 findings**, 118 reports with findings (7 without: 3 image-only scans, 4 clean passes).
All titles LLM-classified into 27 families (one title unlabelled — see bottom row).

Severity mix of the corpus: **Critical 34 (3.3%) · High 98 (9.6%) · Medium 269 · Low 381 · Info 237.**
**106 of 125 reports contain no Critical at all.**

Ranked by **severe density** (share of the family that is Critical+High) — this is the "what to
check first" ordering. See `shieldify-125-corpus-2026.md` for narrative + method.

---

## Tier 1 — high severe density (check these first on any target)

### reward_accounting — 56 findings (5.5%) | C 7 · H 15 · M 18 · L 11 · I 5 | **severe 22 (39%)**
  - [Beetle] User Can Deny Opponent NFT Rewards By Marking Safe PostBattle
  - [BeraRoot] Protocol Can Permanently Lose Rewards During Periods When Zero Participants
  - [Berabot] Referrals Might Be Able to Claim Their Fees When Not Supposed to

### withdrawal_exit_queue — 14 findings (1.4%) | C 2 · H 2 · M 6 · L 2 · I 2 | **severe 4 (29%)**
  - [Builda] Users Choosing Which LRT Token to Withdraw May Harm Other Users
  - [Dinero-SuperETH] Slow Bridging from L2-L1 Using Arbitrum/Optimism Bridge May Fail the Dispute
  - [GeodeFinance-WM] Calculation Mistake on _fulfill() And _fulfillBatch() Functions

### amm_liquidity_tick — 11 findings (1.1%) | C 0 · H 3 · M 2 · L 5 · I 1 | **severe 3 (27%)**
  - [Berabot] BerabotRouter Calculation for Paths Longer Than Two Is Broken
  - [Berabot] BerabotRouter Cannot Make Swaps with V3 Pools with Fee Different than 500
  - [MöbiusExchange] Duplicate Pool in Router Path Can Cause Transaction Failure

### rounding_precision — 26 findings (2.5%) | C 3 · H 4 · M 2 · L 14 · I 3 | **severe 7 (27%)**
  - [BeeCasino] Rounding Issues
  - [ColbFinance-USC-Engine] Fee Calculation Uses Integer Division Rounding Down, Causing Protocol Revenue Loss
  - [Dyad] Missing Asset Decimal Adjustment When Calculating TVL

### fee_tax — 40 findings (3.9%) | C 2 · H 8 · M 13 · L 14 · I 3 | **severe 10 (25%)**
  - [Abster] In Case of No Referrer, Platform Charges Referral Fee to Themselves Instead of Adding it Back
  - [Abster] The payFees() Function Returns Invalid Fee When the Referrer or Fee-Recipients Are Not Present
  - [Berabot] Not Being Able To Manage Configurations Appropriately Allows Users to Avoid Fees

### web2_offchain — 40 findings (3.9%) | C 0 · H 9 · M 13 · L 9 · I 9 | **severe 9 (22%)**
  - [AllYourBase] Decimals not Handled by the Application Frontend
  - [AllYourBase] Content Spoofing via Parameters
  - [AllYourBase] Improper Error Handling in Parameters
  *Note: the frontend/off-chain band carries **no Criticals but 9 Highs** — a UI/parameter
  mismatch is a High here, not a footnote.*

### funds_locked_dos — 98 findings (9.6%) | C 3 · H 17 · M 34 · L 36 · I 7 | **severe 20 (20%)**
  - [Abster] Multiplier Configuration Can Break Distribution Invariant and Permanently Freeze Resolution
  - [Abster] The removePool() Function Permanently Locks User Balances for that Token
  - [Berabot] Users Can Always Grief the Protocol
  *Volume AND severity — the only family in both top-3 lists.*

### access_control — 106 findings (10.4%) | C 8 · H 13 · M 22 · L 50 · I 13 | **severe 21 (20%)**
  - [Adrastea] Require New Authority as Co-Signer for Authority Transmission
  - [Beetle] Admin Can Arbitrarily Seize User Assets
  - [BeraRoot] Use Ownable2Step Version Rather Than Ownable Version

---

## Tier 2 — moderate density, real volume

### share_inflation_4626 — 6 findings (0.6%) | C 1 · H 0 · M 3 · L 0 · I 2 | **severe 1 (17%)**
  - [Bankroll-VLT] ERC-20 Supply Conservation Invariant Does Not Hold While the Contract Is Not Paused
  - [Builda] Attacker Can Manipulate the Amount of bldETH that Should Be Minted to Users
  - [ColbFinance-Vault] Late Depositors Can Manipulate Share Allocation to the Detriment of Early Investors

### randomness_vrf — 14 findings (1.4%) | C 0 · H 2 · M 6 · L 5 · I 1 | **severe 2 (14%)**
  - [DarkMythos] Insecure Generation of Randomness Used for Token Determination Logic
  - [Guanciale-Stake] Current Implementation of the fulfillRandomWords() Might Not Work as Expected
  - [Guanciale-Stake] Current Key Hash for VRF Is Not Correct

### oracle_price — 28 findings (2.7%) | C 0 · H 4 · M 14 · L 8 · I 2 | **severe 4 (14%)**
  - [Beetle] Incorrect Price Emission In Batch Mint
  - [Beraji-KO] Users Can Use Outdated Prices As Long As The Signature Expiry Has Not Passed
  - [Beraji-KO] Stakers Accumulate aSugar Based On The Spot Price During The Claim

### slippage_mev — 44 findings (4.3%) | C 2 · H 4 · M 21 · L 13 · I 4 | **severe 6 (14%)**
  - [Berabot] Slippage During Transfer Fee Swap
  - [Berally-Passes] Slippage Check Before Fee Deduction Allows for Users Getting Less Than Desired
  - [DFDX] The amount0Min and amount1Min Set to Zero in Uniswap V3 Liquidity Addition

### external_call_unchecked — 9 findings (0.9%) | C 0 · H 1 · M 4 · L 3 · I 1 | **severe 1 (11%)**
  - [BastionWallet-SM] Incorrect Token Transfer in _processERC20Payment() Function
  - [BastionWallet-SM] Using the transfer() Function of address payable Is Discouraged
  - [Credifi] Unchecked ERC20 Transfer in Loan Repayment

### liquidation_solvency — 9 findings (0.9%) | C 0 · H 1 · M 4 · L 3 · I 1 | **severe 1 (11%)**
  - [Berally-Staking] Incorrect Assumption That USD Tokens Exist In a 1 to 1 Ratio
  - [ColbFinance-USC-Engine] Incorrect Collateral Calculation Lets Users Mint UnderCollateralized USC
  - [Dyad] Insufficient Exogenous Collateral Check in VaultManagerV2::liquidate()

### governance_voting — 10 findings (1.0%) | C 0 · H 1 · M 0 · L 6 · I 3 | **severe 1 (10%)**
  - [GeodeFinance-WM] Re-issued Votes Are Vulnerable
  - [Guanciale-Stake] Users Can Use Flashloan to Increase Voting Power of Expired Positions
  - [Guanciale-Stake] Users Can Have Vote Weight Even When Their Position Expired

### other_logic_flaw — 85 findings (8.3%) | C 1 · H 6 · M 27 · L 33 · I 18 | **severe 7 (8%)**
  - [BastionWallet-SM] Logic Flaw In The Subscription's Handling Functions Execution
  - [BastionWallet-SM] Subscriptions Tokens Distinguish Functionality Is Broken
  - [BastionWallet-SM] Registering and Paying a Subscription Will Not Be Possible in a Single UserOperation
  *The catch-all bucket. 8% severe means bespoke logic flaws are NOT mostly-severe — the
  recurring shapes are where the money is.*

### token_standard_edge — 51 findings (5.0%) | C 1 · H 3 · M 19 · L 22 · I 5 | **severe 4 (8%)**
  - [Adrastea] Arbitrary Input Tokens and Token Extensions Leading to Invariant Manipulation
  - [Adrastea] Risk of Input Token Mint with Freeze Authority Leading to Permanent DoS
  - [BastionWallet-SM] Protocol Does Not Work Correctly With Tokens That Do Not Revert On Failed Transfer

### reentrancy — 12 findings (1.2%) | C 0 · H 1 · M 0 · L 8 · I 3 | **severe 1 (8%)**
  - [CSX] The stake() Function does Not Follow The CEI Pattern
  - [DarkMythos-Second] The mint() Method does Not Follow the Checks-Effects-Interactions Pattern
  - [DarkMythos] Missing Reentrancy Protection For DarkMythos._mint() Function
  *Reentrancy is the lowest-yield "famous" class in this corpus: 12 findings, 1 severe.*

### stale_state_sync — 19 findings (1.9%) | C 1 · H 0 · M 6 · L 10 · I 2 | **severe 1 (5%)**
  - [Builda] Withdraw/Deposit Function Lacks to Call updateRSETHPrice()
  - [CSX] Some Trade-Terminating Functions Do Not Call removeAssetIdUsed() Internally
  - [Credifi] Incomplete Storage Cleanup in _removeTokenFromUser()

### signature_replay — 19 findings (1.9%) | C 1 · H 0 · M 8 · L 8 · I 2 | **severe 1 (5%)**
  - [Etherspot-CAM] In ResourceLockValidator the validateUserOp() Function Is Not Consuming the Signature Proof
  - [Etherspot-CAM] Missing chainID Validation and smartWallet Validation in Session Key Activation
  - [Harvest-Flow-V2] The Signature of preMint() Can Be Used in Different NFT Contracts

### upgrade_proxy_init — 25 findings (2.4%) | C 1 · H 0 · M 4 · L 13 · I 7 | **severe 1 (4%)**
  - [Abster] The addMultiplierPackage() Is Unusable After Normal Initialization
  - [Berabot] BerabotRouter Can Be Initialised By An Attacker
  - [Berabot] ReferralSystem Does Not Have Storage Gaps

### input_validation — 115 findings (11.3%) | C 0 · H 4 · M 32 · L 59 · I 19 | **severe 4 (3%)**
  - [Abster] Claim Allows Payouts From an Arbitrary Token Pool, Not the Game's Token
  - [Abster] No Upper Bounds on platformFee and referralFee
  - [Adrastea] Insufficient Account Size Checks and Lack of Reallocation Support
  ***The trap: the most common family in the corpus and the worst signal-to-noise. 115 findings,
  4 severe. Never prioritise a review by raw finding count.***

### gas_optimization — 88 findings (8.6%) | C 1 · H 0 · M 1 · L 16 · I 70 | **severe 1 (1%)**
  - [Berabot] Usage of Hardcoded Values and Magic Numbers
  - [Builda] Unnecessary Checks
  - [BullasV2] Excessive Gas Consumption in Multiple Tool Purchases

---

## Tier 3 — the zero-severe families (do not spend depth here)

- **docs_spec** — 38 findings, 34 Info, **0 severe**
- **events_returns** — 31 findings, **0 severe**
- **pause_emergency_migration** — 21 findings, **0 severe**
- **auction_bidding** — 6 findings, **0 severe**

These four = 96 findings and zero Critical/High. A reviewer who spends time on missing events,
stale docs, gas, and pause-role polish has spent 9% of the corpus budget for 0% of its severity.
They still belong in a report (cheap, and clients value them) — they just don't deserve *depth*.

---

## The one cluster that breaks the ranking: AA / session keys

Etherspot reports (Credible Account Module, CAM-Migration, Gas Tank Paymaster Module) =
23 + 19 + others findings, **10 of the corpus's 34 Criticals in three reports**.
Root causes, all one shape — an authorization layer that reads the attacker's own state:

- `enableSessionKey()` — no uniqueness check (silent overwrite of session data)
- `enableSessionKey()` — no "is this key already registered to another wallet" check → **session key hijack**
- `disableSessionKey()` — reads the *caller's* `validUntil` instead of the target's → `0 >= now` is always false → validation skipped for the privileged role
- `onInstall`/`onUninstall` — `sender` taken from calldata, `msg.sender` never authenticated → **anyone can uninstall a validator module from any wallet**
- `validateUserOp()` — signature proof never consumed → replay
- `validateUserOp()` — missing checks → drain the modular wallet

Cross-reference: `POSTMORTEMS/pattern-trace-2026-09.md` **Pattern 1** (authz predicate satisfiable
from the attacker's default state) and the OLY import (`oly-pashov-66-2026.md`) F3 (sentinel/derived
state) + F11 (be your own counterparty). Same family, third appearance.

---

## Reading list — chains we actually work

Robinhood Chain (4 public reports): **Up**, **OffYield**, **Topaz Dex**, **Trace**.
Abstract (many): Onchain Heroes, DEPTH Protocol, Souls.club, Spellborne, Pudgy Strategy,
Aborean Finance, Infinite Beyond, Roots of Embervault, Shiny, Dropster, Tollan Universe.
Also: Berachain (Berally, BeraRoot, Beraji-KO), Hyperliquid (Harmonix, Pear, Crush Trading,
HLOS, Buoy), Bob.

Ecosystem mention counts across all 125 report texts:
Ethereum 20 · Bob 18 · Berachain 12 · Arbitrum 7 · Hyperliquid 7 · Abstract 5 · Solana 5 · BNB 5.

---

## Method + limits (read before quoting any number above)

1. Extracted with pymupdf (125 PDFs → 2,725,702 chars, 0 extraction errors).
2. Findings parsed from bodies keyed on `[ID] … Severity` (plus a bracket-less/uppercase fallback
   for one format variant). **1022 findings.**
3. **Validation: parsed per-report counts match the report's own summary bullets exactly for
   105 of 116 reports** that print them. 11 mismatch — mostly Info-band over-counts (reports whose
   summary counts fewer Informationals than they actually write up, e.g. GeodeFinance 17 vs 26).
   Three are ±1 in Medium/Low. Residual error is small and confined to the non-severe band.
4. Classification: keyword regex scored **59.3% agreement** against an LLM pass on a
   seed-fixed 150-title sample — too low to publish. **All 1022 titles were then LLM-classified**
   (27-family fixed taxonomy, one label each) and the rankings above use those labels.
   The 59.3% number is kept here on purpose: a classifier that "looks right" at 59% produces
   confidently wrong priority lists.
5. **Known gap — 3 reports are image-only scans with no text layer** (41 + 37 + 21 = 99 pages):
   `Bankroll-Vault`, `Buoy`, `Up`. RapidOCR was attempted and stalled (models not cached, fetch
   never completed); it was killed rather than left burning CPU. **`Up` is a Robinhood Chain
   protocol, so this is the highest-value remaining gap.** 2,725,702 chars therefore covers 122 of
   125 reports.
6. One title unlabelled (`Zaros-Token`: "Attacker Can Initialize the Implementation" — assigned
   `upgrade_proxy_init` by inspection in the narrative doc).
