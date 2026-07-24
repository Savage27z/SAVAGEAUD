// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface IGridMining {
    function MIN_DEPLOY() external pure returns (uint256);
    function deployFor(address user, uint8[] calldata blockIds) external payable;
    function currentRoundId() external view returns (uint64);
    function gameStarted() external view returns (bool);
    function rounds(uint64 roundId) external view returns (
        uint256 startTime,
        uint256 endTime,
        uint256 totalDeployed,
        uint256 totalWinnings,
        uint256 winnersDeployed,
        uint8 winningBlock,
        address topMiner,
        uint256 topMinerReward,
        uint256 peapotAmount,
        uint256 topMinerSeed,
        bool settled
    );
}

contract AutoMiner is Ownable, ReentrancyGuard {
    // ============ Constants ============

    uint256 public constant BPS_DENOMINATOR = 10000;
    uint256 public constant MAX_FEE_BPS = 1000;
    uint256 public constant MAX_FLAT_FEE = 0.005 ether;
    uint8 public constant GRID_SIZE = 25;
    uint8 public constant SELECT_STRATEGY_ID = 2;

    // ============ Types ============

    struct StrategyDef {
        uint8 fixedBlocks;  // 0 = user specifies numBlocks, 1-25 = enforced count
        bool exists;
        bool active;
    }

    // ============ State ============

    IGridMining public gridMining;
    address public executor;
    uint256 public executorFeeBps;
    uint256 public executorFlatFee;
    uint256 public minDeploy;           // Cached from GridMining.MIN_DEPLOY()

    mapping(uint8 => StrategyDef) public strategies;
    uint8 public strategyCount;

    struct AutoConfig {
        // Slot 0 (9 bytes used, 23 free)
        uint8 strategyId;              // uint8 - references strategies mapping
        uint8 numBlocks;               // uint8 - resolved block count
        bool active;                   // bool
        uint16 executorFeeBps;         // uint16 - frozen at config time
        uint32 selectedBlockMask;      // uint32 - bitmask for Select strategy (0 = not Select)

        // Slot 1
        uint128 amountPerBlock;        // uint128 (calculated, not user-provided)
        uint64 numRounds;              // uint64 (user-specified execution limit)
        uint64 roundsExecuted;         // uint64 (successful executions count)

        // Slot 2
        uint128 depositAmount;         // uint128 (original deposit for refunds)
        uint32 depositTimestamp;       // uint32 (config creation time)
        uint96 executorFlatFee;        // uint96 (frozen flat fee at config time)
    }

    mapping(address => AutoConfig) public configs;
    mapping(address => uint64) public lastRoundPlayed;

    // Track active users
    address[] public activeUsers;
    mapping(address => uint256) public activeUserIndex;  // index + 1 (0 means not in array)

    // Accumulated fees for executor
    uint256 public accumulatedFees;

    // Gas limits for batch execution
    uint256 public minGasForBatch = 2_000_000;  // Minimum gas to start batch
    uint256 public minGasReserve = 100_000;      // Gas threshold for exit

    // ============ Events ============

    event ConfigUpdated(
        address indexed user,
        uint8 strategyId,
        uint8 numBlocks,
        uint256 amountPerBlock,
        uint256 numRounds,
        uint256 depositAmount,
        bool active,
        uint32 selectedBlockMask
    );
    event ExecutedFor(
        address indexed user,
        uint64 indexed roundId,
        uint8[] blocks,
        uint256 totalDeployed,
        uint256 fee,
        uint256 roundsExecuted
    );
    event ConfigDeactivated(address indexed user, uint256 roundsCompleted);
    event Stopped(address indexed user, uint256 refundAmount, uint256 roundsCompleted);
    event BatchExecuted(uint256 total, uint256 successful, uint256 failed);
    event BatchStopped(uint256 indexed stoppedAtIndex, uint256 total, uint256 successful, uint256 failed);
    event ExecutorUpdated(address indexed oldExecutor, address indexed newExecutor);
    event GridMiningUpdated(address indexed oldGridMining, address indexed newGridMining);
    event ExecutorFeeBpsUpdated(uint256 oldFeeBps, uint256 newFeeBps);
    event ExecutorFlatFeeUpdated(uint256 oldFee, uint256 newFee);
    event FeesCollected(address indexed executor, uint256 amount);
    event StrategyAdded(uint8 indexed strategyId, uint8 fixedBlocks);
    event StrategyUpdated(uint8 indexed strategyId, bool active);

    // ============ Errors ============

    error ZeroAddress();
    error NotExecutor();
    error InvalidNumBlocks();
    error ConfigNotActive();
    error AlreadyPlayedThisRound();
    error GameNotStarted();
    error RoundNotActive();
    error FeeTooHigh();
    error NoFeesToCollect();
    error InvalidBlockCount();
    error DuplicateBlock();
    error InvalidBlockId();
    error ConfigAlreadyActive();
    error InvalidDeposit();
    error InvalidNumRounds();
    error InsufficientDeposit();
    error RoundLimitReached();
    error InvalidStrategy();
    error InvalidFixedBlocks();
    error StrategyNotFound();
    error InsufficientGas();
    error InvalidGasLimits();
    error InvalidBlockMask();

    // ============ Modifiers ============

    modifier onlyExecutor() {
        if (msg.sender != executor) revert NotExecutor();
        _;
    }

    // ============ Constructor ============

    constructor(
        address _gridMining,
        address _executor,
        uint256 _executorFeeBps,
        uint256 _executorFlatFee
    ) Ownable(msg.sender) {
        if (_gridMining == address(0)) revert ZeroAddress();
        if (_executor == address(0)) revert ZeroAddress();
        if (_executorFeeBps > MAX_FEE_BPS) revert FeeTooHigh();
        if (_executorFlatFee > MAX_FLAT_FEE) revert FeeTooHigh();

        gridMining = IGridMining(_gridMining);
        executor = _executor;
        executorFeeBps = _executorFeeBps;
        executorFlatFee = _executorFlatFee;
        minDeploy = IGridMining(_gridMining).MIN_DEPLOY();

        // Seed default strategies: 0=Random, 1=All, 2=Select
        strategies[0] = StrategyDef({fixedBlocks: 0, exists: true, active: true});
        strategies[1] = StrategyDef({fixedBlocks: GRID_SIZE, exists: true, active: true});
        strategies[2] = StrategyDef({fixedBlocks: 0, exists: true, active: true});
        strategyCount = 3;
    }

    // ============ User Functions ============

    /**
     * @notice Set auto-mining configuration with deposit
     * @param strategyId Strategy ID from the registry
     * @param numRounds Number of rounds to execute
     * @param numBlocks Number of blocks (used for strategy 0; ignored for strategy 1 and 2)
     * @param blockMask Bitmask of selected blocks (only used for Select strategy 2; pass 0 otherwise)
     */
    function setConfig(
        uint8 strategyId,
        uint256 numRounds,
        uint8 numBlocks,
        uint32 blockMask
    ) external payable nonReentrant {
        // Validate: Must not have active config (must stop first)
        if (configs[msg.sender].active) revert ConfigAlreadyActive();
        if (msg.value == 0) revert InvalidDeposit();
        if (numRounds == 0) revert InvalidNumRounds();

        // Resolve blocks + validate strategy
        (uint8 actualNumBlocks, uint32 storedBlockMask) = _resolveBlocks(strategyId, numBlocks, blockMask);

        // Calculate amountPerBlock with hybrid fee
        uint256 amountPerBlock = _calculateAmountPerBlock(actualNumBlocks, numRounds);

        // Validate minimum deposit
        if (amountPerBlock < minDeploy) revert InsufficientDeposit();

        // Validate deposit covers all rounds + fees
        {
            uint256 deployPerRound = amountPerBlock * actualNumBlocks;
            uint256 feePerRound = _calculateFee(deployPerRound, uint16(executorFeeBps), uint96(executorFlatFee));
            if (msg.value < (deployPerRound + feePerRound) * numRounds) revert InsufficientDeposit();
        }

        // Store config
        configs[msg.sender] = AutoConfig({
            strategyId: strategyId,
            numBlocks: actualNumBlocks,
            active: true,
            executorFeeBps: uint16(executorFeeBps),
            selectedBlockMask: storedBlockMask,
            amountPerBlock: uint128(amountPerBlock),
            numRounds: uint64(numRounds),
            roundsExecuted: 0,
            depositAmount: uint128(msg.value),
            depositTimestamp: uint32(block.timestamp),
            executorFlatFee: uint96(executorFlatFee)
        });

        // Add to active users
        _addToActiveUsers(msg.sender);

        emit ConfigUpdated(msg.sender, strategyId, actualNumBlocks, amountPerBlock, numRounds, msg.value, true, storedBlockMask);
    }

    /**
     * @notice Stop auto-mining and refund remaining rounds
     */
    function stop() external nonReentrant {
        AutoConfig storage config = configs[msg.sender];

        // Validate active config
        if (!config.active) revert ConfigNotActive();

        // Calculate remaining rounds
        uint256 remainingRounds = config.numRounds - config.roundsExecuted;

        if (remainingRounds == 0) {
            _deactivateUser(msg.sender);
            emit Stopped(msg.sender, 0, config.roundsExecuted);
            return;
        }

        // Calculate refund: cost per round * remaining rounds
        uint256 deployPerRound = config.amountPerBlock * config.numBlocks;
        uint256 feePerRound = _calculateFee(deployPerRound, config.executorFeeBps, config.executorFlatFee);
        uint256 costPerRound = deployPerRound + feePerRound;

        // Use actual remaining deposit (handles rounding dust)
        uint256 totalSpent = costPerRound * config.roundsExecuted;
        uint256 refundAmount = config.depositAmount - totalSpent;

        // Deactivate before transfer
        _deactivateUser(msg.sender);

        // Transfer refund
        if (refundAmount > 0) {
            (bool success, ) = msg.sender.call{value: refundAmount}("");
            require(success, "Transfer failed");
        }

        emit Stopped(msg.sender, refundAmount, config.roundsExecuted);
    }

    // ============ Executor Functions ============

    /**
     * @notice Execute auto-mining for a single user
     * @param user User to deploy for
     * @param blocks Block IDs to deploy to (ignored for Select strategy, contract uses stored mask)
     */
    function executeFor(
        address user,
        uint8[] calldata blocks
    ) external onlyExecutor nonReentrant {
        _executeFor(user, blocks);
    }

    /**
     * @notice Execute auto-mining for multiple users in batch
     * @param users Array of users to deploy for
     * @param blocks Array of block arrays for each user
     * @dev Uses gas-limited inner calls to prevent OOG from reverting entire batch
     */
    function executeBatch(
        address[] calldata users,
        uint8[][] calldata blocks
    ) external onlyExecutor nonReentrant returns (uint256 successCount, uint256 failCount) {
        if (gasleft() < minGasForBatch) revert InsufficientGas();
        require(users.length == blocks.length, "Length mismatch");

        for (uint256 i = 0; i < users.length; i++) {
            // Exit gracefully when running low on gas
            if (gasleft() < minGasReserve) {
                emit BatchStopped(i, users.length, successCount, failCount);
                return (successCount, failCount);
            }

            // Forward remaining gas minus reserve to inner call
            // If inner call runs out, it reverts and gets caught
            uint256 gasToForward = gasleft() - minGasReserve;

            try this.executeForInternal{gas: gasToForward}(users[i], blocks[i]) {
                successCount++;
            } catch {
                failCount++;
            }
        }

        emit BatchExecuted(users.length, successCount, failCount);
    }

    /**
     * @notice Internal execute function callable only by this contract
     */
    function executeForInternal(
        address user,
        uint8[] calldata blocks
    ) external {
        require(msg.sender == address(this), "Only self");
        _executeFor(user, blocks);
    }

    /**
     * @notice Collect accumulated executor fees
     */
    function collectFees() external onlyExecutor {
        uint256 amount = accumulatedFees;
        if (amount == 0) revert NoFeesToCollect();

        accumulatedFees = 0;

        (bool success, ) = executor.call{value: amount}("");
        require(success, "Transfer failed");

        emit FeesCollected(executor, amount);
    }

    // ============ Internal Functions ============

    /**
     * @notice Resolve block count and mask from strategy + params
     */
    function _resolveBlocks(
        uint8 strategyId,
        uint8 numBlocks,
        uint32 blockMask
    ) internal view returns (uint8 actualNumBlocks, uint32 storedBlockMask) {
        StrategyDef storage strat = strategies[strategyId];
        if (!strat.exists || !strat.active) revert InvalidStrategy();

        if (strategyId == SELECT_STRATEGY_ID) {
            if (blockMask == 0) revert InvalidBlockMask();
            if (blockMask >= (1 << GRID_SIZE)) revert InvalidBlockMask();
            actualNumBlocks = _popcount(blockMask);
            storedBlockMask = blockMask;
        } else if (strat.fixedBlocks > 0) {
            actualNumBlocks = strat.fixedBlocks;
        } else {
            if (numBlocks == 0 || numBlocks > GRID_SIZE) revert InvalidNumBlocks();
            actualNumBlocks = numBlocks;
        }
    }

    /**
     * @notice Calculate amountPerBlock with hybrid fee (% first, fallback to flat)
     */
    function _calculateAmountPerBlock(
        uint8 actualNumBlocks,
        uint256 numRounds
    ) internal view returns (uint256 amountPerBlock) {
        uint256 totalBlocks = uint256(actualNumBlocks) * numRounds;

        // Try percentage
        amountPerBlock = (msg.value * BPS_DENOMINATOR) / (totalBlocks * (BPS_DENOMINATOR + executorFeeBps));

        // Check if flat fee should override
        uint256 pctFee = (amountPerBlock * actualNumBlocks * executorFeeBps) / BPS_DENOMINATOR;
        if (pctFee < executorFlatFee) {
            // Flat fee wins — recalculate
            uint256 totalFlatFees = executorFlatFee * numRounds;
            if (msg.value <= totalFlatFees) revert InsufficientDeposit();
            amountPerBlock = (msg.value - totalFlatFees) / totalBlocks;
        }
    }

    function _executeFor(address user, uint8[] calldata blocks) internal {
        AutoConfig storage config = configs[user];

        // Validations
        if (!config.active) revert ConfigNotActive();
        if (!gridMining.gameStarted()) revert GameNotStarted();

        uint64 currentRound = gridMining.currentRoundId();
        if (lastRoundPlayed[user] >= currentRound) revert AlreadyPlayedThisRound();

        // Check round limit before execution
        if (config.roundsExecuted >= config.numRounds) {
            _deactivateUser(user);
            revert RoundLimitReached();
        }

        // Calculate costs using frozen hybrid fee
        uint256 deployAmount = config.amountPerBlock * config.numBlocks;
        uint256 fee = _calculateFee(deployAmount, config.executorFeeBps, config.executorFlatFee);

        // Check round is still active
        (, uint256 endTime, , , , , , , , , bool settled) = gridMining.rounds(currentRound);
        if (settled || block.timestamp >= endTime) revert RoundNotActive();

        // Accumulate fees
        accumulatedFees += fee;
        lastRoundPlayed[user] = currentRound;

        // Deploy via GridMining — branch on strategy type
        if (config.selectedBlockMask != 0) {
            // Select strategy: contract is authoritative, build blocks from stored mask
            uint8[] memory deployBlocks = _maskToBlocks(config.selectedBlockMask, config.numBlocks);
            gridMining.deployFor{value: deployAmount}(user, deployBlocks);

            config.roundsExecuted++;
            if (config.roundsExecuted >= config.numRounds) {
                _deactivateUser(user);
            }
            emit ExecutedFor(user, currentRound, deployBlocks, deployAmount, fee, config.roundsExecuted);
        } else {
            // Random/All: use executor-provided blocks with validation
            if (blocks.length != config.numBlocks) revert InvalidBlockCount();

            // Validate block IDs: unique and in range
            uint256 usedMask = 0;
            for (uint256 i = 0; i < blocks.length; i++) {
                if (blocks[i] >= GRID_SIZE) revert InvalidBlockId();
                uint256 bit = 1 << blocks[i];
                if ((usedMask & bit) != 0) revert DuplicateBlock();
                usedMask |= bit;
            }

            gridMining.deployFor{value: deployAmount}(user, blocks);

            config.roundsExecuted++;
            if (config.roundsExecuted >= config.numRounds) {
                _deactivateUser(user);
            }
            emit ExecutedFor(user, currentRound, blocks, deployAmount, fee, config.roundsExecuted);
        }
    }

    /**
     * @notice Hybrid fee: max(flatFee, percentageFee)
     */
    function _calculateFee(
        uint256 deployAmount,
        uint16 feeBps,
        uint96 flatFee
    ) internal pure returns (uint256) {
        uint256 pctFee = (deployAmount * feeBps) / BPS_DENOMINATOR;
        return pctFee > flatFee ? pctFee : flatFee;
    }

    /**
     * @notice Count set bits in a bitmask
     */
    function _popcount(uint32 x) internal pure returns (uint8 count) {
        while (x != 0) {
            x &= x - 1;
            count++;
        }
    }

    /**
     * @notice Convert a block bitmask to a uint8[] array
     */
    function _maskToBlocks(uint32 mask, uint8 count) internal pure returns (uint8[] memory blockIds) {
        blockIds = new uint8[](count);
        uint256 idx = 0;
        for (uint8 i = 0; i < GRID_SIZE; i++) {
            if ((mask & (1 << i)) != 0) {
                blockIds[idx++] = i;
            }
        }
    }

    function _deactivateUser(address user) internal {
        configs[user].active = false;
        _removeFromActiveUsers(user);
        emit ConfigDeactivated(user, configs[user].roundsExecuted);
    }

    function _addToActiveUsers(address user) internal {
        if (activeUserIndex[user] == 0) {
            activeUsers.push(user);
            activeUserIndex[user] = activeUsers.length;  // Store index + 1
        }
    }

    function _removeFromActiveUsers(address user) internal {
        uint256 indexPlusOne = activeUserIndex[user];
        if (indexPlusOne == 0) return;

        uint256 index = indexPlusOne - 1;
        uint256 lastIndex = activeUsers.length - 1;

        if (index != lastIndex) {
            // Move last element to deleted position
            address lastUser = activeUsers[lastIndex];
            activeUsers[index] = lastUser;
            activeUserIndex[lastUser] = indexPlusOne;
        }

        activeUsers.pop();
        activeUserIndex[user] = 0;
    }

    // ============ Admin Functions ============

    function setExecutor(address _executor) external onlyOwner {
        if (_executor == address(0)) revert ZeroAddress();

        address old = executor;
        executor = _executor;

        emit ExecutorUpdated(old, _executor);
    }

    function setGridMining(address _gridMining) external onlyOwner {
        if (_gridMining == address(0)) revert ZeroAddress();

        address old = address(gridMining);
        gridMining = IGridMining(_gridMining);
        minDeploy = IGridMining(_gridMining).MIN_DEPLOY();

        emit GridMiningUpdated(old, _gridMining);
    }

    function addStrategy(uint8 fixedBlocks) external onlyOwner returns (uint8 strategyId) {
        if (fixedBlocks > GRID_SIZE) revert InvalidFixedBlocks();

        strategyId = strategyCount;
        strategies[strategyId] = StrategyDef({
            fixedBlocks: fixedBlocks,
            exists: true,
            active: true
        });
        strategyCount++;

        emit StrategyAdded(strategyId, fixedBlocks);
    }

    function setStrategyActive(uint8 strategyId, bool active) external onlyOwner {
        if (!strategies[strategyId].exists) revert StrategyNotFound();
        strategies[strategyId].active = active;
        emit StrategyUpdated(strategyId, active);
    }

    function setExecutorFeeBps(uint256 _feeBps) external onlyOwner {
        if (_feeBps > MAX_FEE_BPS) revert FeeTooHigh();

        uint256 old = executorFeeBps;
        executorFeeBps = _feeBps;

        emit ExecutorFeeBpsUpdated(old, _feeBps);
    }

    function setExecutorFlatFee(uint256 _flatFee) external onlyOwner {
        if (_flatFee > MAX_FLAT_FEE) revert FeeTooHigh();

        uint256 old = executorFlatFee;
        executorFlatFee = _flatFee;

        emit ExecutorFlatFeeUpdated(old, _flatFee);
    }

    function setGasLimits(uint256 _minForBatch, uint256 _minReserve) external onlyOwner {
        if (_minForBatch < 500_000) revert InvalidGasLimits();
        if (_minReserve < 50_000 || _minReserve >= _minForBatch) revert InvalidGasLimits();
        minGasForBatch = _minForBatch;
        minGasReserve = _minReserve;
    }

    // ============ View Functions ============

    /**
     * @notice Get user's full auto-mining state
     */
    function getUserState(address user) external view returns (
        AutoConfig memory config,
        uint64 lastRound,
        uint256 costPerRound,
        uint256 roundsRemaining,
        uint256 totalRefundable
    ) {
        config = configs[user];
        lastRound = lastRoundPlayed[user];

        if (config.amountPerBlock > 0 && config.numBlocks > 0) {
            uint256 deployAmount = config.amountPerBlock * config.numBlocks;
            uint256 fee = _calculateFee(deployAmount, config.executorFeeBps, config.executorFlatFee);
            costPerRound = deployAmount + fee;

            if (config.roundsExecuted < config.numRounds) {
                roundsRemaining = config.numRounds - config.roundsExecuted;
                totalRefundable = costPerRound * roundsRemaining;
            }
        }
    }

    /**
     * @notice Get rounds remaining for a user
     */
    function getRoundsRemaining(address user) external view returns (uint256) {
        AutoConfig storage config = configs[user];
        if (config.roundsExecuted >= config.numRounds) return 0;
        return config.numRounds - config.roundsExecuted;
    }

    /**
     * @notice Get execution progress for a user
     */
    function getConfigProgress(address user) external view returns (
        bool active,
        uint256 numRounds,
        uint256 roundsExecuted,
        uint256 roundsRemaining,
        uint256 percentComplete
    ) {
        AutoConfig storage config = configs[user];
        active = config.active;
        numRounds = config.numRounds;
        roundsExecuted = config.roundsExecuted;

        if (roundsExecuted >= numRounds) {
            roundsRemaining = 0;
            percentComplete = 100;
        } else {
            roundsRemaining = numRounds - roundsExecuted;
            percentComplete = (roundsExecuted * 100) / numRounds;
        }
    }

    /**
     * @notice Get strategy definition
     */
    function getStrategy(uint8 strategyId) external view returns (uint8 fixedBlocks, bool exists, bool active) {
        StrategyDef storage s = strategies[strategyId];
        return (s.fixedBlocks, s.exists, s.active);
    }

    /**
     * @notice Get number of active users
     */
    function getActiveUserCount() external view returns (uint256) {
        return activeUsers.length;
    }

    /**
     * @notice Get active users (paginated)
     * @param offset Starting index
     * @param limit Max number to return
     */
    function getActiveUsers(uint256 offset, uint256 limit) external view returns (address[] memory users) {
        uint256 total = activeUsers.length;
        if (offset >= total) return new address[](0);

        uint256 end = offset + limit;
        if (end > total) end = total;
        uint256 count = end - offset;

        users = new address[](count);
        for (uint256 i = 0; i < count; i++) {
            users[i] = activeUsers[offset + i];
        }
    }

    /**
     * @notice Check if user can be executed this round
     */
    function canExecute(address user) external view returns (bool executable, string memory reason) {
        AutoConfig storage config = configs[user];

        if (!config.active) return (false, "Not active");
        if (!gridMining.gameStarted()) return (false, "Game not started");

        uint64 currentRound = gridMining.currentRoundId();
        if (lastRoundPlayed[user] >= currentRound) return (false, "Already played");

        if (config.roundsExecuted >= config.numRounds) return (false, "Round limit reached");

        (, uint256 endTime, , , , , , , , , bool settled) = gridMining.rounds(currentRound);
        if (settled || block.timestamp >= endTime) return (false, "Round not active");

        return (true, "");
    }

    // ============ Receive ============

    receive() external payable {
        // Allow receiving ETH 
    }
}
