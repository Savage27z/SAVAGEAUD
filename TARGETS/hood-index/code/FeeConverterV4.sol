// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IndexVault} from "./IndexVault.sol";
import {IAggregatorV3} from "./interfaces/IAggregatorV3.sol";
import {IPoolManager, PoolKey, SwapParams} from "./ZapV4.sol";

interface IStakingNotify {
    function notifyReward(uint256 amount) external;
}

interface IWETH9 {
    function deposit() external payable;
    function withdraw(uint256) external;
}

/// @title FeeConverterV4 — protocol-fees → buyback & burn, via Uniswap V4
/// @notice Vervangt de originele FeeConverter. Die swapte via de Uniswap V3-router,
///         en dat kán op deze chain niet werken: de V3-pools voor de stock tokens
///         zijn leeg of bestaan niet eens (AAPL/WETH 0,3% bestaat niet). Alle
///         liquiditeit zit in V4. De oude converter kon zijn fees dus nooit
///         omzetten — en omdat er bewust geen withdraw is, bleven ze daar staan.
///
///         De garanties zijn ongewijzigd: fondsen kunnen er maar op één manier uit,
///         namelijk shares → componenten → ETH/WETH → protocol-token → 0xdead.
///         Geen withdraw voor de owner. De keeper mag de stappen uitvoeren maar
///         kan de bestemming niet beïnvloeden: de buyback-pool ligt vast in owner-
///         config (anders kon de keeper de ETH naar een eigen pool wegleiden), en
///         component-verkopen hebben een Chainlink-prijsvloer. Die vloer begrenst
///         het maximale verlies tot `slippageBps` (default 1%, cap 3%) — geen nul,
///         maar een bewust getolereerde marge; een slechte route faalt eronder.
///
/// @dev    Routes komen van de keeper (net als bij ZapV4), want welke V4-pool het
///         goedkoopst is verschilt per component en per moment. De prijsvloer maakt
///         dat ongevaarlijk: een slechte route kan de tx alleen laten falen, nooit
///         waarde weglekken.
contract FeeConverterV4 is ReentrancyGuard, Ownable2Step {
    using SafeERC20 for IERC20;

    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;
    uint256 public constant MAX_FEED_AGE = 80 hours; // feeds pauzeren in het weekend
    uint256 public constant BPS = 10_000;
    uint16 public constant MAX_SLIPPAGE_BPS = 300; // 3% harde cap
    uint16 public constant MAX_STAKING_SHARE_BPS = 5000;

    uint160 internal constant MIN_SQRT_PRICE = 4295128739;
    uint160 internal constant MAX_SQRT_PRICE = 1461446703485210103287273052203988822378723970342;

    IndexVault public immutable vault;
    IPoolManager public immutable poolManager;
    IWETH9 public immutable weth;
    address public immutable usdg;
    IAggregatorV3 public immutable ethUsdFeed;

    address public targetToken; // eenmalig
    // De ETH/targetToken-pool waar de buyback doorheen gaat, eenmalig door de owner
    // vastgezet. Cruciaal: als de keeper deze pool zelf mocht aanleveren, kon hij er
    // een eigen pool van maken en de buyback-ETH naar zijn eigen LP-positie laten
    // lopen (met minOut=0) — een volledige drain van de opgebouwde fees. Vastpinnen
    // aan owner-config sluit dat: de ETH gaat gegarandeerd door de echte pool.
    PoolKey public targetPool;
    address public stakingPool; // eenmalig
    uint16 public stakingShareBps;

    mapping(address => bool) public isKeeper;
    mapping(address => address) public componentFeed;
    uint16 public slippageBps = 100; // 1% t.o.v. Chainlink

    uint256 public totalBurned;

    event KeeperSet(address keeper, bool allowed);
    event TargetTokenSet(address token);
    event ComponentConfigured(address token, address feed);
    event SlippageSet(uint16 bps);
    event FeesRedeemed(uint256 shares);
    event ComponentSold(address indexed token, uint256 amountIn, uint256 ethOut);
    event BuybackBurned(uint256 wethIn, uint256 tokensBurned);
    event StakingPoolSet(address pool, uint16 shareBps);

    error NotKeeper();
    error StakingAlreadySet();
    error StakingShareTooHigh();
    error TargetAlreadySet();
    error TargetNotSet();
    error NotConfigured(address token);
    error StaleFeed(address feed);
    error BadPrice(address feed);
    error SlippageTooHigh();
    error NotPoolManager();
    error BadRoute();
    error BelowFloor(uint256 got, uint256 floorAmount);
    error NothingToDo();

    modifier onlyKeeper() {
        if (!isKeeper[msg.sender] && msg.sender != owner()) revert NotKeeper();
        _;
    }

    constructor(
        IndexVault vault_,
        IPoolManager poolManager_,
        address weth_,
        address usdg_,
        IAggregatorV3 ethUsdFeed_,
        address owner_
    ) Ownable(owner_) {
        vault = vault_;
        poolManager = poolManager_;
        weth = IWETH9(weth_);
        usdg = usdg_;
        ethUsdFeed = ethUsdFeed_;
    }

    receive() external payable {}

    // ---------------------------------------------------------------- admin

    function setKeeper(address keeper, bool allowed) external onlyOwner {
        isKeeper[keeper] = allowed;
        emit KeeperSet(keeper, allowed);
    }

    /// @notice Eenmalig: de token die wordt teruggekocht en geburnd, plus de exacte
    ///         V4-pool waar de buyback doorheen loopt. De pool moet ETH/targetToken
    ///         zijn (native ETH is currency0). De keeper kan de pool daarna niet meer
    ///         beïnvloeden — hij levert alleen nog een minOut aan.
    function setTargetToken(address token, PoolKey calldata pool) external onlyOwner {
        if (targetToken != address(0)) revert TargetAlreadySet();
        if (token == address(0)) revert NotConfigured(token);
        if (pool.currency0 != address(0) || pool.currency1 != token) revert BadRoute();
        targetToken = token;
        targetPool = pool;
        emit TargetTokenSet(token);
    }

    /// @notice Eenmalig: stakingpool + aandeel van de fees dat naar stakers gaat.
    function setStakingPool(address pool, uint16 shareBps) external onlyOwner {
        if (stakingPool != address(0)) revert StakingAlreadySet();
        if (pool == address(0)) revert NotConfigured(pool);
        if (shareBps == 0 || shareBps > MAX_STAKING_SHARE_BPS) revert StakingShareTooHigh();
        stakingPool = pool;
        stakingShareBps = shareBps;
        emit StakingPoolSet(pool, shareBps);
    }

    function configureComponent(address token, address feed) external onlyOwner {
        componentFeed[token] = feed;
        emit ComponentConfigured(token, feed);
    }

    function setSlippageBps(uint16 bps) external onlyOwner {
        if (bps > MAX_SLIPPAGE_BPS) revert SlippageTooHigh();
        slippageBps = bps;
        emit SlippageSet(bps);
    }

    // --------------------------------------------------------------- keeper

    /// @notice Stap 1: verzilver opgebouwde fee-shares naar componenten.
    function redeemFees(uint256 shares) external onlyKeeper nonReentrant {
        vault.redeem(shares, address(this));
        emit FeesRedeemed(shares);
    }

    /// @notice Stap 2: verkoop een component naar ETH via V4 en wrap naar WETH.
    ///         `compPool` mag met native ETH of met USDG gepaard zijn; is het USDG,
    ///         dan wordt de USDG in dezelfde unlock doorgeswapt naar ETH via `usdgEth`.
    /// @dev    De opbrengst moet boven de Chainlink-vloer liggen, dus een slechte
    ///         route of een sandwich laat de tx falen in plaats van waarde te lekken.
    function sellComponent(address token, uint256 amountIn, PoolKey calldata compPool, PoolKey calldata usdgEth)
        external
        onlyKeeper
        nonReentrant
        returns (uint256 ethOut)
    {
        address feed = componentFeed[token];
        if (feed == address(0)) revert NotConfigured(token);
        if (amountIn == 0) revert NothingToDo();

        uint256 tokenUsd = _freshPrice(IAggregatorV3(feed)); // 8 dec
        uint256 ethUsd = _freshPrice(ethUsdFeed); // 8 dec
        uint256 fairOut = (amountIn * tokenUsd) / ethUsd; // 18 dec ETH
        uint256 floorOut = (fairOut * (BPS - slippageBps)) / BPS;

        uint256 before = address(this).balance;
        poolManager.unlock(abi.encode(Action.SELL, abi.encode(token, amountIn, compPool, usdgEth)));
        ethOut = address(this).balance - before;

        if (ethOut < floorOut) revert BelowFloor(ethOut, floorOut);

        weth.deposit{value: ethOut}();
        emit ComponentSold(token, amountIn, ethOut);
    }

    /// @notice Stap 3: koop de protocol-token met WETH en burn hem direct.
    /// @param minOut door de keeper berekende ondergrens (een net gelaunchte token
    ///        heeft geen oracle). De pool ligt vast in owner-config, dus de keeper
    ///        kan de ETH niet naar een eigen pool wegleiden; minOut beschermt alleen
    ///        nog tegen sandwiching van de swap zelf.
    function buybackAndBurn(uint256 wethIn, uint256 minOut) external onlyKeeper nonReentrant returns (uint256 burned) {
        if (targetToken == address(0)) revert TargetNotSet();
        if (wethIn == 0) revert NothingToDo();

        // Staking-split: vast deel als WETH naar de stakers, de rest wordt geburnd.
        if (stakingPool != address(0)) {
            uint256 toStakers = (wethIn * stakingShareBps) / BPS;
            if (toStakers > 0) {
                IERC20(address(weth)).forceApprove(stakingPool, toStakers);
                IStakingNotify(stakingPool).notifyReward(toStakers);
                wethIn -= toStakers;
            }
        }

        weth.withdraw(wethIn); // V4 handelt in native ETH, niet in WETH
        bytes memory res = poolManager.unlock(abi.encode(Action.BUYBACK, abi.encode(wethIn, targetPool)));
        burned = abi.decode(res, (uint256)); // targetPool is de opgeslagen, owner-vaste pool

        if (burned < minOut) revert BelowFloor(burned, minOut);
        totalBurned += burned;
        emit BuybackBurned(wethIn, burned);
    }

    // ------------------------------------------------------------- callback

    enum Action {
        SELL,
        BUYBACK
    }

    function unlockCallback(bytes calldata raw) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        (Action action, bytes memory payload) = abi.decode(raw, (Action, bytes));

        if (action == Action.SELL) {
            (address token, uint256 amountIn, PoolKey memory compPool, PoolKey memory usdgEth) =
                abi.decode(payload, (address, uint256, PoolKey, PoolKey));
            _sell(token, amountIn, compPool, usdgEth);
            return "";
        }

        (uint256 ethIn, PoolKey memory pool) = abi.decode(payload, (uint256, PoolKey));
        return abi.encode(_buyAndBurn(ethIn, pool));
    }

    /// @dev component → (USDG →) ETH, alles binnen één unlock.
    function _sell(address token, uint256 amountIn, PoolKey memory compPool, PoolKey memory usdgEth) internal {
        // welke kant staat de component in deze pool, en waar wordt hij voor verkocht?
        bool compIsCurrency0;
        address proceeds;
        if (compPool.currency0 == token) {
            compIsCurrency0 = true;
            proceeds = compPool.currency1;
        } else if (compPool.currency1 == token) {
            compIsCurrency0 = false;
            proceeds = compPool.currency0;
        } else {
            revert BadRoute();
        }
        if (proceeds != address(0) && proceeds != usdg) revert BadRoute();

        // exact-input: we verkopen precies `amountIn` van de component
        (int256 a0, int256 a1) = _swap(compPool, compIsCurrency0, -int256(amountIn));
        int256 gained = compIsCurrency0 ? a1 : a0;

        // component afrekenen (we zijn hem schuldig)
        _settle(token, amountIn);

        if (proceeds == usdg) {
            // USDG doorswappen naar ETH: in de ETH/USDG-pool is ETH altijd currency0
            if (usdgEth.currency0 != address(0) || usdgEth.currency1 != usdg) revert BadRoute();
            // Niet settlen! Swap 1 gaf een USDG-tegoed, swap 2 maakt een even grote
            // USDG-schuld — binnen dezelfde unlock netten die tegen elkaar weg. Wie
            // hier echte USDG probeert over te maken, heeft die niet en de tx klapt.
            (int256 b0,) = _swap(usdgEth, false, -int256(gained)); // verkoop currency1 (USDG)
            poolManager.take(address(0), address(this), uint256(b0));
        } else {
            poolManager.take(address(0), address(this), uint256(gained));
        }
    }

    /// @dev ETH → targetToken, rechtstreeks naar het burn-adres.
    function _buyAndBurn(uint256 ethIn, PoolKey memory pool) internal returns (uint256 bought) {
        bool ethIsCurrency0 = pool.currency0 == address(0) && pool.currency1 == targetToken;
        if (!ethIsCurrency0) revert BadRoute(); // native ETH is per V4-conventie altijd currency0

        (, int256 a1) = _swap(targetPool, true, -int256(ethIn)); // exact-input ETH
        bought = uint256(a1);

        _settle(address(0), ethIn);
        // de gekochte tokens gaan direct naar 0xdead — ze raken dit contract niet aan
        poolManager.take(targetToken, DEAD, bought);
    }

    function _swap(PoolKey memory key, bool zeroForOne, int256 amountSpecified)
        internal
        returns (int256 amount0, int256 amount1)
    {
        int256 packed = poolManager.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecified, // < 0 = exact input
                sqrtPriceLimitX96: zeroForOne ? MIN_SQRT_PRICE + 1 : MAX_SQRT_PRICE - 1
            }),
            ""
        );
        int128 a0;
        int128 a1;
        assembly ("memory-safe") {
            a0 := sar(128, packed)
            a1 := signextend(15, packed)
        }
        amount0 = int256(a0);
        amount1 = int256(a1);
    }

    /// @dev schuld aan de PoolManager afrekenen: native met value, ERC-20 via sync+transfer.
    function _settle(address currency, uint256 amount) internal {
        if (currency == address(0)) {
            poolManager.settle{value: amount}();
        } else {
            poolManager.sync(currency);
            IERC20(currency).safeTransfer(address(poolManager), amount);
            poolManager.settle();
        }
    }

    function _freshPrice(IAggregatorV3 feed) internal view returns (uint256) {
        (uint80 roundId, int256 answer,, uint256 updatedAt, uint80 answeredInRound) = feed.latestRoundData();
        if (answer <= 0) revert BadPrice(address(feed));
        // een onvolledige of nog niet afgeronde round is even onbetrouwbaar als een stale;
        // met het brede 80h-venster (weekend-pauzes) is dit een goedkope extra check
        if (answeredInRound < roundId || updatedAt == 0) revert BadPrice(address(feed));
        if (block.timestamp - updatedAt > MAX_FEED_AGE) revert StaleFeed(address(feed));
        return uint256(answer);
    }
}