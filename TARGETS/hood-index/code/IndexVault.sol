// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";

/// @title IndexVault — on-chain index op Robinhood Chain stock tokens
/// @notice ERC-20 index-share met in-kind creation/redemption, zoals een ETF.
///
/// Ontwerpprincipes (bewust rug-proof):
///  - De basket (tokens + units per share) is IMMUTABLE na deploy. Niemand kan
///    componenten wisselen, wegtrekken of de verhoudingen aanpassen.
///  - Geen upgradability, geen pause, geen admin-transfer van onderliggende assets.
///  - Fees zijn hard gecapt in code; de owner kan ze alleen binnen de caps zetten
///    en de feeCollector wijzigen. Meer niet.
///  - Mint/redeem is in-kind: de vault swapt zelf nooit en heeft geen oracle nodig
///    om correct te zijn. NAV-berekening leeft in een aparte view-lens.
///
/// Corporate actions: Robinhood stock tokens (ERC-8056) verwerken dividenden en
/// splits via een on-chain uiMultiplier; raw balances blijven statisch en de
/// Chainlink-feedprijs bevat de multiplier al. De vault rekent daarom uitsluitend
/// met raw balances en hoeft niets te doen bij corporate actions.
contract IndexVault is ERC20, ReentrancyGuard, Ownable2Step {
    using SafeERC20 for IERC20;

    uint256 public constant UNIT = 1e18;

    /// @notice Harde caps — kunnen nooit overschreden worden.
    uint16 public constant MAX_MINT_FEE_BPS = 100; // 1%
    uint16 public constant MAX_REDEEM_FEE_BPS = 100; // 1%
    uint16 public constant MAX_STREAMING_FEE_BPS = 200; // 2% per jaar
    uint256 public constant BPS = 10_000;

    /// @notice Basket-componenten (immutable na deploy).
    address[] public components;
    /// @notice Hoeveelheid van component i (in wei van dat token) per 1e18 index-shares.
    mapping(address => uint256) public unitsPerShare;

    uint16 public mintFeeBps;
    uint16 public redeemFeeBps;
    uint16 public streamingFeeBps;
    address public feeCollector;
    uint64 public lastAccrual;

    event Minted(address indexed sender, address indexed to, uint256 sharesOut, uint256 feeShares);
    event Redeemed(address indexed sender, address indexed to, uint256 sharesIn, uint256 feeShares);
    event StreamingFeeAccrued(uint256 feeShares);
    event FeesUpdated(uint16 mintFeeBps, uint16 redeemFeeBps, uint16 streamingFeeBps);
    event FeeCollectorUpdated(address feeCollector);

    error LengthMismatch();
    error EmptyBasket();
    error ZeroAddress();
    error ZeroUnits();
    error DuplicateComponent();
    error ZeroShares();
    error FeeAboveCap();

    constructor(
        string memory name_,
        string memory symbol_,
        address[] memory components_,
        uint256[] memory unitsPerShare_,
        uint16 mintFeeBps_,
        uint16 redeemFeeBps_,
        uint16 streamingFeeBps_,
        address feeCollector_,
        address owner_
    ) ERC20(name_, symbol_) Ownable(owner_) {
        if (components_.length == 0) revert EmptyBasket();
        if (components_.length != unitsPerShare_.length) revert LengthMismatch();
        if (feeCollector_ == address(0)) revert ZeroAddress();

        for (uint256 i = 0; i < components_.length; i++) {
            address token = components_[i];
            if (token == address(0)) revert ZeroAddress();
            if (unitsPerShare_[i] == 0) revert ZeroUnits();
            if (unitsPerShare[token] != 0) revert DuplicateComponent();
            unitsPerShare[token] = unitsPerShare_[i];
            components.push(token);
        }

        _setFees(mintFeeBps_, redeemFeeBps_, streamingFeeBps_);
        feeCollector = feeCollector_;
        lastAccrual = uint64(block.timestamp);
    }

    // ---------------------------------------------------------------- views

    function componentCount() external view returns (uint256) {
        return components.length;
    }

    function allComponents() external view returns (address[] memory) {
        return components;
    }

    /// @notice Benodigde component-bedragen om `shares` te minten (afgerond omhoog).
    function amountsForMint(uint256 shares) public view returns (uint256[] memory amounts) {
        amounts = new uint256[](components.length);
        for (uint256 i = 0; i < components.length; i++) {
            amounts[i] = _ceilDiv(unitsPerShare[components[i]] * shares, UNIT);
        }
    }

    /// @notice Component-bedragen die `shares` opleveren bij redeem (pro-rata op
    ///         werkelijke vault-balansen, afgerond omlaag). Pro-rata in plaats van
    ///         units zodat afrondingsstof in de vault holders toekomt en de vault
    ///         nooit insolvent kan raken.
    function amountsForRedeem(uint256 shares) public view returns (uint256[] memory amounts) {
        uint256 supply = totalSupply() + _pendingStreamingFee();
        amounts = new uint256[](components.length);
        for (uint256 i = 0; i < components.length; i++) {
            uint256 bal = IERC20(components[i]).balanceOf(address(this));
            amounts[i] = supply == 0 ? 0 : (bal * shares) / supply;
        }
    }

    // ------------------------------------------------------------- mutating

    /// @notice In-kind mint: trekt de benodigde componenten van msg.sender en mint
    ///         `shares`, waarvan de mint-fee (in shares) naar de feeCollector gaat.
    /// @dev Caller moet approvals hebben gezet voor alle componenten.
    function mint(uint256 shares, address to) external nonReentrant returns (uint256 sharesOut) {
        if (shares == 0) revert ZeroShares();
        _accrueStreamingFee();

        uint256[] memory amounts = amountsForMint(shares);
        for (uint256 i = 0; i < components.length; i++) {
            IERC20(components[i]).safeTransferFrom(msg.sender, address(this), amounts[i]);
        }

        uint256 feeShares = (shares * mintFeeBps) / BPS;
        sharesOut = shares - feeShares;
        if (feeShares > 0) _mint(feeCollector, feeShares);
        _mint(to, sharesOut);
        emit Minted(msg.sender, to, sharesOut, feeShares);
    }

    /// @notice In-kind redeem: brandt `shares` en betaalt componenten pro-rata uit.
    ///         De redeem-fee (in shares) gaat naar de feeCollector.
    function redeem(uint256 shares, address to) external nonReentrant returns (uint256[] memory amounts) {
        if (shares == 0) revert ZeroShares();
        _accrueStreamingFee();

        uint256 feeShares = (shares * redeemFeeBps) / BPS;
        uint256 netShares = shares - feeShares;

        amounts = new uint256[](components.length);
        uint256 supply = totalSupply();
        for (uint256 i = 0; i < components.length; i++) {
            uint256 bal = IERC20(components[i]).balanceOf(address(this));
            amounts[i] = (bal * netShares) / supply;
        }

        if (feeShares > 0) _transfer(msg.sender, feeCollector, feeShares);
        _burn(msg.sender, netShares);
        for (uint256 i = 0; i < components.length; i++) {
            if (amounts[i] > 0) IERC20(components[i]).safeTransfer(to, amounts[i]);
        }
        emit Redeemed(msg.sender, to, shares, feeShares);
    }

    /// @notice Accrue de streaming fee expliciet (gebeurt ook bij elke mint/redeem).
    function accrueStreamingFee() external {
        _accrueStreamingFee();
    }

    // ---------------------------------------------------------------- admin

    /// @notice Fees aanpassen — alleen binnen de harde caps.
    function setFees(uint16 mintFeeBps_, uint16 redeemFeeBps_, uint16 streamingFeeBps_) external onlyOwner {
        _accrueStreamingFee();
        _setFees(mintFeeBps_, redeemFeeBps_, streamingFeeBps_);
    }

    function setFeeCollector(address feeCollector_) external onlyOwner {
        if (feeCollector_ == address(0)) revert ZeroAddress();
        feeCollector = feeCollector_;
        emit FeeCollectorUpdated(feeCollector_);
    }

    // ------------------------------------------------------------- internal

    function _setFees(uint16 mintFeeBps_, uint16 redeemFeeBps_, uint16 streamingFeeBps_) internal {
        if (mintFeeBps_ > MAX_MINT_FEE_BPS || redeemFeeBps_ > MAX_REDEEM_FEE_BPS || streamingFeeBps_ > MAX_STREAMING_FEE_BPS) {
            revert FeeAboveCap();
        }
        mintFeeBps = mintFeeBps_;
        redeemFeeBps = redeemFeeBps_;
        streamingFeeBps = streamingFeeBps_;
        emit FeesUpdated(mintFeeBps_, redeemFeeBps_, streamingFeeBps_);
    }

    function _pendingStreamingFee() internal view returns (uint256) {
        uint256 supply = totalSupply();
        if (supply == 0 || streamingFeeBps == 0) return 0;
        uint256 dt = block.timestamp - lastAccrual;
        return (supply * streamingFeeBps * dt) / (BPS * 365 days);
    }

    function _accrueStreamingFee() internal {
        uint256 feeShares = _pendingStreamingFee();
        lastAccrual = uint64(block.timestamp);
        if (feeShares > 0) {
            _mint(feeCollector, feeShares);
            emit StreamingFeeAccrued(feeShares);
        }
    }

    function _ceilDiv(uint256 a, uint256 b) internal pure returns (uint256) {
        return a == 0 ? 0 : (a - 1) / b + 1;
    }
}