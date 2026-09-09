// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// Revert to standard OpenZeppelin imports
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts/utils/Strings.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol"; // Import ECDSA

/**
 * @title DeathRaceGame
 * @dev Smart contract to manage Death Race game on Abstract L2 (zkSync Era)
 * 
 * The contract handles game creation, payout management, and provable fairness
 * for the Death Race game, where players navigate through a grid to maximize 
 * their potential winnings. Requires server-signed parameters for critical actions.
 */
contract DeathFun is Initializable, OwnableUpgradeable, ReentrancyGuardUpgradeable {
    using Strings for uint256;

    // ===================
    // State Variables
    // ===================

    /// @notice Counter for unique on-chain game IDs
    uint256 public gameCounter;

    /// @notice Prefix used in messageHash for domain separation
    string public messagePrefix;

    /// @notice Mapping of admin addresses (can call privileged functions)
    mapping(address => bool) public isAdmin;

    /// @notice Mapping from preliminary game ID to on-chain game ID
    mapping(string => uint256) public preliminaryToOnChainId;

    /// @notice Game status enum
    enum GameStatus {
        Active,
        Won,
        Lost
    }

    /// @notice Game data structure
    struct Game {
        uint256 createdAt;       // Block timestamp when game was created
        address player;          // Player's wallet address
        uint256 betAmount;       // Original bet amount in wei
        GameStatus status;       // Current game status
        uint256 payoutAmount;    // Final payout amount (0 if lost)
        bytes32 gameSeedHash;    // Hash of the seed + gameConfig + algoVersion
        string gameSeed;         // Seed used to generate the game state
        string algoVersion;      // Algorithm version for going from seed to game state
        string gameConfig;       // JSON string containing game configuration
        string gameState;        // JSON string containing final game state/player moves
    }

    /// @notice Mapping from on-chain game ID to Game data
    mapping(uint256 => Game) public games;

    /// @notice Reserved slots for upgradeability
    uint256[50] private __gap; // 50 reserved slots

    // ===================
    // Events
    // ===================

    /// @notice Emitted when a new game is created
    event GameCreated(
        string preliminaryGameId,
        uint256 indexed onChainGameId,
        address indexed player,
        uint256 betAmount,
        bytes32 gameSeedHash // Keep seed hash in event for listener correlation
    );

    /// @notice Emitted when a payout is sent to a player
    event PayoutSent(
        uint256 indexed onChainGameId,
        uint256 amount,
        address indexed recipient
    );

    /// @notice Emitted when a game status is updated
    event GameStatusUpdated(
        uint256 indexed onChainGameId,
        GameStatus status
    );

    /// @notice Emitted when funds are deposited directly into the contract
    event DepositReceived(address indexed sender, uint256 amount);

    /// @notice Emitted when an admin is added
    event AdminAdded(address indexed newAdmin);

    /// @notice Emitted when an admin is removed
    event AdminRemoved(address indexed removedAdmin);

    /// @notice Emitted when a referral payment is made
    event ReferralPaid(address indexed recipient, uint256 amount, address indexed admin);

    /// @notice Emitted when a bet increase is made
    event BetIncrease(uint256 indexed onChainGameId, uint256 amount, address indexed player);

    // ===================
    // Errors
    // ===================

    /// @notice Error when game already exists
    error GameAlreadyExists(string preliminaryGameId);

    /// @notice Error when game doesn't exist
    error GameDoesNotExist(uint256 onChainGameId);

    /// @notice Error when caller is not the player
    error NotGamePlayer(uint256 onChainGameId, address caller);

    /// @notice Error when game is not in active status
    error GameNotActive(uint256 onChainGameId);

    /// @notice Error when payout fails
    error PayoutFailed(uint256 onChainGameId, uint256 amount);

    /// @notice Error when server signature is invalid or doesn't match expected signer
    error InvalidServerSignature();

    /// @notice Error when caller is not authorized
    error NotAuthorized();

    /// @notice Error when signature has expired
    error SignatureExpired();

    /// @notice Error when amount is zero
    error ZeroAmount();

    // ===================
    // Constructor
    // ===================

    /**
     * @dev Initializer sets the contract owner and initial server signer address
     * @param _messagePrefix The prefix used in messageHash for domain separation
     */
    function initialize(string memory _messagePrefix) public initializer {
        __Ownable_init(msg.sender);
        __ReentrancyGuard_init();
        gameCounter = 0;
        messagePrefix = _messagePrefix;
        isAdmin[msg.sender] = true;
        emit AdminAdded(msg.sender);
    }

    // ===================
    // External Functions
    // ===================

    /**
     * @notice Creates a new game placeholder on-chain. Requires server signature.
     * Only gameSeedHash is needed for provable fairness.
     * @param preliminaryGameId The preliminary game ID generated by the backend
     * @param gameSeedHash Hash of the actual game seed (used for listener correlation)
     * @param algoVersion The algorithm version for provable fairness
     * @param gameConfig JSON string containing game configuration
     * @param deadline The latest timestamp this signature is valid for
     * @param serverSignature Signature from the server authorizing this game creation
     */
    function createGame(
        string calldata preliminaryGameId,
        bytes32 gameSeedHash,
        string calldata algoVersion,
        string calldata gameConfig,
        uint256 deadline,
        bytes calldata serverSignature
    ) external payable {
        require(block.timestamp <= deadline, "Signature expired");
        // Use domain separation and abi.encode for signature
        bytes32 messageHash = keccak256(
            abi.encode(
                string.concat(messagePrefix, ":createGame"),
                preliminaryGameId,
                gameSeedHash,
                algoVersion,
                gameConfig,
                msg.sender,
                msg.value,
                deadline
            )
        );
        _verifyAnyAdminSignature(messageHash, serverSignature);

        if (preliminaryToOnChainId[preliminaryGameId] != 0) {
            revert GameAlreadyExists(preliminaryGameId);
        }

        gameCounter += 1;
        uint256 onChainGameId = gameCounter;
        preliminaryToOnChainId[preliminaryGameId] = onChainGameId;

        // Create game struct with all metadata
        games[onChainGameId] = Game({
            player: msg.sender,
            betAmount: msg.value,
            gameSeedHash: gameSeedHash,
            status: GameStatus.Active,
            payoutAmount: 0,
            gameSeed: "",
            algoVersion: algoVersion,
            gameConfig: gameConfig,
            gameState: "",
            createdAt: block.timestamp
        });

        emit GameCreated(preliminaryGameId, onChainGameId, msg.sender, msg.value, gameSeedHash);
    }

    /**
     * @notice Processes a cash out. Callable by an admin (no signature) or by the player with a valid server signature.
     * @param onChainGameId The on-chain game ID.
     * @param payoutAmount The NET amount to pay out.
     * @param gameState JSON string containing final game state/player moves
     * @param gameSeed The final game seed to store for provable fairness
     * @param deadline The latest timestamp this signature is valid for (only required if called by player)
     * @param serverSignature Signature from an admin authorizing this cash out (only required if called by player)
     */
    function cashOut(
        uint256 onChainGameId,
        uint256 payoutAmount,
        string calldata gameState,
        string calldata gameSeed,
        uint256 deadline,
        bytes calldata serverSignature
    ) external nonReentrant {
        Game storage game = games[onChainGameId];
        if (game.player == address(0)) {
             revert GameDoesNotExist(onChainGameId);
        }
        // Check status - This prevents cashing out already Won/Lost games
        if (game.status != GameStatus.Active) {
            revert GameNotActive(onChainGameId);
        }
        require(payoutAmount > 0, "PayoutZero");
        address playerAddress = game.player;

        if (!isAdmin[msg.sender]) {
            require(msg.sender == playerAddress, "Not authorized");
            require(block.timestamp <= deadline, "Signature expired");
            bytes32 messageHash = keccak256(
                abi.encode(
                    string(abi.encodePacked(messagePrefix, ":cashOut")),
                    onChainGameId,
                    payoutAmount,
                    gameState,
                    gameSeed,
                    deadline
                )
            );
            _verifyAnyAdminSignature(messageHash, serverSignature);
        }

        // --- EFFECTS (set state before external call) ---
        game.status = GameStatus.Won;
        game.payoutAmount = payoutAmount;
        game.gameState = gameState;
        game.gameSeed = gameSeed; // Store the game seed

        // --- INTERACTION ---
        (bool success, ) = payable(playerAddress).call{value: payoutAmount}("");
        if (!success) {
            revert PayoutFailed(onChainGameId, payoutAmount);
        }

        emit GameStatusUpdated(onChainGameId, GameStatus.Won);
        emit PayoutSent(onChainGameId, payoutAmount, playerAddress);
    }

    /**
     * @notice Mark a game as lost. Callable by an admin (no signature) or by the player with a valid server signature.
     * @param onChainGameId The on-chain game ID
     * @param gameState JSON string containing final game state/player moves
     * @param gameSeed The final game seed to store for provable fairness
     * @param deadline The latest timestamp this signature is valid for (only required if called by player)
     * @param serverSignature Signature from an admin authorizing this loss (only required if called by player)
     */
    function markGameAsLost(
        uint256 onChainGameId,
        string calldata gameState,
        string calldata gameSeed,
        uint256 deadline,
        bytes calldata serverSignature
    ) external {
        Game storage game = games[onChainGameId];
         if (game.player == address(0)) {
             revert GameDoesNotExist(onChainGameId);
         }
        if (game.status != GameStatus.Active) {
            revert GameNotActive(onChainGameId);
        }
        address playerAddress = game.player;

        if (!isAdmin[msg.sender]) {
            require(msg.sender == playerAddress, "Not authorized");
            require(block.timestamp <= deadline, "Signature expired");
            bytes32 messageHash = keccak256(
                abi.encode(
                    string(abi.encodePacked(messagePrefix, ":markGameAsLost")),
                    onChainGameId,
                    gameState,
                    gameSeed,
                    deadline
                )
            );
            _verifyAnyAdminSignature(messageHash, serverSignature);
        }

        game.status = GameStatus.Lost;
        game.gameState = gameState;
        game.gameSeed = gameSeed; // Store the game seed

        emit GameStatusUpdated(onChainGameId, GameStatus.Lost);
    }

    /**
     * @notice Get details for a specific game
     * @param onChainGameId The on-chain game ID
     * @return Game struct with all game details
     */
    function getGameDetails(uint256 onChainGameId) external view returns (Game memory) {
         if (games[onChainGameId].player == address(0)) { // Check if game actually exists
             revert GameDoesNotExist(onChainGameId);
         }
        return games[onChainGameId];
    }

    /**
     * @notice Get on-chain ID from preliminary ID
     * @param preliminaryGameId The preliminary game ID
     * @return onChainGameId The corresponding on-chain game ID (0 if not found)
     */
    function getOnChainGameId(string calldata preliminaryGameId) external view returns (uint256) {
        return preliminaryToOnChainId[preliminaryGameId];
    }

    /**
     * @notice Increase the bet amount for a game
     * @param onChainGameId The on-chain game ID
     * @param amount The amount to increase the bet by
     */
    function increaseBet(uint256 onChainGameId, uint256 amount, uint256 deadline, bytes calldata serverSignature) external payable {
        // --- validations
        if (block.timestamp > deadline) {
            revert SignatureExpired();
        }
        bytes32 messageHash = keccak256(
            abi.encode(
                string.concat(messagePrefix, ":increaseBet"),
                onChainGameId,
                amount,
                deadline
            )
        );        
        _verifyAnyAdminSignature(messageHash, serverSignature);

        Game storage game = games[onChainGameId];
        if (game.player != msg.sender) {
            revert NotAuthorized();
        }

        game.betAmount += amount;
        emit BetIncrease(onChainGameId, amount, msg.sender);
    }

    // ===================
    // Admin Functions
    // ===================

    /**
     * @notice Withdraw contract funds to a specified recipient. Only callable by the owner.
     * Funds represent implicitly collected fees (Total Bets - Total Net Payouts).
     * @param amount The amount to withdraw.
     * @param recipient The address to send the withdrawn funds to.
     */
    function withdrawFunds(uint256 amount, address payable recipient) external onlyOwner nonReentrant {
        require(amount > 0, "Withdraw amount must be positive");
        require(recipient != address(0), "Invalid recipient address");
        require(amount <= address(this).balance, "Insufficient contract balance");
        (bool success, ) = recipient.call{value: amount}("");
        require(success, "Withdrawal failed");
    }

    /**
     * @notice Pay referral rewards from contract funds to a specified recipient. Only callable by admins.
     * Funds represent implicitly collected fees (Total Bets - Total Net Payouts).
     * @param amount The amount to pay as referral reward.
     * @param recipient The address to send the referral payment to.
     */
    function payReferral(uint256 amount, address payable recipient) external nonReentrant {
        require(isAdmin[msg.sender], "Only admins can pay referrals");
        require(amount > 0, "Payment amount must be positive");
        require(recipient != address(0), "Invalid recipient address");
        require(amount <= address(this).balance, "Insufficient contract balance");
        (bool success, ) = recipient.call{value: amount}("");
        require(success, "Referral payment failed");
        
        emit ReferralPaid(recipient, amount, msg.sender);
    }

    /**
     * @notice Receive function to accept direct Ether deposits into the treasury.
     */
    receive() external payable {
        emit DepositReceived(msg.sender, msg.value);
    }

    /**
     * @notice Adds a new admin address. Only callable by the contract owner.
     * @param newAdmin The address to grant admin privileges.
     */
    function addAdmin(address newAdmin) external onlyOwner {
        require(newAdmin != address(0), "Invalid admin address");
        require(!isAdmin[newAdmin], "Already admin");
        isAdmin[newAdmin] = true;
        emit AdminAdded(newAdmin);
    }

    /**
     * @notice Removes an admin address. Only callable by the contract owner.
     * @param adminToRemove The address to revoke admin privileges from.
     */ 
    function removeAdmin(address adminToRemove) external onlyOwner {
        require(isAdmin[adminToRemove], "Not an admin");
        require(adminToRemove != owner(), "Cannot remove owner");
        isAdmin[adminToRemove] = false;
        emit AdminRemoved(adminToRemove);
    }

    /**
     * @notice Allows the owner to manually set the gameCounter (for migration/upgrades).
     * @param newCounter The new value for gameCounter. Must be >= current value.
     */
    function setGameCounter(uint256 newCounter) external onlyOwner {
        require(newCounter >= gameCounter, "Cannot decrease gameCounter");
        gameCounter = newCounter;
    }

    // ===============================
    // Internal Helper Functions
    // ===============================

    /**
     * @dev Verifies that the provided signature for the given hash was generated by any admin.
     * Reverts with InvalidServerSignature if verification fails.
     * @param _hash The hash that was signed.
     * @param _signature The signature bytes (expected length 65).
     */
    function _verifyAnyAdminSignature(bytes32 _hash, bytes calldata _signature) internal view {
        // Use OpenZeppelin's ECDSA library for robust verification
        bytes32 prefixedHash = ECDSA.toEthSignedMessageHash(_hash);
        address recoveredSigner = ECDSA.recover(prefixedHash, _signature);
        if (recoveredSigner == address(0) || !isAdmin[recoveredSigner]) {
            revert InvalidServerSignature();
        }
    }
}