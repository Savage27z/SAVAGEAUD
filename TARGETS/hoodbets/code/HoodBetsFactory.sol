// SPDX-License-Identifier: MIT

/*
 *  ██╗  ██╗ ██████╗  ██████╗ ██████╗    ██████╗ ███████╗████████╗███████╗
 *  ██║  ██║██╔═══██╗██╔═══██╗██╔══██╗   ██╔══██╗██╔════╝╚══██╔══╝██╔════╝
 *  ███████║██║   ██║██║   ██║██║  ██║   ██████╔╝█████╗     ██║   ███████╗
 *  ██╔══██║██║   ██║██║   ██║██║  ██║   ██╔══██╗██╔══╝     ██║   ╚════██║
 *  ██║  ██║╚██████╔╝╚██████╔╝██████╔╝   ██████╔╝███████╗   ██║   ███████║
 *  ╚═╝  ╚═╝ ╚═════╝  ╚═════╝ ╚═════╝    ╚═════╝ ╚══════╝   ╚═╝   ╚══════╝
 *
 *              T R A D E   T H E   F U T U R E .   O W N   T H E   O U T C O M E .
 *
 *  ───────────────────────────────────────────────────────────────────────────────────────────────
 *   On-chain prediction markets. Bet native ETH on a binary outcome; winners split the losing pot
 *   pro-rata. Every market mints its own non-transferable YES/NO share tokens.
 *
 *   Chain    : Robinhood Chain (Arbitrum Orbit) — chainId 4663 / 0x1237
 *   Gas token: ETH
 *   WETH     : 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73
 *   Fee      : 3% of every buy, to the market resolver
 *  ───────────────────────────────────────────────────────────────────────────────────────────────
 */

pragma solidity ^0.8.24;

/**
 * @title WETH interface
 * @dev Interface for Wrapped Ether (WETH) on Robinhood Chain
 */
interface IWETH {
    function deposit() external payable;
    function withdraw(uint256 amount) external;
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 value) external returns (bool);
}

/**
 * @title HoodBetsMarketShare
 * @dev ERC20 token representing shares in a prediction market (YES or NO)
 */
contract HoodBetsMarketShare {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;
    uint256 public totalSupply;

    address public immutable factory;
    uint256 public immutable marketId;

    mapping(address => uint256) public balanceOf;

    event Transfer(address indexed from, address indexed to, uint256 value);

    modifier onlyFactory() {
        require(msg.sender == factory, "Only factory can mint/burn");
        _;
    }

    constructor(string memory _name, string memory _symbol, uint256 _marketId) {
        name = _name;
        symbol = _symbol;
        marketId = _marketId;
        factory = msg.sender;
    }

    /**
     * @dev Transfers are disabled - tokens are non-transferable
     */
    function transfer(address, uint256) external pure returns (bool) {
        revert("Tokens are non-transferable");
    }

    /**
     * @dev Approvals are disabled - tokens are non-transferable
     */
    function approve(address, uint256) external pure returns (bool) {
        revert("Tokens are non-transferable");
    }

    /**
     * @dev TransferFrom is disabled - tokens are non-transferable
     */
    function transferFrom(address, address, uint256) external pure returns (bool) {
        revert("Tokens are non-transferable");
    }

    /**
     * @dev Mints tokens to a user when they buy shares
     * @param to Address to mint tokens to
     * @param amount Amount of tokens to mint
     */
    function mint(address to, uint256 amount) external onlyFactory {
        totalSupply += amount;
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    /**
     * @dev Burns tokens from a user when they claim winnings
     * @param from Address to burn tokens from
     * @param amount Amount of tokens to burn
     */
    function burn(address from, uint256 amount) external onlyFactory {
        require(balanceOf[from] >= amount, "Insufficient balance to burn");
        balanceOf[from] -= amount;
        totalSupply -= amount;
        emit Transfer(from, address(0), amount);
    }
}

interface IOwnable {
    /// @dev Returns the owner of the contract.
    function owner() external view returns (address);

    /// @dev Lets an authorized wallet set a new owner for the contract.
    function setOwner(address _newOwner) external;

    /// @dev Emitted when a new Owner is set.
    event OwnerUpdated(address indexed prevOwner, address indexed newOwner);
}

/**
 *  @title   Ownable
 *  @notice  Exposes functions for setting and reading who the 'owner' of the inheriting
 *           smart contract is, and lets the inheriting contract perform conditional logic
 *           that uses information about who the contract's owner is.
 */
abstract contract Ownable is IOwnable {
    /// @dev The sender is not authorized to perform the action
    error OwnableUnauthorized();

    /// @dev Owner of the contract.
    address private _owner;

    /// @dev Reverts if caller is not the owner.
    modifier onlyOwner() {
        if (msg.sender != _owner) {
            revert OwnableUnauthorized();
        }
        _;
    }

    /**
     *  @notice Returns the owner of the contract.
     */
    function owner() public view override returns (address) {
        return _owner;
    }

    /**
     *  @notice Lets an authorized wallet set a new owner for the contract.
     *  @param _newOwner The address to set as the new owner of the contract.
     */
    function setOwner(address _newOwner) external override {
        if (!_canSetOwner()) {
            revert OwnableUnauthorized();
        }
        _setupOwner(_newOwner);
    }

    /// @dev Assigns a new owner and emits {OwnerUpdated}.
    function _setupOwner(address _newOwner) internal {
        address _prevOwner = _owner;
        _owner = _newOwner;

        emit OwnerUpdated(_prevOwner, _newOwner);
    }

    /// @dev Returns whether owner can be set in the given execution context.
    function _canSetOwner() internal view virtual returns (bool);
}

abstract contract ReentrancyGuard {
    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED = 2;

    uint256 private _status;

    constructor() {
        _status = _NOT_ENTERED;
    }

    /**
     * @dev Prevents a contract from calling itself, directly or indirectly.
     */
    modifier nonReentrant() {
        require(_status != _ENTERED, "ReentrancyGuard: reentrant call");
        _status = _ENTERED;
        _;
        _status = _NOT_ENTERED;
    }
}

/**
 * @title HoodBetsFactory
 * @dev A prediction market contract where users can bet on outcomes and claim winnings based on the result.
 *      Deposits are wrapped into WETH and held by this contract; claims unwrap back to native ETH.
 */
contract HoodBetsFactory is Ownable, ReentrancyGuard {
    /// @notice Market prediction outcome enum
    enum MarketOutcome {
        UNRESOLVED,
        OPTION_A,
        OPTION_B
    }

    /// @dev Represents a prediction market.
    struct Market {
        string question;
        string description;
        string category;
        uint256 endTime;
        MarketOutcome outcome;
        string optionA;
        string optionB;
        uint256 totalOptionAShares;
        uint256 totalOptionBShares;
        bool resolved;
        mapping(address => uint256) optionASharesBalance;
        mapping(address => uint256) optionBSharesBalance;
        // Tracks whether a user has already claimed their winnings
        mapping(address => bool) hasClaimed;
        // Market tokens
        HoodBetsMarketShare yesToken;
        HoodBetsMarketShare noToken;
    }

    // WETH on Robinhood Chain mainnet
    IWETH public constant weth = IWETH(0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73);

    /// @notice Address authorized to resolve markets
    address public marketResolver;

    uint256 public marketCount;
    mapping(uint256 => Market) public markets;

    /// @notice Emitted when a new market is created.
    event MarketCreated(
        uint256 indexed marketId,
        string question,
        string description,
        string category,
        string optionA,
        string optionB,
        uint256 endTime
    );

    /// @notice Emitted when shares are purchased in a market.
    event SharesPurchased(uint256 indexed marketId, address indexed buyer, bool isOptionA, uint256 amount);

    /// @notice Emitted when a market is resolved with an outcome.
    event MarketResolved(uint256 indexed marketId, MarketOutcome outcome);

    /// @notice Emitted when winnings are claimed by a user.
    event Claimed(uint256 indexed marketId, address indexed user, uint256 amount);

    /// @notice Emitted when the market resolver is changed.
    event MarketResolverUpdated(address indexed previousResolver, address indexed newResolver);

    /// @notice Emitted when a fee is collected by the market resolver.
    event FeeCollected(uint256 indexed marketId, address indexed resolver, uint256 amount);

    /**
     * @dev Initializes the contract owner and market resolver.
     */
    constructor() {
        _setupOwner(msg.sender); // Set the contract deployer as the owner
        marketResolver = msg.sender; // Set the deployer as initial market resolver
    }

    /**
     * @dev Allows contract to receive ETH from WETH withdrawals
     */
    receive() external payable {}

    /**
     * @dev Required override for the Ownable extension.
     * @return True if the caller is the contract owner.
     */
    function _canSetOwner() internal view virtual override returns (bool) {
        return msg.sender == owner();
    }

    /**
     * @dev Internal function to convert uint256 to string.
     * @param value The uint256 value to convert.
     * @return The string representation of the value.
     */
    function _toString(uint256 value) internal pure returns (string memory) {
        if (value == 0) {
            return "0";
        }
        uint256 temp = value;
        uint256 digits;
        while (temp != 0) {
            digits++;
            temp /= 10;
        }
        bytes memory buffer = new bytes(digits);
        while (value != 0) {
            digits -= 1;
            buffer[digits] = bytes1(uint8(48 + uint256(value % 10)));
            value /= 10;
        }
        return string(buffer);
    }

    /**
     * @notice Creates a new prediction market.
     * @param _question The question for the market.
     * @param _description Detailed description of the market.
     * @param _category The category of the market (e.g., "Sports", "Politics", "Crypto").
     * @param _optionA The first option for the market.
     * @param _optionB The second option for the market.
     * @param _endTime The timestamp when the market closes.
     * @return marketId The ID of the newly created market.
     */
    function createMarket(
        string memory _question,
        string memory _description,
        string memory _category,
        string memory _optionA,
        string memory _optionB,
        uint256 _endTime
    ) external returns (uint256) {
        require(msg.sender == owner(), "Only owner can create markets");
        // Must clear the 30-minute trading cutoff: `buyShares` computes `endTime - 30 minutes`
        // under checked math, so a shorter horizon would underflow on every buy and the market
        // could never be traded.
        require(_endTime > block.timestamp + 30 minutes, "End time must be at least 30 minutes away");
        require(bytes(_optionA).length > 0 && bytes(_optionB).length > 0, "Options cannot be empty");

        uint256 marketId = ++marketCount; // Start from 1
        Market storage market = markets[marketId];

        market.question = _question;
        market.description = _description;
        market.category = _category;
        market.optionA = _optionA;
        market.optionB = _optionB;
        market.endTime = _endTime;
        market.outcome = MarketOutcome.UNRESOLVED;

        // Deploy YES and NO tokens for this market
        market.yesToken = new HoodBetsMarketShare(
            string(abi.encodePacked("Hood Bets YES - ", _optionA)),
            string(abi.encodePacked("HOOD YES - ", _toString(marketId))),
            marketId
        );

        market.noToken = new HoodBetsMarketShare(
            string(abi.encodePacked("Hood Bets NO - ", _optionB)),
            string(abi.encodePacked("HOOD NO - ", _toString(marketId))),
            marketId
        );

        emit MarketCreated(marketId, _question, _description, _category, _optionA, _optionB, market.endTime);
        return marketId;
    }

    /**
     * @notice Allows users to buy shares in a market using native ETH.
     * @dev Automatically wraps ETH to WETH. A 3% fee is sent to the market resolver.
     *      Trading closes 30 minutes before market end to prevent manipulation.
     * @param _marketId The ID of the market to buy shares in.
     * @param _isOptionA True if buying shares for Option A, false for Option B.
     */
    function buyShares(uint256 _marketId, bool _isOptionA) external payable {
        Market storage market = markets[_marketId];
        require(market.endTime != 0, "Invalid market");
        require(block.timestamp < market.endTime - 30 minutes, "Market trading closes 30 minutes before end");
        require(!market.resolved, "Market already resolved");
        require(msg.value > 0, "Must send ETH");

        // Calculate 3% fee for resolver
        uint256 fee = (msg.value * 3) / 100;
        uint256 shareAmount = msg.value - fee;

        // Wrap ETH to WETH
        weth.deposit{value: msg.value}();

        // Transfer fee to resolver
        require(weth.transfer(marketResolver, fee), "Fee transfer failed");
        emit FeeCollected(_marketId, marketResolver, fee);

        if (_isOptionA) {
            market.optionASharesBalance[msg.sender] += shareAmount;
            market.totalOptionAShares += shareAmount;
            // Mint YES tokens to the buyer (97% of paid amount)
            market.yesToken.mint(msg.sender, shareAmount);
        } else {
            market.optionBSharesBalance[msg.sender] += shareAmount;
            market.totalOptionBShares += shareAmount;
            // Mint NO tokens to the buyer (97% of paid amount)
            market.noToken.mint(msg.sender, shareAmount);
        }

        emit SharesPurchased(_marketId, msg.sender, _isOptionA, shareAmount);
    }

    /**
     * @notice Resolves a market by setting the outcome.
     * @param _marketId The ID of the market to resolve.
     * @param _outcome The outcome to set for the market.
     */
    function resolveMarket(uint256 _marketId, MarketOutcome _outcome) external {
        require(msg.sender == marketResolver, "Only market resolver can resolve markets");
        Market storage market = markets[_marketId];
        require(market.endTime != 0, "Invalid market");
        require(block.timestamp >= market.endTime, "Market hasn't ended yet");
        require(!market.resolved, "Market already resolved");
        require(_outcome != MarketOutcome.UNRESOLVED, "Invalid outcome");

        // Prevent resolving in favor of an option with no shares
        if (_outcome == MarketOutcome.OPTION_A) {
            require(market.totalOptionAShares > 0, "Cannot resolve for option with no shares");
        } else if (_outcome == MarketOutcome.OPTION_B) {
            require(market.totalOptionBShares > 0, "Cannot resolve for option with no shares");
        }

        market.outcome = _outcome;
        market.resolved = true;

        emit MarketResolved(_marketId, _outcome);
    }

    /**
     * @notice Claims winnings for the caller if they participated in a resolved market.
     * @dev Automatically unwraps WETH to native ETH and sends to user.
     * @param _marketId The ID of the market to claim winnings from.
     */
    function claimWinnings(uint256 _marketId) external nonReentrant {
        Market storage market = markets[_marketId];
        require(market.endTime != 0, "Invalid market");
        require(market.resolved, "Market not resolved yet");
        require(!market.hasClaimed[msg.sender], "Already claimed");

        uint256 userShares;
        uint256 winningShares;
        uint256 losingShares;

        if (market.outcome == MarketOutcome.OPTION_A) {
            userShares = market.optionASharesBalance[msg.sender];
            winningShares = market.totalOptionAShares;
            losingShares = market.totalOptionBShares;
            // Burn YES tokens from user
            market.yesToken.burn(msg.sender, userShares);
            market.optionASharesBalance[msg.sender] = 0;
        } else if (market.outcome == MarketOutcome.OPTION_B) {
            userShares = market.optionBSharesBalance[msg.sender];
            winningShares = market.totalOptionBShares;
            losingShares = market.totalOptionAShares;
            // Burn NO tokens from user
            market.noToken.burn(msg.sender, userShares);
            market.optionBSharesBalance[msg.sender] = 0;
        } else {
            revert("Market outcome is not valid");
        }

        require(userShares > 0, "No winnings to claim");

        // Mark as claimed BEFORE transferring funds (CEI pattern)
        market.hasClaimed[msg.sender] = true;

        // Calculate winnings
        uint256 winnings;
        if (losingShares == 0) {
            // No losing side - winners just get their stake back
            winnings = userShares;
        } else {
            // Calculate the reward ratio
            uint256 rewardRatio = (losingShares * 1e18) / winningShares; // Using 1e18 for precision
            // Calculate winnings: original stake + proportional share of losing funds
            winnings = userShares + (userShares * rewardRatio) / 1e18;
        }

        // Unwrap WETH to ETH
        weth.withdraw(winnings);

        // Send native ETH to user
        (bool success,) = payable(msg.sender).call{value: winnings}("");
        require(success, "ETH transfer failed");

        emit Claimed(_marketId, msg.sender, winnings);
    }

    /**
     * @notice Returns detailed information about a specific market.
     * @param _marketId The ID of the market to retrieve information for.
     * @return question The market's question.
     * @return description The market's description.
     * @return category The market's category.
     * @return optionA The first option for the market.
     * @return optionB The second option for the market.
     * @return endTime The end time of the market.
     * @return outcome The outcome of the market.
     * @return totalOptionAShares Total shares bought for Option A.
     * @return totalOptionBShares Total shares bought for Option B.
     * @return resolved Whether the market has been resolved.
     */
    function getMarketInfo(uint256 _marketId)
        external
        view
        returns (
            string memory question,
            string memory description,
            string memory category,
            string memory optionA,
            string memory optionB,
            uint256 endTime,
            MarketOutcome outcome,
            uint256 totalOptionAShares,
            uint256 totalOptionBShares,
            bool resolved
        )
    {
        Market storage market = markets[_marketId];
        return (
            market.question,
            market.description,
            market.category,
            market.optionA,
            market.optionB,
            market.endTime,
            market.outcome,
            market.totalOptionAShares,
            market.totalOptionBShares,
            market.resolved
        );
    }

    /**
     * @notice Returns the shares balance for a specific user in a market.
     * @param _marketId The ID of the market to check.
     * @param _user The address of the user to check balance for.
     * @return optionAShares The user's shares for Option A.
     * @return optionBShares The user's shares for Option B.
     */
    function getSharesBalance(uint256 _marketId, address _user)
        external
        view
        returns (uint256 optionAShares, uint256 optionBShares)
    {
        Market storage market = markets[_marketId];
        return (market.optionASharesBalance[_user], market.optionBSharesBalance[_user]);
    }

    /**
     * @notice Allows multiple users to claim their winnings in a batch for a given market.
     * @dev Automatically unwraps WETH to native ETH and sends to users.
     * @param _marketId The ID of the market for which winnings are claimed.
     * @param _users Array of user addresses who wish to claim their winnings.
     */
    function batchClaimWinnings(uint256 _marketId, address[] calldata _users) external nonReentrant {
        Market storage market = markets[_marketId];
        require(market.endTime != 0, "Invalid market");
        require(market.resolved, "Market not resolved yet");

        for (uint256 i = 0; i < _users.length; i++) {
            address user = _users[i];

            // Skip if the user already claimed
            if (market.hasClaimed[user]) {
                continue;
            }

            uint256 userShares;
            uint256 winningShares;
            uint256 losingShares;

            // Determine user shares and winning/losing shares based on the outcome
            if (market.outcome == MarketOutcome.OPTION_A) {
                userShares = market.optionASharesBalance[user];
                winningShares = market.totalOptionAShares;
                losingShares = market.totalOptionBShares;
                // Burn YES tokens from user
                if (userShares > 0) {
                    market.yesToken.burn(user, userShares);
                }
                market.optionASharesBalance[user] = 0; // Reset user shares after claim
            } else if (market.outcome == MarketOutcome.OPTION_B) {
                userShares = market.optionBSharesBalance[user];
                winningShares = market.totalOptionBShares;
                losingShares = market.totalOptionAShares;
                // Burn NO tokens from user
                if (userShares > 0) {
                    market.noToken.burn(user, userShares);
                }
                market.optionBSharesBalance[user] = 0; // Reset user's shares after claim
            } else {
                revert("Market outcome is not valid");
            }

            // We need to ensure the user has winnings to claim
            if (userShares == 0) {
                continue;
            }

            // Calculate winnings
            uint256 winnings;
            if (losingShares == 0) {
                // No losing side - winners just get their stake back
                winnings = userShares;
            } else {
                // Calculate the reward ratio
                uint256 rewardRatio = (losingShares * 1e18) / winningShares;
                winnings = userShares + (userShares * rewardRatio) / 1e18;
            }

            // Mark the user as having claimed winnings
            market.hasClaimed[user] = true;

            // Unwrap WETH to ETH
            weth.withdraw(winnings);

            // Send native ETH to user
            (bool success,) = payable(user).call{value: winnings}("");
            require(success, "ETH transfer failed");

            // emit an event for each user who claimed winnings
            emit Claimed(_marketId, user, winnings);
        }
    }

    /**
     * @notice Returns the addresses of the YES and NO tokens for a market.
     * @param _marketId The ID of the market.
     * @return yesTokenAddress The address of the YES token.
     * @return noTokenAddress The address of the NO token.
     */
    function getMarketShares(uint256 _marketId)
        external
        view
        returns (address yesTokenAddress, address noTokenAddress)
    {
        Market storage market = markets[_marketId];
        return (address(market.yesToken), address(market.noToken));
    }

    /// @notice Whether `_user` has already claimed in `_marketId`. View-only helper.
    function hasClaimed(uint256 _marketId, address _user) external view returns (bool) {
        return markets[_marketId].hasClaimed[_user];
    }

    /**
     * @notice Updates the market resolver address.
     * @dev Only the contract owner can call this function.
     * @param _newResolver The address of the new market resolver.
     */
    function setMarketResolver(address _newResolver) external onlyOwner {
        require(_newResolver != address(0), "Resolver cannot be zero address");
        address previousResolver = marketResolver;
        marketResolver = _newResolver;
        emit MarketResolverUpdated(previousResolver, _newResolver);
    }
}