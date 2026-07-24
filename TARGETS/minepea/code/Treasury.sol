// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

interface IPea {
    function getPriceDeviation() external view returns (int24, int24, uint24);
    function isTWAPReady() external view returns (bool);
    function burn(uint256 amount) external;
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
}

interface IStaking {
    function distributeYield(uint256 amount) external;
}

contract Treasury is Ownable, ReentrancyGuard, IUnlockCallback {
    // ============ Constants ============

    uint256 public constant BURY_BPS = 9500;         // 95% burned
    uint256 public constant STAKER_BPS = 500;       // 5% to stakers
    uint256 public constant BPS_DENOMINATOR = 10000;

    uint256 public constant DEFAULT_SLIPPAGE_BPS = 500;  // 5% default slippage
    uint256 public constant MAX_SLIPPAGE_BPS = 2000;     // 20% max slippage

    // ============ State ============

    IPea public pea;
    IStaking public staking;
    IPoolManager public immutable poolManager;
    address public gridMining;

    // V4 Pool config (set via setPoolConfig after pool creation)
    uint24 public poolFee;
    int24 public poolTickSpacing;
    IHooks public poolHooks;
    bool public poolConfigSet;

    uint256 public vaultedETH;
    uint256 public buybackThreshold;
    uint256 public slippageBps;

    // Stats
    uint256 public totalBurned;
    uint256 public totalDistributedToStakers;
    uint256 public totalBuybacks;

    // ============ Events ============

    event VaultReceived(uint256 amount, uint256 totalVaulted);
    event BuybackExecuted(
        uint256 ethSpent,
        uint256 peaReceived,
        uint256 peaBurned,
        uint256 peaToStakers
    );
    event ThresholdUpdated(uint256 oldThreshold, uint256 newThreshold);
    event SlippageUpdated(uint256 oldSlippage, uint256 newSlippage);

    // ============ Errors ============

    error OnlyGridMining();
    error BelowThreshold();
    error TWAPNotReady();
    error SlippageTooHigh();
    error ZeroAddress();
    error BuybackFailed();
    error PriceDeviationTooHigh();
    error OnlyPoolManager();
    error PoolConfigNotSet();

    // ============ Modifiers ============

    modifier onlyGridMining() {
        if (msg.sender != gridMining) revert OnlyGridMining();
        _;
    }

    // ============ Constructor ============

    constructor(
        address _pea,
        uint256 _buybackThreshold,
        address _poolManager
    ) Ownable(msg.sender) {
        if (_poolManager == address(0)) revert ZeroAddress();
        pea = IPea(_pea);
        poolManager = IPoolManager(_poolManager);
        buybackThreshold = _buybackThreshold;
        slippageBps = DEFAULT_SLIPPAGE_BPS;
    }

    // ============ Admin Functions ============

    function setGridMining(address _gridMining) external onlyOwner {
        if (_gridMining == address(0)) revert ZeroAddress();
        gridMining = _gridMining;
    }

    function setStaking(address _staking) external onlyOwner {
        if (_staking == address(0)) revert ZeroAddress();
        staking = IStaking(_staking);
    }

    function setBuybackThreshold(uint256 _threshold) external onlyOwner {
        uint256 oldThreshold = buybackThreshold;
        buybackThreshold = _threshold;

        emit ThresholdUpdated(oldThreshold, _threshold);
    }

    function setSlippage(uint256 _slippageBps) external onlyOwner {
        if (_slippageBps > MAX_SLIPPAGE_BPS) revert SlippageTooHigh();

        uint256 oldSlippage = slippageBps;
        slippageBps = _slippageBps;

        emit SlippageUpdated(oldSlippage, _slippageBps);
    }

    function setPoolConfig(uint24 _fee, int24 _tickSpacing, address _hooks) external onlyOwner {
        poolFee = _fee;
        poolTickSpacing = _tickSpacing;
        poolHooks = IHooks(_hooks);
        poolConfigSet = true;
    }

    // ============ Vault Functions ============

    /**
     * @notice Receive vaulted ETH from GridMining
     * @dev Only callable by GridMining contract
     */
    function receiveVault() external payable onlyGridMining {
        vaultedETH += msg.value;

        emit VaultReceived(msg.value, vaultedETH);
    }

    // ============ Buyback Functions ============

    /**
     * @notice Check if buyback can be executed
     * @return canExecute True if conditions are met
     * @return reason Reason if cannot execute
     */
    function canExecuteBuyback() external view returns (bool canExecute, string memory reason) {
        if (vaultedETH < buybackThreshold) {
            return (false, "Below threshold");
        }

        if (!pea.isTWAPReady()) {
            return (false, "TWAP not ready");
        }

        if (!poolConfigSet) {
            return (false, "Pool not configured");
        }

        // Only block when PEA is more expensive than TWAP
        (int24 spotTick, int24 twapTick,) = pea.getPriceDeviation();
        if (spotTick < twapTick && uint24(twapTick - spotTick) > slippageBps) {
            return (false, "Price deviation too high");
        }

        return (true, "");
    }

    /**
     * @notice Execute buyback using vaulted ETH via V4 PoolManager
     * @dev Anyone can call this: uses TWAP deviation check for MEV protection
     */
    function executeBuyback() external nonReentrant {
        if (vaultedETH < buybackThreshold) revert BelowThreshold();
        if (!pea.isTWAPReady()) revert TWAPNotReady();
        if (!poolConfigSet) revert PoolConfigNotSet();

        uint256 ethToSpend = vaultedETH;
        vaultedETH = 0;

        // Only block when PEA is more expensive than TWAP
        (int24 spotTick, int24 twapTick,) = pea.getPriceDeviation();
        if (spotTick < twapTick && uint24(twapTick - spotTick) > slippageBps) revert PriceDeviationTooHigh();

        // Perform V4 swap via unlock/callback pattern
        uint256 balanceBefore = pea.balanceOf(address(this));
        uint256 ethBalanceBefore = address(this).balance;
        poolManager.unlock(abi.encode(ethToSpend));
        uint256 peaReceived = pea.balanceOf(address(this)) - balanceBefore;

        // Credit back unconsumed ETH from partial fill
        uint256 ethConsumed = ethBalanceBefore - address(this).balance;
        if (ethConsumed < ethToSpend) {
            vaultedETH = ethToSpend - ethConsumed;
        }

        if (peaReceived == 0) revert BuybackFailed();

        // Calculate distribution
        uint256 toBurn = (peaReceived * BURY_BPS) / BPS_DENOMINATOR;
        uint256 toStakers = peaReceived - toBurn;

        // Burn 95%
        pea.burn(toBurn);
        totalBurned += toBurn;

        // Send 5% to staking contract
        if (address(staking) != address(0) && toStakers > 0) {
            pea.transfer(address(staking), toStakers);
            staking.distributeYield(toStakers);
            totalDistributedToStakers += toStakers;
        } else {
            // If no staking contract, burn everything
            pea.burn(toStakers);
            totalBurned += toStakers;
        }

        totalBuybacks += 1;

        emit BuybackExecuted(ethConsumed, peaReceived, toBurn, toStakers);
    }

    // ============ V4 Unlock Callback ============

    /**
     * @notice Called by PoolManager during unlock: executes the swap
     * @param data ABI-encoded ETH amount to swap
     */
    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert OnlyPoolManager();

        uint256 ethToSpend = abi.decode(data, (uint256));
        PoolKey memory key = _getPoolKey();

        // ETH = currency0, PEA = currency1 -> zeroForOne = true (sell ETH, buy PEA)
        BalanceDelta delta = poolManager.swap(
            key,
            SwapParams({
                zeroForOne: true,
                amountSpecified: -int256(ethToSpend),           // negative = exact input
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1  // no effective price limit
            }),
            ""
        );

        // Settle: pay ETH to PoolManager
        poolManager.settle{value: uint256(uint128(-delta.amount0()))}();

        // Take: receive PEA from PoolManager
        poolManager.take(key.currency1, address(this), uint256(uint128(delta.amount1())));

        return abi.encode(delta);
    }

    // ============ Internal ============

    function _getPoolKey() internal view returns (PoolKey memory) {
        return PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO,        // Native ETH
            currency1: Currency.wrap(address(pea)),         // PEA
            fee: poolFee,
            tickSpacing: poolTickSpacing,
            hooks: poolHooks
        });
    }

    // ============ View Functions ============

    function getStats() external view returns (
        uint256 _vaultedETH,
        uint256 _totalBurned,
        uint256 _totalDistributedToStakers,
        uint256 _totalBuybacks
    ) {
        return (vaultedETH, totalBurned, totalDistributedToStakers, totalBuybacks);
    }

    // ============ Receive ============

    receive() external payable {
        // Only accept ETH from GridMining through receiveVault()
        revert("Use receiveVault()");
    }
}
