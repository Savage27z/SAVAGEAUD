// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IQuiverCoordinator} from "./quiver/interfaces/IQuiverCoordinator.sol";
import {IQuiverConsumer} from "./quiver/interfaces/IQuiverConsumer.sol";
import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IPea {
    function mint(address to, uint256 amount) external;
    function burn(uint256 amount) external;
    function totalMinted() external view returns (uint256);
}

interface ITreasury {
    function receiveVault() external payable;
}


// Two-step transfer, no renounce. Ownership here is the randomness liveness
contract GridMining is IQuiverConsumer, Ownable2Step, ReentrancyGuard {
    // ============ Constants ============

    uint256 public constant ROUND_DURATION = 60 seconds;
    uint256 public constant MIN_DEPLOY = 0.0000025 ether;
    uint256 public constant GRID_SIZE = 25;

    uint256 public constant ADMIN_FEE_BPS = 100;      // 1%
    uint256 public constant VAULT_FEE_BPS = 1000;     // 10%
    uint256 public constant HARVESTING_FEE_BPS = 1000;  // 10%
    uint256 public constant BPS_DENOMINATOR = 10000;

    uint256 public constant ONE_PEA = 1e18;
    uint256 public constant MIN_PEAPOT_ACCUMULATION = ONE_PEA / 10;
    uint256 public constant MAX_PEAPOT_ACCUMULATION = ONE_PEA;
    uint256 public peapotAccumulation = ONE_PEA / 10;
    uint256 public constant PEAPOT_CHANCE = 333;
    uint256 public constant MAX_SUPPLY = 3_000_000 * ONE_PEA;

    // ============ Randomness Config (Pyth-inherited commit-reveal) ============

    /// @dev Both owner-settable. Ops rule:
    ///      rotating the PROVIDER mid-pending-request is safe (old request stays
    ///      mapped); rotating the COORDINATOR mid-pending requires timing — the callback gate
    ///      checks the current coordinator, so settle or emergency-reset first.
    IQuiverCoordinator public quiver;
    address public provider;

    // ============ External Contracts ============

    IPea public pea;
    ITreasury public treasury;
    address public feeCollector;
    address public autoMiner;

    // ============ Board State ============

    uint64 public currentRoundId;
    bool public gameStarted;
    uint256 public maxMinersForSingleWinner = 2000;

    // ============ Round State ============

    struct Round {
        uint256 startTime;
        uint256 endTime;
        uint256[25] deployed;           // ETH per block
        uint256 totalDeployed;
        uint256 totalWinnings;          // After fees, for winners to claim
        uint256 winnersDeployed;        // Amount on winning block
        uint8 winningBlock;
        address topMiner;               // Single winner address, or address(0) if split
        uint256 topMinerReward;         // PEA reward amount
        uint256 peapotAmount;          // Peapot payout if triggered
        uint256 topMinerSeed;
        bool settled;
        uint256 minerCount;             // Number of unique deployers this round
    }

    /// @dev Quiver request state, kept out of the Round struct: the auto-generated
    ///      rounds() getter is prefix-decoded by AutoMiner and already near the
    ///      stack-depth limit. A separate single-slot record avoids both hazards.
    struct RequestState {
        address provider;               // provider serving the active request
        uint64 seq;                     // Quiver sequence number (per-provider, starts at 1)
        bool pending;
    }

    struct FeeCalc {
        uint256 adminFee;
        uint256 vaultAmount;
        uint256 totalWinnings;
    }

    mapping(uint64 => Round) public rounds;
    /// @dev roundId => active randomness request for that round.
    mapping(uint64 => RequestState) public roundRequests;
    /// @dev keccak256(provider, seq) => roundId. Quiver sequence numbers are PER-PROVIDER
    mapping(bytes32 => uint64) public requestToRound;

    // ============ Miner State ============

    struct Miner {
        uint256 deployedMask;           // Bitmask of blocks deployed to
        uint256 amountPerBlock;         // ETH per block
        bool checkpointed;
    }

    // roundId => user => Miner
    mapping(uint64 => mapping(address => Miner)) public miners;

    // roundId => deployIndex => deployer address
    mapping(uint64 => mapping(uint256 => address)) internal minerByIndex;

    // ============ Global Rewards State ============

    uint256 public peapotPool;

    // Harvesting fee redistribution
    uint256 public totalUnclaimed;                              
    uint256 public accHarvestingPerUnclaimed;                     
    mapping(address => uint256) public userHarvestingDebt;
    mapping(address => uint256) public userUnclaimedPEA;
    mapping(address => uint256) public userUnclaimedETH;
    mapping(address => uint256) public userHarvestedPEA;
    mapping(address => uint64) public userLastRound;

    // ============ Events ============

    event GameStarted(uint64 indexed roundId, uint256 startTime, uint256 endTime);
    event Deployed(uint64 indexed roundId, address indexed user, uint256 amountPerBlock, uint256 blockMask, uint256 totalAmount);
    event ResetRequested(
        uint64 indexed roundId,
        address indexed provider,
        uint64 sequenceNumber,
        bytes32 userRandom,
        uint128 feePaid
    );
    event RoundSettled(
        uint64 indexed roundId,
        uint8 winningBlock,
        address topMiner,
        uint256 totalWinnings,
        uint256 topMinerReward,
        uint256 peapotAmount,
        bool isSplit,
        uint256 topMinerSeed,
        uint256 winnersDeployed
    );
    event DeployedFor(
        uint64 indexed roundId,
        address indexed user,
        address indexed executor,
        uint256 amountPerBlock,
        uint256 blockMask,
        uint256 totalAmount
    );
    event AutoMinerUpdated(address indexed oldAutoMiner, address indexed newAutoMiner);
    event Checkpointed(uint64 indexed roundId, address indexed user, uint256 ethReward, uint256 peaReward);
    event ClaimedETH(address indexed user, uint256 amount);
    event ClaimedPEA(address indexed user, uint256 minedPea, uint256 harvestedPea, uint256 fee, uint256 net);
    event EmergencyVRFRequested(uint64 indexed roundId, uint64 oldSeq, uint64 newSeq, address indexed provider);
    event PeapotAccumulationUpdated(uint256 oldValue, uint256 newValue);
    event CoordinatorUpdated(address indexed oldCoordinator, address indexed newCoordinator);
    event ProviderUpdated(address indexed oldProvider, address indexed newProvider);

    // ============ Errors ============

    error GameNotStarted();
    error GameAlreadyStarted();
    error RoundNotActive();
    error RoundNotEnded();
    error RoundAlreadySettled();
    error RoundNotSettled();
    error AlreadyCheckpointed();
    error InvalidBlockId();
    error InsufficientDeployAmount();
    error NoBlocksSelected();
    error AlreadyDeployedThisRound();
    error NothingToClaim();
    error TransferFailed();
    error InvalidVRFRequest();
    error MaxSupplyReached();
    error VRFAlreadyRequested();
    error NotAutoMiner();
    error MinimumThresholdTooLow();
    error EmergencyTooEarly();
    error InvalidPeapotAccumulation();
    error ZeroAddress();
    error CallerNotCoordinator(address caller);
    error InsufficientFeeAttached(uint256 provided, uint256 required);
    error RenounceDisabled();

    // ============ Constructor ============

    constructor(
        address _coordinator,
        address _provider,
        address _pea,
        address _treasury,
        address _feeCollector
    ) Ownable(msg.sender) {
        if (_coordinator == address(0)) revert ZeroAddress();
        if (_provider == address(0)) revert ZeroAddress();
        if (_treasury == address(0)) revert ZeroAddress();
        if (_feeCollector == address(0)) revert ZeroAddress();
        if (_pea == address(0)) revert ZeroAddress();

        quiver = IQuiverCoordinator(_coordinator);
        provider = _provider;
        pea = IPea(_pea);
        treasury = ITreasury(_treasury);
        feeCollector = _feeCollector;
    }

    // ============ Admin Functions ============

    /// @notice Replace the Quiver coordinator.
    /// @dev Do not rotate while a request is pending. The callback gate checks the
    ///      current coordinator, so the old one's delivery would revert.
    function setCoordinator(address _coordinator) external onlyOwner {
        if (_coordinator == address(0)) revert ZeroAddress();
        address old = address(quiver);
        quiver = IQuiverCoordinator(_coordinator);
        emit CoordinatorUpdated(old, _coordinator);
    }

    /// @notice Replace the default randomness provider.
    /// @dev Safe mid-pending: the in-flight request stays keyed to its own provider.
    function setProvider(address _provider) external onlyOwner {
        if (_provider == address(0)) revert ZeroAddress();
        address old = provider;
        provider = _provider;
        emit ProviderUpdated(old, _provider);
    }

    /// @notice Disabled: ownership is the randomness liveness failover
    function renounceOwnership() public view override onlyOwner {
        revert RenounceDisabled();
    }

    function setFeeCollector(address _feeCollector) external onlyOwner {
        if (_feeCollector == address(0)) revert ZeroAddress();
        feeCollector = _feeCollector;
    }

    function setTreasury(address _treasury) external onlyOwner {
        if (_treasury == address(0)) revert ZeroAddress();
        treasury = ITreasury(_treasury);
    }

    function setAutoMiner(address _autoMiner) external onlyOwner {
        address old = autoMiner;
        autoMiner = _autoMiner;
        emit AutoMinerUpdated(old, _autoMiner);
    }

    function setPeapotAccumulation(uint256 _accumulation) external onlyOwner {
        if (_accumulation < MIN_PEAPOT_ACCUMULATION || _accumulation > MAX_PEAPOT_ACCUMULATION) {
            revert InvalidPeapotAccumulation();
        }
        uint256 oldValue = peapotAccumulation;
        peapotAccumulation = _accumulation;
        emit PeapotAccumulationUpdated(oldValue, _accumulation);
    }

    function setMaxMinersForSingleWinner(uint256 _max) external onlyOwner {
        if (_max < 500) revert MinimumThresholdTooLow();
        maxMinersForSingleWinner = _max;
    }

    function startFirstRound() external onlyOwner {
        // Coordinator + provider are constructor-guaranteed non-zero
        if (gameStarted) revert GameAlreadyStarted();

        gameStarted = true;
        currentRoundId = 1;

        Round storage round = rounds[1];
        round.startTime = block.timestamp;
        round.endTime = block.timestamp + ROUND_DURATION;

        emit GameStarted(1, round.startTime, round.endTime);
    }

    // ============ Core Game Functions ============

    /**
     * @notice Deploy ETH to selected blocks in the current round
     * @param blockIds Array of block IDs (0-24) to deploy to
     * @dev Deploys msg.value / blockIds.length to each selected block
     */
    function deploy(uint8[] calldata blockIds) external payable nonReentrant {
        if (!gameStarted) revert GameNotStarted();

        // Auto-checkpoint previous round
        _autoCheckpointPrevious(msg.sender);

        Round storage round = rounds[currentRoundId];

        // Check round is active
        if (block.timestamp >= round.endTime) revert RoundNotActive();

        uint256 numBlocks = blockIds.length;
        if (numBlocks == 0) revert NoBlocksSelected();

        uint256 amountPerBlock = msg.value / numBlocks;
        if (amountPerBlock < MIN_DEPLOY) revert InsufficientDeployAmount();

        Miner storage miner = miners[currentRoundId][msg.sender];

        // One deploy per round
        if (miner.deployedMask != 0) revert AlreadyDeployedThisRound();

        // Assign deploy index for lazy top miner resolution
        minerByIndex[currentRoundId][round.minerCount] = msg.sender;
        round.minerCount++;

        uint256 blockMask;
        uint256 totalAmount;

        for (uint256 i; i < numBlocks; ) {
            uint8 blockId = blockIds[i];
            if (blockId >= GRID_SIZE) revert InvalidBlockId();

            uint256 bit = 1 << blockId;
            if ((blockMask & bit) != 0) revert InvalidBlockId();
            blockMask |= bit;

            uint256 currentDeployed = round.deployed[blockId];
            round.deployed[blockId] = currentDeployed + amountPerBlock;

            unchecked {
                totalAmount += amountPerBlock;
                ++i;
            }
        }

        // Write miner state
        miner.deployedMask = blockMask;
        miner.amountPerBlock = amountPerBlock;

        round.totalDeployed += totalAmount;

        // Track user's last played round
        userLastRound[msg.sender] = currentRoundId;

        emit Deployed(currentRoundId, msg.sender, amountPerBlock, blockMask, totalAmount);
    }

    /**
    * @notice Deploy ETH to selected blocks on behalf of a user (AutoMiner only)
    * @param user The address to credit deposits to
    * @param blockIds Array of block IDs (0-24) to deploy to
    * @dev Deploys msg.value / blockIds.length to each selected block
    */
    function deployFor(address user, uint8[] calldata blockIds) external payable nonReentrant {
        if (msg.sender != autoMiner) revert NotAutoMiner();
        if (user == address(0)) revert ZeroAddress();
        if (!gameStarted) revert GameNotStarted();

        // Auto-checkpoint previous round for the USER
        _autoCheckpointPrevious(user);

        Round storage round = rounds[currentRoundId];

        // Check round is active
        if (block.timestamp >= round.endTime) revert RoundNotActive();

        uint256 numBlocks = blockIds.length;
        if (numBlocks == 0) revert NoBlocksSelected();

        uint256 amountPerBlock = msg.value / numBlocks;
        if (amountPerBlock < MIN_DEPLOY) revert InsufficientDeployAmount();

        // Use USER's miner state
        Miner storage miner = miners[currentRoundId][user];

        // One deploy per round
        if (miner.deployedMask != 0) revert AlreadyDeployedThisRound();

        // Assign deploy index for lazy top miner resolution
        minerByIndex[currentRoundId][round.minerCount] = user;
        round.minerCount++;

        uint256 blockMask;
        uint256 totalAmount;

        for (uint256 i; i < numBlocks; ) {
            uint8 blockId = blockIds[i];
            if (blockId >= GRID_SIZE) revert InvalidBlockId();

            uint256 bit = 1 << blockId;
            if ((blockMask & bit) != 0) revert InvalidBlockId();
            blockMask |= bit;

            uint256 currentDeployed = round.deployed[blockId];
            round.deployed[blockId] = currentDeployed + amountPerBlock;

            unchecked {
                totalAmount += amountPerBlock;
                ++i;
            }
        }

        // Write miner state
        miner.deployedMask = blockMask;
        miner.amountPerBlock = amountPerBlock;

        round.totalDeployed += totalAmount;

        // Track USER's last played round
        userLastRound[user] = currentRoundId;

        emit DeployedFor(currentRoundId, user, msg.sender, amountPerBlock, blockMask, totalAmount);
    }

    /**
     * @notice End the current round and request settlement randomness from Quiver
     * @dev Anyone can call this after round ends. Payable: attach getFee(provider)
     *      as msg.value. Exactly the fee is forwarded and any excess is refunded to the caller.
     */
    function reset() external payable nonReentrant {
        if (!gameStarted) revert GameNotStarted();

        Round storage round = rounds[currentRoundId];

        if (block.timestamp < round.endTime) revert RoundNotEnded();
        if (round.settled) revert RoundAlreadySettled();
        if (roundRequests[currentRoundId].pending) revert VRFAlreadyRequested();

        // Handle empty round (no one deployed) — synchronous, no randomness needed.
        // Refund any attached fee so it can't strand in the contract.
        if (round.totalDeployed == 0) {
            round.settled = true;
            _startNextRound();
            if (msg.value > 0) _safeTransferETH(msg.sender, msg.value);
            return;
        }

        _requestSettlement(currentRoundId);
    }

    /// @dev Request settlement randomness from the current provider. The fee rides in
    ///      as msg.value: forward EXACTLY the fee (the coordinator refunds overpayment
    ///      to this contract, not the caller) and refund the excess here.
    function _requestSettlement(uint64 roundId) internal {
        bytes32 userRandom = keccak256(
            abi.encode(
                address(this), roundId, roundRequests[roundId].seq, block.timestamp, blockhash(block.number - 1), msg.sender, gasleft()
            )
        );

        address provider_ = provider;
        uint128 fee = quiver.getFee(provider_);
        if (msg.value < fee) revert InsufficientFeeAttached(msg.value, fee);

        uint64 seq = quiver.requestWithCallback{value: fee}(provider_, userRandom);

        roundRequests[roundId] = RequestState({provider: provider_, seq: seq, pending: true});
        requestToRound[_requestKey(provider_, seq)] = roundId;

        emit ResetRequested(roundId, provider_, seq, userRandom, fee);

        uint256 excess = msg.value - fee;
        if (excess > 0) _safeTransferETH(msg.sender, excess);
    }

    /// @notice Quiver push-flow delivery point.
    /// @dev Only the coordinator may call. Never reverts on stale/unknown sequences.
    ///      The emergency re-request path depends on silent drops.
    function quiverCallback(uint64 sequenceNumber, address provider_, bytes32 randomNumber) external override {
        if (msg.sender != address(quiver)) revert CallerNotCoordinator(msg.sender);
        _fulfillRandomness(sequenceNumber, provider_, randomNumber);
    }

    function _fulfillRandomness(uint64 sequenceNumber, address provider_, bytes32 randomNumber) internal {
        uint64 roundId = requestToRound[_requestKey(provider_, sequenceNumber)];
        if (roundId == 0) return; // stale/unknown request = silent drop

        Round storage round = rounds[roundId];
        if (round.settled) return; // replay guard

        // Expand single bytes32 into the 3 words to deliver
        uint256[3] memory randomWords = deriveWords(randomNumber);

        uint8 winningBlock = uint8(randomWords[0] % GRID_SIZE);
        round.winningBlock = winningBlock;
        round.winnersDeployed = round.deployed[winningBlock];

        if (round.winnersDeployed == 0) {
            roundRequests[roundId].pending = false;
            _settleNoWinners(roundId, round, winningBlock);
            return;
        }

        FeeCalc memory fees = _calculateSettlementFees(round.totalDeployed, round.winnersDeployed);
        round.totalWinnings = fees.totalWinnings;

        bool isSplit = _processMinting(round, randomWords);

        round.settled = true;
        roundRequests[roundId].pending = false;

        _safeTransferETH(feeCollector, fees.adminFee);
        treasury.receiveVault{value: fees.vaultAmount}();

        _startNextRound();

        emit RoundSettled(roundId, winningBlock, round.topMiner, round.totalWinnings, round.topMinerReward, round.peapotAmount, isSplit, round.topMinerSeed, round.winnersDeployed);
    }

    function deriveWords(bytes32 randomNumber) public pure returns (uint256[3] memory words) {
        for (uint256 i = 0; i < 3; i++) {
            words[i] = uint256(keccak256(abi.encode(randomNumber, i)));
        }
    }

    /// @dev Deterministic key for a (provider, sequenceNumber) request.
    function _requestKey(address provider_, uint64 sequenceNumber) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(provider_, sequenceNumber));
    }

    function _settleNoWinners(uint64 roundId, Round storage round, uint8 winningBlock) internal {
        uint256 adminFee = (round.totalDeployed * ADMIN_FEE_BPS) / BPS_DENOMINATOR;
        uint256 vaultAmount = round.totalDeployed - adminFee;

        round.settled = true;

        _safeTransferETH(feeCollector, adminFee);
        treasury.receiveVault{value: vaultAmount}();

        _startNextRound();

        emit RoundSettled(roundId, winningBlock, address(0), 0, 0, 0, false, 0, 0);
    }

    function _calculateSettlementFees(uint256 totalDeployed, uint256 winnersDeployed) internal pure returns (FeeCalc memory) {
        uint256 losersPool = totalDeployed - winnersDeployed;
        uint256 adminFee = (totalDeployed * ADMIN_FEE_BPS) / BPS_DENOMINATOR;
        uint256 losersAdminShare = (losersPool * ADMIN_FEE_BPS) / BPS_DENOMINATOR;
        uint256 losersAfterAdmin = losersPool - losersAdminShare;
        uint256 vaultAmount = (losersAfterAdmin * VAULT_FEE_BPS) / BPS_DENOMINATOR;
        uint256 totalWinnings = losersAfterAdmin - vaultAmount;

        return FeeCalc(adminFee, vaultAmount, totalWinnings);
    }

    function _processMinting(Round storage round, uint256[3] memory randomWords) internal returns (bool isSplit) {
        isSplit = (randomWords[1] % 2 == 0);

        // Cap combined mint to remaining supply. Avoid revert near MAX_SUPPLY
        uint256 remaining = MAX_SUPPLY - pea.totalMinted();
        uint256 mintAmount = ONE_PEA > remaining ? remaining : ONE_PEA;
        remaining -= mintAmount;
        uint256 peapotMint = peapotAccumulation > remaining ? remaining : peapotAccumulation;

        round.topMinerSeed = randomWords[1];
        round.topMinerReward = mintAmount;
        round.topMiner = isSplit ? address(0) : address(1);

        if (randomWords[2] % PEAPOT_CHANCE == 0 && peapotPool > 0) {
            round.peapotAmount = peapotPool;
            peapotPool = 0;
        }

        peapotPool += peapotMint;

        uint256 totalMint = mintAmount + peapotMint;
        if (totalMint > 0) {
            pea.mint(address(this), totalMint);
        }
    }

    function _checkpoint(uint64 roundId, address user) internal {
        Round storage round = rounds[roundId];
        Miner storage miner = miners[roundId][user];

        // Skip if already checkpointed or round not settled
        if (miner.checkpointed || !round.settled) return;

        uint8 winningBlock = round.winningBlock;

        // Bitmask check
        uint256 userDeployed = (miner.deployedMask & (1 << winningBlock)) != 0
            ? miner.amountPerBlock
            : 0;

        // If user didn't deploy to winning block, mark as checkpointed and return
        if (userDeployed == 0) {
            miner.checkpointed = true;
            emit Checkpointed(roundId, user, 0, 0);
            return;
        }

        uint256 winnersDeployed = round.winnersDeployed;

        // Calculate ETH rewards: proportional share of actual retained ETH
        uint256 ethReward;
        unchecked {
            uint256 claimablePool = _getClaimablePool(round.totalDeployed, winnersDeployed);
            ethReward = (claimablePool * userDeployed) / winnersDeployed;
        }

        // Calculate PEA rewards
        uint256 peaReward;

        if (round.topMiner == address(0)) {
            peaReward = (round.topMinerReward * userDeployed) / winnersDeployed;
        } else if (round.topMiner == address(1)) {
            if (round.minerCount > maxMinersForSingleWinner) {
                // Too many miners: force proportional split
                round.topMiner = address(0);
                peaReward = (round.topMinerReward * userDeployed) / winnersDeployed;
            } else {
                // Safe to iterate: resolve single winner
                _resolveTopMiner(roundId, round);
                if (round.topMiner == user) {
                    peaReward = round.topMinerReward;
                }
            }
        } else if (round.topMiner == user) {
            peaReward = round.topMinerReward;
        }

        if (round.peapotAmount != 0) {
            peaReward += (round.peapotAmount * userDeployed) / winnersDeployed;
        }

        miner.checkpointed = true;

        // Snapshot pending harvested rewards before modifying unclaimed or debt
        // This converts the accumulator delta into userHarvestedPEA before debt is overwritten
        _updateHarvestingRewards(user);

        // Conditional unclaimed updates
        if (ethReward != 0) {
            userUnclaimedETH[user] += ethReward;
        }
        if (peaReward != 0) {
            userUnclaimedPEA[user] += peaReward;
            totalUnclaimed += peaReward;
        }

        // Update user's harvesting debt
        userHarvestingDebt[user] = accHarvestingPerUnclaimed;

        emit Checkpointed(roundId, user, ethReward, peaReward);
    }

    /**
     * @notice Checkpoint rewards for a specific round
     * @param roundId The round to checkpoint
     */
    function checkpoint(uint64 roundId) external nonReentrant {
        _checkpoint(roundId, msg.sender);
    }

    function _autoCheckpointPrevious(address user) internal {
        uint64 lastRound = userLastRound[user];
        if (lastRound == 0) return;
        if (lastRound >= currentRoundId) return;

        _checkpoint(lastRound, user);
    }

    /**
     * @notice Claim accumulated ETH rewards
     */
    function claimETH() external nonReentrant {
        // Auto-checkpoint previous round
        _autoCheckpointPrevious(msg.sender);

        uint256 amount = userUnclaimedETH[msg.sender];
        if (amount == 0) revert NothingToClaim();

        // Safety net: cap at contract balance to prevent revert from rounding dust
        uint256 balance = address(this).balance;
        if (amount > balance) {
            amount = balance;
        }

        userUnclaimedETH[msg.sender] = 0;

        _safeTransferETH(msg.sender, amount);

        emit ClaimedETH(msg.sender, amount);
    }

    /**
     * @notice Claim accumulated PEA rewards with harvesting fee
     */
    function claimPEA() external nonReentrant {
        // Auto-checkpoint previous round
        _autoCheckpointPrevious(msg.sender);

        // First, update user's harvesting bonus
        _updateHarvestingRewards(msg.sender);

        uint256 minedPEA = userUnclaimedPEA[msg.sender];
        uint256 harvestedPEA = userHarvestedPEA[msg.sender];
        uint256 gross = minedPEA + harvestedPEA;

        if (gross == 0) revert NothingToClaim();

        // Calculate harvesting fee (only on mined, not on harvested bonus)
        uint256 fee = 0;
        if (minedPEA > 0 && totalUnclaimed > 0) {
            fee = (minedPEA * HARVESTING_FEE_BPS) / BPS_DENOMINATOR;

            // Distribute fee to remaining unclaimed holders
            // Subtract user's unclaimed first since they're claiming
            uint256 remainingUnclaimed = totalUnclaimed - minedPEA;
            if (remainingUnclaimed > 0) {
                accHarvestingPerUnclaimed += (fee * 1e18) / remainingUnclaimed;
            } else {
                // No other unclaimed holders: burn the fee instead of losing it
                pea.burn(fee);
            }
        }

        uint256 net = gross - fee;

        // Safety net: cap at contract PEA balance to prevent revert from rounding dust
        uint256 contractPeaBalance = IERC20(address(pea)).balanceOf(address(this));
        if (net > contractPeaBalance) {
            net = contractPeaBalance;
        }

        // Update state
        totalUnclaimed -= minedPEA;
        userUnclaimedPEA[msg.sender] = 0;
        userHarvestedPEA[msg.sender] = 0;
        userHarvestingDebt[msg.sender] = accHarvestingPerUnclaimed;

        // Transfer PEA
        require(IERC20(address(pea)).transfer(msg.sender, net), "Transfer failed");

        emit ClaimedPEA(msg.sender, minedPEA, harvestedPEA, fee, net);
    }

    /**
     * @notice Re-request VRF if the original request wasn't fulfilled within 1 hour
     * @dev Anyone can call this after the timeout period
     */
    function emergencyResetVRF() external payable nonReentrant {
        if (!gameStarted) revert GameNotStarted();

        Round storage round = rounds[currentRoundId];
        RequestState storage req = roundRequests[currentRoundId];

        // Must have a pending randomness request
        if (!req.pending) revert InvalidVRFRequest();

        // Must not be already settled
        if (round.settled) revert RoundAlreadySettled();

        // Must be at least 1 hour since round ended
        if (block.timestamp < round.endTime + 1 hours) revert EmergencyTooEarly();

        // Unmap the old request: if its reveal ever lands, _fulfillRandomness
        // resolves roundId 0 and drops it silently. Note the old provider is used
        // for the key, the owner may have rotated `provider` since the request.
        uint64 oldSeq = req.seq;
        delete requestToRound[_requestKey(req.provider, oldSeq)];

        // Re-request from the CURRENT provider (owner rotates via setProvider if
        // the original is dead/exhausted.
        _requestSettlement(currentRoundId);

        emit EmergencyVRFRequested(currentRoundId, oldSeq, req.seq, req.provider);
    }

    // ============ Internal Functions ============

    function _startNextRound() internal {
        currentRoundId += 1;

        Round storage nextRound = rounds[currentRoundId];
        nextRound.startTime = block.timestamp;
        nextRound.endTime = block.timestamp + ROUND_DURATION;

        emit GameStarted(currentRoundId, nextRound.startTime, nextRound.endTime);
    }


    function _getTopMinerSample(uint64 roundId) internal view returns (uint256) {
        Round storage round = rounds[roundId];

        return round.topMinerSeed % round.winnersDeployed;
    }

    /**
     * @notice Resolve top miner by iterating deployers in index order
     * @dev Called once per single-winner round on first checkpoint. Builds cumulative
     *      ranges on the fly for the winning block and finds whose range contains the sample.
     */
    function _resolveTopMiner(uint64 roundId, Round storage round) internal {
        uint8 winningBlock = round.winningBlock;
        uint256 sample = round.topMinerSeed % round.winnersDeployed;
        uint256 cumulative;
        uint256 count = round.minerCount;

        for (uint256 i; i < count; ) {
            address addr = minerByIndex[roundId][i];
            Miner storage m = miners[roundId][addr];

            if ((m.deployedMask & (1 << winningBlock)) != 0) {
                uint256 amt = m.amountPerBlock;
                if (sample >= cumulative && sample < cumulative + amt) {
                    round.topMiner = addr;
                    return;
                }
                cumulative += amt;
            }

            unchecked { ++i; }
        }
    }

    /// @dev View-only version of _resolveTopMiner for getTotalPendingRewards
    function _viewResolveTopMiner(uint64 roundId, Round storage round) internal view returns (address) {
        uint8 winningBlock = round.winningBlock;
        uint256 sample = round.topMinerSeed % round.winnersDeployed;
        uint256 cumulative;
        uint256 count = round.minerCount;

        for (uint256 i; i < count; ) {
            address addr = minerByIndex[roundId][i];
            Miner storage m = miners[roundId][addr];

            if ((m.deployedMask & (1 << winningBlock)) != 0) {
                uint256 amt = m.amountPerBlock;
                if (sample >= cumulative && sample < cumulative + amt) {
                    return addr;
                }
                cumulative += amt;
            }

            unchecked { ++i; }
        }
        return address(0);
    }

    function _getClaimablePool(uint256 totalDeployed, uint256 winnersDeployed) internal pure returns (uint256) {
        uint256 adminFee = (totalDeployed * ADMIN_FEE_BPS) / BPS_DENOMINATOR;
        uint256 losersPool = totalDeployed - winnersDeployed;
        uint256 losersAdminShare = (losersPool * ADMIN_FEE_BPS) / BPS_DENOMINATOR;
        uint256 vaultAmount = ((losersPool - losersAdminShare) * VAULT_FEE_BPS) / BPS_DENOMINATOR;
        return totalDeployed - adminFee - vaultAmount;
    }

    function _updateHarvestingRewards(address user) internal {
        uint256 unclaimed = userUnclaimedPEA[user];
        if (unclaimed == 0) return;

        uint256 accumulatedPerToken = accHarvestingPerUnclaimed - userHarvestingDebt[user];
        uint256 pending = (unclaimed * accumulatedPerToken) / 1e18;

        userHarvestedPEA[user] += pending;
        userHarvestingDebt[user] = accHarvestingPerUnclaimed;
    }

    function _safeTransferETH(address to, uint256 amount) internal {
        (bool success, ) = to.call{value: amount}("");
        if (!success) revert TransferFailed();
    }

    // ============ View Functions ============

    function getRound(uint64 roundId) external view returns (
        uint256 startTime,
        uint256 endTime,
        uint256 totalDeployed,
        uint256 totalWinnings,
        uint8 winningBlock,
        address topMiner,
        uint256 topMinerReward,
        uint256 peapotAmount,
        bool settled
    ) {
        Round storage round = rounds[roundId];
        return (
            round.startTime,
            round.endTime,
            round.totalDeployed,
            round.totalWinnings,
            round.winningBlock,
            round.topMiner,
            round.topMinerReward,
            round.peapotAmount,
            round.settled
        );
    }

    function getRoundDeployed(uint64 roundId) external view returns (uint256[25] memory) {
        return rounds[roundId].deployed;
    }

    function getMinerInfo(uint64 roundId, address user) external view returns (
        uint256 deployedMask,
        uint256 amountPerBlock,
        bool checkpointed
    ) {
        Miner storage miner = miners[roundId][user];
        return (miner.deployedMask, miner.amountPerBlock, miner.checkpointed);
    }

    function getPendingETH(address user) external view returns (uint256) {
        return userUnclaimedETH[user];
    }

    function getPendingPEA(address user) external view returns (uint256 gross, uint256 fee, uint256 net) {
        uint256 minedPEA = userUnclaimedPEA[user];

        // Calculate pending harvesting bonus
        uint256 accumulatedPerToken = accHarvestingPerUnclaimed - userHarvestingDebt[user];
        uint256 pendingHarvested = (minedPEA * accumulatedPerToken) / 1e18;
        uint256 harvestedPEA = userHarvestedPEA[user] + pendingHarvested;

        gross = minedPEA + harvestedPEA;

        // Fee only on mined
        fee = (minedPEA * HARVESTING_FEE_BPS) / BPS_DENOMINATOR;
        net = gross - fee;
    }

    function getTotalPendingRewards(address user) external view returns (
        uint256 pendingETH,
        uint256 pendingUnharvestedPEA,
        uint256 pendingHarvestedPEA,
        uint64 uncheckpointedRound
    ) {
        // 1. Already checkpointed rewards
        pendingETH = userUnclaimedETH[user];
        pendingUnharvestedPEA = userUnclaimedPEA[user];

        // 2. Harvesting bonus (stored + pending)
        pendingHarvestedPEA = userHarvestedPEA[user]
            + (userUnclaimedPEA[user] * (accHarvestingPerUnclaimed - userHarvestingDebt[user])) / 1e18;

        // 3. Check for uncheckpointed round
        uint64 lastRound = userLastRound[user];
        if (lastRound == 0) return (pendingETH, pendingUnharvestedPEA, pendingHarvestedPEA, 0);

        Round storage round = rounds[lastRound];
        Miner storage miner = miners[lastRound][user];

        if (miner.checkpointed || !round.settled) {
            return (pendingETH, pendingUnharvestedPEA, pendingHarvestedPEA, 0);
        }

        // 4. Calculate uncheckpointed rewards
        {
            uint8 winningBlock = round.winningBlock;
            uint256 userDeployed = (miner.deployedMask & (1 << winningBlock)) != 0
                ? miner.amountPerBlock
                : 0;

            if (userDeployed == 0) {
                return (pendingETH, pendingUnharvestedPEA, pendingHarvestedPEA, 0);
            }

            uncheckpointedRound = lastRound;
            uint256 winnersDeployed = round.winnersDeployed;

            // ETH: proportional share of actual retained ETH
            pendingETH += (_getClaimablePool(round.totalDeployed, winnersDeployed) * userDeployed) / winnersDeployed;

            // PEA (uncheckpointed goes to unharvested)
            uint256 peaReward;

            if (round.topMiner == address(0)) {
                peaReward = (round.topMinerReward * userDeployed) / winnersDeployed;
            } else if (round.topMiner == address(1)) {
                if (round.minerCount > maxMinersForSingleWinner) {
                    // Over cap: would be forced to split on checkpoint
                    peaReward = (round.topMinerReward * userDeployed) / winnersDeployed;
                } else {
                    // Unresolved single winner: iterate deployers to check
                    if (_viewResolveTopMiner(lastRound, round) == user) {
                        peaReward = round.topMinerReward;
                    }
                }
            } else if (round.topMiner == user) {
                peaReward = round.topMinerReward;
            }

            if (round.peapotAmount != 0) {
                peaReward += (round.peapotAmount * userDeployed) / winnersDeployed;
            }

            pendingUnharvestedPEA += peaReward;
        }
    }

    function getCurrentRoundInfo() external view returns (
        uint64 roundId,
        uint256 startTime,
        uint256 endTime,
        uint256 totalDeployed,
        uint256 timeRemaining,
        bool isActive
    ) {
        Round storage round = rounds[currentRoundId];

        roundId = currentRoundId;
        startTime = round.startTime;
        endTime = round.endTime;
        totalDeployed = round.totalDeployed;
        timeRemaining = block.timestamp >= round.endTime ? 0 : round.endTime - block.timestamp;
        isActive = gameStarted && block.timestamp < round.endTime && !round.settled;
    }

    // ============ Receive ============

    receive() external payable {}
}
