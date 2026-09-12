# OLY/OlympusX (Pashov) — 66-finding digest

Compact per-finding root cause, for grepping. Full narrative: `POSTMORTEMS/oly-pashov-66-2026.md`.
Source PDF: https://github.com/pashov/audits/blob/master/team/pdf/OLY-security-review_2025-12-31.pdf


## Critical

### C-01 Genesis rewards will be stolen  
*Status: Resolved*  
In the mint phase, users mint OLY tokens via native ether. These native ethers will be sent to the router for distribution. The distribution part for genesis will be held in TaxRouter. The genesis team can withdraw these rewards via the function withdrawEth . In function distributeEth/distributeEthFromMint , users can trigger these two functions to distribute rewards. In function _distributeEthInternal , if the input value is zero, the function will distribute the current native ether balance in this contract. The problem here is that the current native ether balance belongs to genesis . This will cause anyone to be able to redistribute genesis ' rewards to stakers, validator vault, etc . fu

### C-02 Underflow during FarmKeeper V4 liquidity minting  
*Status: Resolved*  
When adding or minting liquidity into V4 liquidity pools tied to farms through FarmKeeperV4Lib::addLiquidity() , it is observed that the protocol checks the amount utilized by the FarmKeeper contract to increase the LP position before and after the PositionManager::modifyLiquidities() call. However, when reviewing how unlockData is prepared via FarmKeeperV4Lib::_prepareMintPositionUnlockData() and FarmKeeperV4Lib::_prepareAddLiquidityUnlockData() , we observe that the protocol performs a sweep for any remaining native ETH if oversettlement occurs. Under the hood, this sweep operation calls PositionManager::_sweep() , which transfers any remaining token balances held by the PositionManager ba

### C-03 V4 farm tokenId can be cached but not minted  
*Status: Resolved*  
V4 pools are enabled through the FarmKeeper::enableV4Farm() call. Once the native pool is enabled, ETH is swapped for the equivalent currency1 through _depositToV4Farm() followed by _swapV4Currency() . After that, any remaining currency0Balance and currency1Balance are supplied to the relevant V4 pool as LP through _addV4Liquidity() , which calls FarmKeeperV4Lib::addLiquidity() . The issue lies in the FarmKeeperV4Lib::addLiquidity() logic. We observe that when the calculated liquidity to be supplied is 0, the farm.lp.tokenId , which represents the ERC6909 position token for the farm, is still cached even though the FarmKeeper does not actually mint a position token. In this case, PositionMan

### C-04 Intermediary poolId not updated for nonnative farms  
*Status: Resolved*  
For farms with non-native pools, the admin adds an intermediary pool to swap ETH allocated to the farm into one of the tokens associated with that farm. This intermediary pool can be configured as either a V3 pool or a V4 pool, and FarmKeeper::setIntermediaryConfiguration() allows the admin to update the intermediary pool configuration. function setIntermediaryConfiguration( bytes32 id, uint16 slippage, uint32 twapPeriod, PoolKey memory poolKey, bool isPoolV4 ) external onlyOwner validFarmId(id) { FarmKeeperValidationLib.validateSwapSlippage(slippage); FarmKeeperValidationLib.validateTwapPeriod(twapPeriod); PoolData storage intermediaryPool = intermediaryPools[id]; if (intermediaryPool.swapS

### C-05 Incorrect handling of stETH shares causes accounting error  
*Status: Resolved*  
The stakeETH() function in ValidatorVault incorrectly treats the return value of stETH.submit() as the amount of stETH tokens received, when it actually returns the number of shares minted. This fundamental misunderstanding of Lido's rebasing token mechanism leads to systematic under-wrapping of stETH to wstETH, causing multiple critical issues with fund accounting and reward distribution. Root Cause: According to Lido's documentation, stETH.submit() returns the number of shares minted, not the stETH token amount. The relationship between shares and stETH tokens is: stETH_balance = shares * totalPooledEther / totalShares Currently, the share-to-stETH ratio is approximately 1 share ≈ 1.22 stE


## High

### H-01 Fail to unwrap WETH in swapV3EthForFarmToken  
*Status: Resolved*  
In FarmKeeper, users can deposit assets to Uniswap pools via depositToFarm . If the target pool is not one native pool, the native ether will be swapped to an intermediary token via function _swapNativeForFarm at first. If the intermediaryPool is one Uniswap v3 pool, nativeBalance will be wrapped to WETH at first. It is possible that there will be some remaining WETH, recorded by swapResult.unusedAmount . These unused WETH will be recorded back to nativeBalance . In the next farm, these native ether can be used again. The problem here is that the unused WETH fails to be unwrapped to native Ether. This will cause that in the next farm, the actual native ether might be less than nativeBalance

### H-02 Unused amount may be calculated incorrectly  
*Status: Resolved*  
In the SwapActions contract, there is one swap retry mechanism. If this swap slippage is larger than expected, the swap action will retry until the retry count reaches maxRetries . The problem here is that if the swap fails for all retries, the actual used amount should be 0. However, the unusedAmount will be calculated by result.unusedAmount = params.amountIn - amountToSwap . This will cause the unusedAmount to be less than expected. function _swapV4Currency( SwapExactInParams memory params, PoolKey memory poolKey, Currency currencyIn, Currency currencyOut, uint48 deadline ) internal returns (SwapExactInResult memory result) { // true --> isV4 Pool. _approveTokenIfNeeded(Currency.unwrap(cur

### H-03 Limit order incorrectly filled on tick movement  
*Status: Resolved*  
The OlympusXHook contract relies on the _getCrossedTicks() function to identify which ticks were crossed during a swap by comparing the current pool tick with the previously recorded tick. Based on this range, _afterSwap() processes any limit orders whose tick ranges are considered crossed and marks them as filled. However, this approach can incorrectly mark limit orders as fully filled in certain price movement patterns. Specifically, if a swap moves the tick into a limit order's range by crossing the lower boundary but does not cross the upper boundary, and a subsequent swap then moves the tick back in the opposite direction, the limit order may be incorrectly treated as filled. Consider t

### H-04 Inefficient liquidity provision due to decimal-agnostic token  
*Status: Resolved*  
The depositToFarm() function in FarmKeeper determines which token to swap by comparing raw token balances without accounting for token decimals. This breaks the protocol's efficiency guarantee that all available tokens should be optimally deployed as liquidity. When depositToFarm() is called, the function compares farm.currency0Balance > farm.currency1Balance to decide which token to swap. This comparison uses raw wei amounts, which are not comparable across tokens with different decimal places. For example, in a USDC (6 decimals) / DAI (18 decimals) pool: If the intermediate pool swap provides 100 USDC (1e6) and fees (to be reinvested) accumulate 1 DAI (1e18), the comparison 100 * 1e6 > 1e1

### H-05 First depositor can claim all auction tokens before auction  
*Status: Resolved*  
The claim() function in OlympusXAuction allows users to claim their proportional share of OLY tokens without verifying whether the auction for the current cycle has concluded. This creates a critical race condition where the first depositor during an active auction can immediately claim all distributed tokens before other users have a chance to participate. 1. 2. 3. 4. 1. 2. 3. 4. 5. When a user deposits ETH via deposit() during an active auction, their contribution is recorded in userDeposits[msg.sender][currentCycle] and added to totalEthDeposited[currentCycle] . The claim() function then calculates the claimable amount using the formula: (userDeposit * olympusXAmount) / totalEth; However,

### H-06 Liquidity addition vulnerable to sandwich attacks due to spot  
*Status: Resolved*  
The addLiquidity() function in FarmKeeperV4Lib calculates the liquidity amounts to add using the current spot price obtained from getSlot0() . This creates an opportunity for sandwich attacks where an attacker can manipulate the pool price immediately before liquidity addition to extract value. The attack flow works as follows: An attacker monitors the amount of liquidity available to be added to a pool. If enough liquidity is available to make the attack profitable, the attacker swaps in the pool to move the current tick to an extreme price. He calls the public addLiquidity() function, which reads the manipulated tick via getSlot0() and calculates liquidity based on this distorted price. Th

### H-07 Asymmetric unit scaling in swapAmount calculation breaks  
*Status: Resolved*  
In FarmKeeper.depositToFarm() , the swap amount ( swapAmount ) is calculated asymmetrically depending on swap direction. In the token1 → token0 branch, the balance is multiplied by 1e6 , while in the token0 → token1 branch, no such scaling is applied. As a result, when swapToken0 == true , the computed swapAmount is typically ~1e6 times smaller than intended, effectively disabling rebalancing in that direction. This causes systematic under-swapping, leaving one side of the pair underfunded and preventing proper liquidity balancing. Asymmetric swapAmount formula bool swapToken0 = farm.currency0Balance > farm.currency1Balance; uint256 swapAmount = (swapToken0 ? farm.currency0Balance : farm.cur

### H-08 Exact output swaps incur lower tax than exact input swaps  
*Status: Resolved*  
The protocol implements different tax calculation formulas for exact input versus exact output swaps when users sell OLY tokens for ETH, resulting in users paying substantially less tax when using exact output swaps. This creates an exploitable arbitrage opportunity and undermines the protocol's dynamic tax mechanism designed to regulate market activity based on market capitalization. The tax discrepancy occurs because of different calculation methods in _beforeSwap() and _afterSwap() : Exact Output Tax (in _beforeSwap() ): When params.amountSpecified > 0 , the user specifies the desired ETH output amount. The tax is calculated as: taxAmount = (netRequested * taxBps) / BPS Exact Input Tax (i

### H-09 Withdraw pays only one token while accounting debits both  
*Status: Resolved*  
When an epoch is filled, the protocol materializes the result in two tokens and stores them in epochInfo.token0Total and epochInfo.token1Total . During withdraw() , the user’s proportional share is calculated and deducted from both totals. However, in unlockCallbackWithdraw , the user is paid only one token, depending on the zeroForOne direction. The second token (including principal and/or fees accumulated in the “unexpected” currency) may not be paid out and can remain locked on the hook as minted claims in PoolManager . 1. 2. 3. 4. • • • This creates a mismatch between accounting and payout: user balances for both tokens are debited, but only one side is actually transferred. Fill records


## Medium

### M-01 Reward loss due to precision underflow in cycle payouts  
*Status: Resolved*  
It is observed that reward tokens are paid out every X cycle days depending on the cycle number. Each time a token reward payout is triggered through StakingVault::_triggerCyclePayout() , the value of cumulativeRewardPerShare[token][_cycleNo] is increased. However, in situations where _globalActiveShares is very large and the value of tokenReward * PRECISION is very small, an underflow can occur. When this happens, cumulativeRewardPerShare[token][_cycleNo] is not incremented, while tokenCyclePayoutPool[token][_cycleNo] is reset to zero. This issue is more likely for reward tokens with low decimal precision and high value, such as WBTC . function _triggerCyclePayout(uint256 _cycleNo, uint256

### M-02 Share rate increase causing staking value loss  
*Status: Resolved*  
It is observed that when a user stakes, the currentShareRate can increase due to the daily multiplier of 1.0003 applied to the previous day’s share rate through StakingCalculations::updateShareRate() . function _updateShareRate() internal { if (currentDay > lastShareRateUpdate) { uint40 daysPassed = currentDay - lastShareRateUpdate; @> currentShareRate = StakingCalculations.updateShareRate(currentShareRate, daysPassed, CAPPED_MAX_RATE); lastShareRateUpdate = currentDay; emit ShareRateUpdated(currentShareRate, currentDay); } } As a result, users who stake OLY tokens in exchange for vault shares may receive fewer vault shares for the same amount staked. This design favors earlier stakers over

### M-03 Reward claim pattern issue with blacklisted tokens  
*Status: Resolved*  
It is observed that for token rewards claimed by users during staking and unstaking, the protocol uses a push pattern rather than a pull pattern for ERC20 tokens. For tokens that include a blacklisting mechanism, this creates an issue where a staker who is blacklisted by USDC cannot open new stakes or close an existing stake. This occurs because both StakingVault::_startStake() and StakingVault::_processEndStake() call the internal function StakingVault::_claimAllRewardsInternal() -> StakingVault::_claimAllTokensForCycle() , which attempts to transfer reward tokens to the user. If the staker is blacklisted for USDC and has accumulated USDC rewards, the token transfer will fail and cause the

### M-04 Eth pricing fallback misprices USD value  
*Status: Resolved*  
We observe that in multiple instances within the v4 hook OlympusXHook and in LaunchManager , the protocol relies on an EthPrice contract to price ETH in terms of USD. By default, this contract retrieves the USD price using the Chainlink ETH to USD price oracle, and the resulting value is scaled to 18 decimal places. However, if the price feed is stale or returns an abnormal value, the protocol falls back to using a TWAP price from Uniswap. This can be sourced from any Uniswap V3 or Uniswap V4 pool with sufficient liquidity, where the returned square root price is squared to derive the price of token0 in terms of token1. For simplicity, we consider the Uniswap V3 WETH to USDT pool that is con

### M-05 Overflow risk in price calculation during V4 pool creation  
*Status: Resolved*  
It is observed that in LaunchManager , once initialLiquidityEthCollected reaches the required initialLiquidityEth , the protocol proceeds to initialize a V4 ETH <> OLY pool through the V4 PoolManager contract. function createAndInitializeLiquidityPool(uint48 deadline) external { require(initialLiquidityEthCollected >= initialLiquidityEth, LaunchManager__InsufficientInitialEth()); require(initialPoolTokenPrice > 0, LaunchManager__InvalidInitialPoolPrice()); uint256 ethPrice = ethPriceFeed.getLatestEthPriceUSD(); // Calculate liquidity pool allocation dynamically based on ETH price and target token price uint256 liquidityPoolAllocation = (initialLiquidityEth * ethPrice) / initialPoolTokenPrice

### M-06 Inflation pool accounting gap allows excess distribution  
*Status: Resolved*  
The inflation pool accounting system has a timing gap between when stakes end and when inflation rewards are claimed that allows more inflation to be distributed than the maxInflationPool limit allows. The system tracks emitted inflation using two variables: totalInflationDistributed : Inflation allocated to daily pools but not yet minted. totalInflationMinted : Inflation that has been minted to users. The available inflation for distribution is calculated in _distributeDailyInflation() as: uint256 maxAllowedTotal = maxInflationPool > totalInflationMinted ? maxInflationPool - totalInflationMinted : 0; uint256 maxAdditional = maxAllowedTotal > totalInflationDistributed ? maxAllowedTotal - tot

### M-07 Tokens permanently locked in accounting if auction receives  
*Status: Resolved*  
The OlympusXAuction contract suffers from an accounting error where OLY tokens allocated to an auction cycle become permanently inaccessible if no users deposit ETH during that cycle. This occurs due to improper management of the totalReservedTokens state variable across the auction lifecycle. When startDistribution() is called to begin a new auction cycle, the function calculates the amount of tokens to distribute and increments totalReservedTokens : uint256 amountToDistribute = ((poolBalance - totalReservedTokens) * uint256(distributionBps)) / BPS; olympusXDistributedPerCycle[currentCycle] = amountToDistribute; totalReservedTokens = totalReservedTokens + amountToDistribute; These tokens ar

### M-08 Accrued fees can be exploited to obtain subsidized liquidity  
*Status: Resolved*  
The unlockCallbackPlace() function in OlympusXHook allows users to place limit orders by adding liquidity to specific tick ranges. However, when the pool price enters a tick range but does not fully cross it (partial fill), the existing position accumulates trading fees. These accrued fees create an exploitable condition where new users can add liquidity to the same tick and effectively use the accumulated fees to subsidize their position costs. When poolManager.modifyLiquidity() is called on a position with accrued fees, the returned BalanceDelta includes both the cost of adding new liquidity and the credit from accumulated fees. The function only checks the final delta values to ensure the

### M-09 New limit order participants unfairly receive fees from exited  
*Status: Resolved*  
The place() function in OlympusXHook allows users to add liquidity to existing epochs that already have accumulated fees from previous participants who exited their positions. This creates an unfair distribution mechanism where new participants receive trading fees they never earned, diluting rewards for users who legitimately held positions while those fees were generated. When a user removes their limit order via kill() while other liquidity providers remain in the same epoch, the exiting user's accumulated trading fees are allocated to remaining participants through the epochInfo.token0Total and epochInfo.token1Total variables: function unlockCallbackKill(...) external selfOnly returns (.

### M-10 Withdrawal requests revert when combined amounts exceed  
*Status: Resolved*  
The _prepareWithdrawalAmounts() function in ValidatorVault attempts to handle small remainder amounts by combining them with a full withdrawal request. However, this logic creates amounts that exceed Lido's MAX_WITHDRAWAL_AMOUNT of 1000 stETH, causing all withdrawal requests to revert and blocking the protocol's ability to harvest and distribute rewards. 1. 2. 3. 4. 5. 6. 7. 8. Lido's withdrawal queue enforces strict constraints: Maximum per request: 1000 stETH (exactly 1000 ether). Minimum per request: 100 wei. The function handles remainders smaller than the minimum by merging them with the last full request: } else if (remainder > 0 && fullRequests > 0) { // If remainder is too small but

### M-11 Imprecise maturity calculation allows premature stake ending  
*Status: Resolved*  
The _verifyMaturityPercentage() function enforces that stakes can only be ended early if they have reached at least 50% of their committed duration. However, the current implementation uses a day-based calculation that compounds rounding errors from both the stake start time and the current time, allowing users to end stakes up to nearly a full day before they have actually reached 50% maturity. The flawed calculation occurs in _verifyMaturityPercentage() : uint256 stakeStartDay = (_stake.stakeInfo.stakeStartTs - launchTime) / uint40(1 days) + 1; uint256 daysCompleted = currentDay - stakeStartDay; uint256 maturityPercent = (daysCompleted * 100) / _stake.stakeInfo.numOfDays; Both stakeStartDa

### M-12 Incorrect validation in validateFarmSetup allows non-  
*Status: Resolved*  
The validateFarmSetup() function incorrectly validates which token must be a registered reward token for Uniswap V4 pools. In V4 pools, ETH is represented as address(0) in currency0 , while currency1 holds the paired ERC20 token. However, the validation logic attempts to determine the "other token" using the isWethToken mapping, which does not contain address(0) since address(0) cannot be added to it: function setWethToken(address _wethToken, bool _isWethToken) external onlyOwner { @> require(_wethToken != address(0), FarmKeeper_InvalidAddress()); isWethToken[_wethToken] = _isWethToken; emit FarmKeeper_WethTokenSet(_wethToken, _isWethToken); } This means that for a V4 ETH pool, the function

### M-13 Missing validation allows intermediary pool with wrong token  
*Status: Resolved*  
When enabling a farm with a non-native pool (neither token is ETH/WETH), an intermediary pool is required to swap ETH into one of the main pool's tokens. However, validateFarmSetup() does not validate that the non-ETH/WETH token in the intermediary pool matches either currency0 or currency1 of the main pool. The validation only checks: Both main pool tokens are registered reward tokens. The intermediary pool exists and has proper TWAP history. Exactly one token in the intermediary pool is ETH/WETH. But crucially, it never validates that the other intermediary pool token is actually one of the main pool tokens. 1. 2. 3. This allows an owner to configure an intermediary pool with an arbitrary

### M-14 Reward debt heuristic can drop rewards after reward token  
*Status: Resolved*  
StakingVault uses a heuristic where userRewardDebt == 0 is treated as “uninitialized” and replaced with tokenAdditionBaseline . In a removeRewardToken(token) → addRewardToken(token) scenario, this can cause loss of claimable rewards for some users: a user who staked when cumulativeRewardPerShare[token][cycle] == 0 and never claimed and never changed shares will have userRewardDebt remain 0 . After the token is re-added, tokenAdditionBaseline is reset to a newer (non-zero) cumulative value, and during claim the userDebt == 0 branch substitutes this new baseline, effectively skipping rewards accrued before the re-add. Baseline is reset on token addition tokenAdditionBaseline[_token][CYCLE_8_DA

### M-15 Excess ETH not refunded when placing limit orders  
*Status: Resolved*  
The place() function in OlympusXHook accepts ETH payments via msg.value to place limit orders, but fails to refund any excess ETH that exceeds the amount actually required for the liquidity position. This results in users losing funds when they send more ETH than necessary, with the excess permanently trapped in the contract. • • When a user calls place() to create a limit order with ETH as currency0 , the function calculates the exact amount needed through the unlockCallbackPlace() callback. Inside unlockCallbackPlace() , when delta.amount0() < 0 (indicating ETH is needed), the function settles with only the required amount: amount0 = uint256(uint128(-delta.amount0())); poolManager.sync(key

### M-16 Unequal reward distribution lets short-term stakers access  
*Status: Acknowledged*  
The protocol distributes rewards across five different cycles (8, 28, 90, 369, and 888 days), intending to reward longer-term stakers with access to less frequent but potentially more valuable reward cycles. However, the current implementation fails to restrict which cycles a stake is eligible for based on its duration, leading to a significant fairness issue where short- term stakers can receive the same rewards as long-term stakers. When a user creates a stake, their shares are calculated via StakingCalculations.calculateShares() which applies a time-based bonus (0-400% depending on stake duration from 88 to 1776 days). However, once shares are minted, they participate in all five reward c

### M-17 Inflation reward calculation is not accurate  
*Status: Resolved*  
In StakingVault, users can stake OLY to earn some staking rewards. The inflation rewards will be calculated by the formula totalSupply * annualRateBPS * delta time . Once users stake or unstake their positions, the previous time slot's inflation rewards will be calculated by _distributeDailyInflation . The problem here is that the totalSupply will change without any stake. For example, users mint OLY and do not stake any OLY into the staking vault, or users can burn OLY via BuyAndBurn. For example, users mint OLY and do not stake any OLY into the staking vault, or users can burn OLY via In timestamp X, users stake OLY into the staking vault. In timestamp X + 3000, users mint some OLY and sta

### M-18 Ethereum can be locked if required liquidity is not achieved  
*Status: Acknowledged*  
We observe that users supply ETH to mint OLY tokens, which is tracked through initialLiquidityEthCollected in LaunchManager . Once the supplied ETH reaches the initialLiquidityEth threshold required to seed the V4 ETH <> OLY pool, anyone can call LaunchManager::createAndInitializeLiquidityPool() to initialize the pool and add liquidity through the FarmKeeper . However, if initialLiquidityEthCollected never reaches initialLiquidityEth , the supplied ETH remains permanently locked in LaunchManager with no mechanism for recovery. Extending the mint phase does not guarantee that the initialLiquidityEth target will be met. In such a case, the only way forward would be for the protocol itself to s

### M-19 Emergency withdrawal fails to recover ETH in pendingEth  
*Status: Resolved*  
The emergencyWithdrawWstEth() function is designed to recover all funds from the ValidatorVault in extreme circumstances, but it only withdraws wstETH tokens and completely ignores any ETH held in the pendingEth state variable. This creates a scenario where a portion of user funds is left in the contract after an emergency withdrawal, defeating the purpose of the emergency mechanism. The Issue: The emergency withdrawal function only handles wstETH: function emergencyWithdrawWstEth() external onlyOwner { uint256 balance = IERC20(wstEth).balanceOf(address(this)); if (balance == 0) revert ValidatorVault__ZeroAmount(); IERC20(wstEth).approve(stakingVault, balance); IStakingVault(stakingVault).di

### M-20 Removed tokens lead to unclaimable rewards causing  
*Status: Resolved*  
When a reward token is removed from the StakingVault via removeRewardToken() , users lose the ability to claim any pending rewards for that token through the standard claiming mechanisms like claimAllRewards() and the automatic reward claim when starting or ending a stake. The _claimAllTokensForCycle() function only iterates through the current rewardTokens array, meaning removed tokens are completely skipped. Root Cause: The _claimAllTokensForCycle() function only processes tokens currently in the rewardTokens array: function _claimAllTokensForCycle(address _user, uint256 _cycleNo) internal returns (uint256 totalClaimed) { uint256 tokensLength = rewardTokens.length; for (uint256 t = 0; t <

### M-21 Missing slippage protection in mint function exposes users  
*Status: Resolved*  
The mint() function lacks slippage protection when converting ETH to OLY tokens, breaking the protocol's guarantee that users receive the expected token amount for their ETH contribution. Users have no control over the minimum tokens they receive, exposing them to potentially significant losses due to ETH price fluctuations between transaction submission and execution. When a user calls mint() with ETH, the function calculates the OLY tokens to mint using tokensToMint = msg.value * ethPriceFeed.getLatestEthPriceUSD() / schedule.tokenPrice . The ethPriceFeed.getLatestEthPriceUSD() function queries a Chainlink oracle (or Uniswap TWAP fallback) to get the current ETH price in USD. However, this

### M-22 Dead stake violates zero staker invariant and absorbs  
*Status: Resolved*  
StakingVault initializes a permanent deadStake with DEAD_SHARES = 1000 , which is always included in totalShares and participates in inflation distribution. This has two related effects that stem from the same design choice. First, the protective guard intended to prevent inflation accrual when no real stakers exist ( if (_totalShares == 0) ... return ) never triggers in practice. Because _totalShares always includes DEAD_SHARES , inflation can be distributed and reserved even when there are no real stakers in the system, violating the invariant “no stakers → no inflation accrual”. Second, inflation is calculated based on totalSupply() but distributed proportionally across totalShares , incl

### M-23 LP fees can be permanently locked in nonfilled epochs after  
*Status: Resolved*  
In non-filled epochs, LP fees can accumulate in epochInfo.token0Total and epochInfo.token1Total as a result of kill() calls by non-last participants. When all users exit an epoch via kill() before it ever reaches the filled state, the epoch remains non-filled ( filled == false ), liquidityTotal drops to zero, and withdraw() becomes permanently unavailable due to the NotFilled() gate. In this terminal state, accumulated token totals (representing collected LP fees) have no execution path for distribution. The epoch is neither finalized nor reset, and the recorded token0Total / token1Total values remain stranded on the hook without any user- accessible withdrawal mechanism. kill() reduces liqu

### M-24 Missing collect accrued swap fees in  
*Status: Resolved*  
In OlympusXHook, users can place one limit order via place() . In the callback unlockCallbackPlace , the liquidity will be added to the pool. The return value BalanceDelta delta includes needed token0/token1 and also accrued fees. It is possible that when users place one limit order, there are some accrued fees. This will cause users to fail to place a limit order because there is one condition in the function unlockCallbackPlace : the other token amount must be 0. For example: Place one limit order [tick A, tick A + tick spacing). The current tick is moved to this range and accrues some fees for this position. The tick moves out of this range. If another user wants to place one limit order,

### M-25 Protocol rebalances incur OLY sell tax when swapping via  
*Status: Resolved*  
When rebalancing a v4 farm in depositToFarm() , FarmKeeper performs swaps through the farm's own poolKey . If the farm uses the taxed main OLY pool (with OlympusXHook ), then on the sell direction (OLY → ETH) the protocol effectively pays the sell-tax like a regular trader. With typical configurations where early-tier taxBps (e.g., 18–38%) exceeds the farm’s default swapSlippage (e.g., 10%), sell-side rebalances become either operationally fragile (frequent TooLittleReceived / slippage reverts) or economically inefficient if operators increase slippage to force execution. This creates a systemic operational/economic degradation for farms that rebalance via the taxed pool: either sell rebalan


## Low

### L-01 Stake position flooding risk  
*Status: Resolved*  
It is observed that a user stake position can be flooded with many small stake entries. An attacker can use the LaunchManager::mint() followed by StakingVault::startStakeForUser() flow to front run a user staking transaction and fill the staker userStakes array with numerous small stake positions. As a result, when the legitimate staker later tries to unstake the original stake position, they must remove each stakeId individually. Otherwise, the call sequence from StakingVault::stakeEnd() to StakingVault::_processStakeEnd() to StakingVault::_removeUserStake() may revert due to excessive gas consumption. This situation can cause the legitimate staker to lose both the principal amount of OLY s

### L-02 Ineffective staking allowance management in  
*Status: Resolved*  
LaunchManager.setStakingVault() attempts to manage staking permissions by revoking and re-approving token allowance ( approve(0) → approve(type(uint256).max) ). However, in OlympusX , the allowance() function special-cases the stakingVault address and always returns type(uint256).max , ignoring the stored allowance value. As a result, the approve/revoke logic in setStakingVault() has no real effect on staking permissions. This creates a mismatch between the intended control flow in LaunchManager and the actual permission model enforced by OlympusX , potentially misleading maintainers, reviewers, or integrators into assuming that staking access can be revoked or rotated via allowance manageme

### L-03 Claimable amount underflow causing stuck token  
*Status: Acknowledged*  
OlympusXAuction calculates the claimable amount of OLY tokens based on the amount of ETH used by a bidder through OlympusXAuction::deposit() . However, if we look at OlympusXAuction::getClaimableAmount() , the calculated claimable amount can underflow when userDeposit * olympusXAmount < totalEth for a given cycle. Although this scenario has a low likelihood, since ETH is expected to be worth more than the token, it can still occur. When this underflow happens, totalReservedTokens is not decremented correctly. As a result, some OLY tokens can become stuck in the contract and cannot be distributed to future cycles. This leads to a situation where winning bidders, meaning those who deposited mo

### L-04 EthPrice oracle missing price deviation check  
*Status: Acknowledged*  
We observe that the EthPrice oracle uses either a UniswapV3 pool or a UniswapV4 pool as a fallback to price ETH in terms of USD. The primary pricing mechanism relies on the ETH USD price feed from Chainlink. However, we observe that there are no on-chain price deviation checks in place to handle scenarios where price spikes occur. If the price of ETH temporarily spikes due to Chainlink oracles returning incorrect values or due to users swapping large amounts of tokens in the pools, although this is unlikely since high liquidity pools will be used and a very large amount of tokens would be required, the oracle may return an abnormally high ETH price in USD terms. One impact of this is that th

### L-05 Mint transactions vulnerable to griefing via front running due  
*Status: Resolved*  
LaunchManager.mint() reverts if the calculated number of tokens to mint exceeds the remaining amount in the current vesting schedule. Because partial fills are not supported and the check is enforced as a hard require , users cannot buy “whatever remains” in the schedule, nor can they specify protective parameters such as minimum acceptable output. This behavior enables a griefing/MEV scenario where a third party front-runs a large purchase with one or more small mint transactions, slightly reducing the remaining token amount. As a result, the original transaction—calculated against the previous remaining amount—reverts. The attacker gains no direct economic benefit, but can repeatedly force

### L-06 ValidatorVault.harvest() reverts on buy and burn  
*Status: Resolved*  
ValidatorVault.harvest() calculates 16% of rewards for Buy & Burn and attempts to create a Lido withdrawal request. Lido requires a minimum withdrawal amount of 100 wei stETH. If the Buy & Burn portion after conversion from wstETH is below this minimum, the function reverts with ValidatorVault__AmountTooSmall() , blocking the entire harvest process. While rewards will eventually grow enough to overcome the minimum, this causes temporary denial of service for all reward distribution (StakingVault 68%, reinvestment 16%). The protocol cannot harvest until sufficient rewards accumulate.

### L-07 StakeETH allows ETH to be staked while minting zero  
*Status: Resolved*  
ValidatorVault.stakeETH(amount) does not verify that wrapping the received stETH into wstETH produces a non-zero result. Due to floor rounding in wstETH.wrap() , sufficiently small staking amounts may result in zero wstETH minted, even though ETH is successfully staked via Lido. This means the operation has a real external effect while producing no accounting-visible staking position. This issue persists even if principal accounting is fully corrected.

### L-08 Unused token allowance after partial swap execution  
*Status: Resolved*  
SwapActions approves the full amountIn before swaps, but the retry mechanism reduces swap amounts on slippage errors, leaving unused allowance. For V4/PERMIT2 this persists until the deadline; for V3's forceApprove it remains indefinitely. Residual allowance could amplify other vulnerabilities.

### L-09 Payout schedule advances only one cycle per call when cycles  
*Status: Resolved*  
StakingVault._triggerCyclePayout updates nextCyclePayoutDay incrementally by adding a single cycleLength ( += cycleLength ). When a large number of days have passed without activity, this causes overdue payout schedules to “catch up” only one cycle per transaction. As a result, even after a successful payout trigger, nextCyclePayoutDay can remain significantly behind currentDay . Processing all missed payout cycles requires multiple external calls to functions that invoke _triggerPayouts() , and reward distribution timing becomes dependent on subsequent user interactions after a period of inactivity. This behavior does not lead to loss of funds or incorrect reward calculations, but it may re

### L-10 CyclePayoutTriggered logs ethReward = 0 due to  
*Status: Resolved*  
In StakingVault._triggerCyclePayout , the ethReward value emitted in CyclePayoutTriggered is determined via a pre-scan over rewardTokens and therefore depends on token ordering. If the first token with a non-zero tokenCyclePayoutPool is an ERC20, the pre-scan sets hasRewards = true and breaks early, leaving ethReward as 0 even when the ETH pool for the same cycle is non-zero. This can cause the CyclePayoutTriggered(..., ethReward) event to report 0 ETH while ETH rewards are actually distributed in the same call. This does not affect on-chain reward accounting, but can mislead off-chain indexers, dashboards, and analytics that rely on the ethReward event field. Pre-scan + early break makes et

### L-11 No wstETH/stETH oracle on ETH mainnet  
*Status: Resolved*  
ValidatorVault determines the current value of wstETH staked in the vault in terms of ETH by assuming that stETH trades 1:1 with ETH. While this assumption is already risky without any on-chain price deviation checks, the more fundamental vulnerability is the assumption that a valid wstETH / stETH price feed exists on the Ethereum mainnet. If we carefully examine the oracle referenced by the protocol for wstETH / stETH in the test files, it is actually an AAVE oracle price adapter that returns the wstETH / USD price instead. function getWstETHRateFeedByChainId(uint256 chainId) internal pure returns (address) { //Ethereum - Chainlink wstEth/stETH rate feed if (chainId == 1) { @> return addres

### L-12 Self-referral allows users to claim both minter and referrer  
*Status: Resolved*  
The mint() function lacks validation to prevent self-referral, allowing users to set themselves as the referrer and claim both the minter bonus and referral bonus, effectively doubling their bonus allocation and draining the referral pool faster than intended. When a user mints tokens with a referrer, the protocol allocates two bonuses from the referral pool: Referral bonus (5% of minted tokens) to the referrer. Minter bonus (5% of minted tokens) to the minter. The function accepts any address as the referrer without checking if it is the same as the minter ( to ) or the caller ( msg.sender ). This allows a user to: Call mint(to, to, vestingSchedule) or mint(to, msg.sender, vestingSchedule)

### L-13 Farm removal fee distribution mismatch with documentation  
*Status: Resolved*  
We observe that during farm removals, all accumulated fees of currency0 and currency1 are distributed to stakers of 28-day cycles. However, the code comment states that ETH and WETH fees should be sent to the taxRouter , while other ERC20 token fees should be distributed to stakers during farm removals. If one of the pool currencies is WETH or ETH, the current logic still distributes the accumulated fees to stakers instead of routing them to the taxRouter . This creates a mismatch between the documented behavior and the implemented logic. If this behavior is intended, the recommendation is to update the code comment to reflect the actual implementation. If it is not intended, then for pools

### L-14 Incorrect liquidity removed value in FarmKeeper_Removed  
*Status: Resolved*  
When removing farms via FarmKeeper::removeFarm() , the FarmKeeper_Removed event emits an incorrect value for the liquidityRemoved field. Instead of indicating the actual liquidity that was removed, it emits farm.lp.liquidity , which has already been deleted at the time of emission. As a result, liquidityRemoved is always emitted as 0, which is incorrect. The recommendation is to cache the initial liquidity value before deletion and emit that cached value as liquidityRemoved in the event. // ... delete _accumulatedFees[id]; delete intermediaryPools[id]; delete farmAllocPoints[id]; @> _farms.remove(id); // Send ETH to tax router _safeETHTransfer(taxRouter, ethAmount); @> emit FarmKeeper_Remove

### L-15 Constructor does not validate price configuration parameters  
*Status: Resolved*  
The constructor() directly assigns _priceConfig to priceConfig without performing any validation checks on the configuration parameters. In contrast, setPriceConfig() validates that the weth address is one of the tokens in the Uniswap pool by checking it against token0 and token1 . This inconsistency means an invalid configuration could be set during deployment, potentially causing failures when attempting to fetch prices from the Uniswap fallback. The constructor should apply the same validation logic as setPriceConfig() to ensure the weth address corresponds to one of the pool tokens and that other configuration parameters are valid.

### L-16 Intermediary pool configuration lacks validation  
*Status: Resolved*  
The setIntermediaryConfiguration() function allows the owner to update the intermediary pool configuration for a farm, but it does not validate that the provided poolKey corresponds to an actual existing pool. While slippage and twapPeriod are validated, the pool's existence is never checked. This differs from enableV3Farm() and enableV4Farm() , which validate pool existence during farm creation. Setting an invalid intermediary pool could cause reverts when attempting to swap native tokens through the non-existent pool via swapNativeForFarm() or depositToFarm() . Add validation to verify the pool exists based on the isPoolV4 flag, similar to the validation performed in the farm enablement fu

### L-17 Twap period can be set to an invalid value  
*Status: Resolved*  
The setTwapPeriod() function in OlympusXHook allows the owner to set the TWAP period to any value, including zero or extremely low values, without validation. This period is used by getTokenPriceInUsd() and getMarketCap() to calculate time-weighted average prices from the Uniswap pool. Setting the TWAP period to zero or a very low value would break the TWAP oracle logic, making price calculations unreliable or causing reverts in the underlying TWAP library calls. Other contracts in the protocol, like FarmKeeper , validate the TWAP period to be between 1 minute and 60 minutes. Apply similar validation in setTwapPeriod() to ensure the TWAP period remains within a reasonable range that supports

### L-18 Reward tokens become permanently locked when removed  
*Status: Resolved*  
In removeRewardToken() , if outstanding rewards exist in cycle payout pools but totalShares is zero, the rewards cannot be distributed and become permanently locked in the contract. The distribution logic requires both conditions: if (totalRemaining > 0 && totalShares > 0) . When there are no active shares (all stakes have ended), the rewards in tokenCyclePayoutPool for all cycles cannot be distributed to stakers nor recovered by any mechanism. This edge case could occur if the protocol experiences a period with no active stakes while reward tokens are still being accumulated, or if a token needs to be removed during such a period. Add a fallback mechanism to transfer any remaining rewards t

### L-19 Rounding dust from reward distribution becomes  
*Status: Resolved*  
In removeRewardToken() , when distributing outstanding rewards across all cycles, the calculation (amount * PRECISION) / totalShares can result in rounding down, leaving dust tokens in the contract. After updating cumulativeRewardPerShare , the pool balance is set to zero without accounting for this rounding remainder. When users claim rewards, they receive (cumulativeRewardPerShare * shares) / PRECISION , which also rounds down. The combination of these two rounding operations means a small amount of tokens remains in the contract balance but is not reflected in claimable rewards. While typically negligible per distribution, these dust amounts accumulate over time and across all five cycles

### L-20 Summed reward claims across different tokens produce  
*Status: Resolved*  
In _claimAllTokensForCycle() , the totalClaimed variable accumulates rewards across all reward tokens by summing tokenReward amounts. This value is returned and used in claimAllRewards() to populate the claimedPerCycle array. However, when multiple reward tokens exist with different decimal places (e.g., ETH with 18 decimals, USDC with 6 decimals), summing these amounts creates a meaningless value. For example, claiming 1 ETH (1e18) and 1000 USDC (1000e6) would result in totalClaimed = 1e18 + 1000e6 = 1_000000001000000000 , which does not represent the actual value of either asset. The returned claimedPerCycle array from claimAllRewards() becomes unusable for off- chain tracking or display p

### L-21 Inconsistent slippage handling for increase and decrease of  
*Status: Resolved*  
In the v4 liquidity helper logic, two different slippage models are used for increase and decrease operations. During decrease liquidity, minimum output amounts ( minAmount0 / minAmount1 ) are adjusted using the configurable farm.liquiditySlippage parameter. In contrast, during increase liquidity, the calculated liquidity is always reduced by a fixed coefficient 9_950 / BPS (0.5%), which is not configurable via farm parameters. As a result, slippage tolerance is only partially parameterized. Operators may reasonably expect farm.liquiditySlippage to control slippage behavior consistently, but in practice it applies only to decrease operations, while increase operations always incur a hard-cod

### L-22 Implicit assumption on Chainlink price feed decimals in  
*Status: Resolved*  
EthPrice implicitly assumes that the configured Chainlink price feed uses 18 decimals or fewer. This assumption is not enforced or validated in code. While this is true for standard ETH/USD Chainlink feeds today, the contract does not guard against misconfiguration. If a feed with more than 18 decimals were ever configured, price scaling logic would break or revert, potentially impacting all protocol paths that rely on ETH price (including minting and liquidity-related calculations). This is not an exploitable vulnerability under correct configuration, but it represents a fragile external dependency assumption that could lead to systemic failures if violated.

### L-23 StakeETH can be front run with a small amount to disrupt  
*Status: Resolved*  
The stakeETH function is callable by anyone and allows users to stake ETH held in ValidatorVault.sol into Lido. Although the function is permissionless and lets users specify the staking amount, the transaction will revert if the amount exceeds pendingEth: if (amount > pendingEth) revert ValidatorVault__InsufficientPendingEth(); Because of this behavior, a malicious user can front-run a transaction where stakeETH is called with an amount equal to pendingETH by submitting a transaction with a very small amount (e.g., 100 wei). This reduces pendingETH and causes the victim's transaction to revert. While this issue does not lead to direct fund loss, it negatively impacts user experience and can

### L-24 Missed slippage protection when users sell OLY  
*Status: Resolved*  


### L-25 Mint accounting break with mixed liquidity and vesting  
*Status: Resolved*  


### L-26 Insufficient observation cardinality validation in  
*Status: Resolved*  
The FarmKeeper.setTwapPeriod() function allows the owner to update the TWAP period for a farm without validating whether the pool has sufficient observation cardinality to support the requested period. This creates a vulnerability where TWAP price queries may fail and price determination will fall back to manipulable spot prices. When setTwapPeriod() increases the TWAP period (e.g., from 15 minutes to 60 minutes), it does not verify that the pool's observationCardinality can accommodate the longer lookback window. The required number of observations depends on the block time and TWAP period. For example, on Ethereum mainnet with a 12-second block time, a 60-minute TWAP requires approximately

### L-27 ValidatorVault assumes stETH is pegged 1 to 1 with ETH  
*Status: Resolved*  
We observe that in multiple instances throughout ValidatorVault , the protocol assumes that stETH is pegged 1:1 with ETH. While both assets tend to trade close to parity, this has not always been the case. Market conditions can cause stETH to deviate from ETH, breaking the assumed peg. We observe the following instances where stETH is treated as 1:1 with ETH. In ValidatorVault::harvest() , when calculating currentEthValue of the total wstETH held by the ValidatorVault in terms of ETH, getWstETHValue() assumes stETH is 1:1 with ETH. In ValidatorVault::harvest() , when calculating reinvestedETHValue for the portion of wstETHToReinvest , the wstETH amount is converted to a stETH value and stETH
