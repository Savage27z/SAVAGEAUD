// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IndexVault} from "./IndexVault.sol";
import {IAggregatorV3} from "./interfaces/IAggregatorV3.sol";

/// @title NavLens — view-only NAV-berekening voor IndexVault via Chainlink
/// @notice Losse lens zodat de vault zelf geen oracle-afhankelijkheid heeft.
///         Feeds op Robinhood Chain: USD, 8 decimals, heartbeat 24h, en de prijs
///         bevat de corporate-action multiplier al (dus raw balance * prijs klopt).
contract NavLens {
    struct FeedConfig {
        address token;
        address feed;
    }

    struct ComponentView {
        address token;
        uint256 balance; // raw balance in de vault
        int256 priceUSD8; // laatste Chainlink-prijs (8 dec)
        uint256 updatedAt;
        bool stale;
        uint256 valueUSD8; // balance * prijs, geschaald naar 8 dec
    }

    uint256 public constant MAX_FEED_AGE = 80 hours; // heartbeat 24h + weekend (feeds pauzeren buiten beurstijden)

    IndexVault public immutable vault;
    mapping(address => address) public feedOf;
    address[] private _tokens;

    error UnknownComponent(address token);
    error StaleFeed(address token);
    error BadPrice(address token);

    constructor(IndexVault vault_, FeedConfig[] memory feeds_) {
        vault = vault_;
        for (uint256 i = 0; i < feeds_.length; i++) {
            feedOf[feeds_[i].token] = feeds_[i].feed;
            _tokens.push(feeds_[i].token);
        }
        // Elke vault-component moet een feed hebben.
        address[] memory comps = vault_.allComponents();
        for (uint256 i = 0; i < comps.length; i++) {
            if (feedOf[comps[i]] == address(0)) revert UnknownComponent(comps[i]);
        }
    }

    /// @notice Totale NAV van de vault in USD (8 decimals). Reverts bij stale feed.
    function totalNavUSD8() public view returns (uint256 nav) {
        address[] memory comps = vault.allComponents();
        for (uint256 i = 0; i < comps.length; i++) {
            (uint256 price,) = _freshPrice(comps[i]);
            uint256 bal = IERC20(comps[i]).balanceOf(address(vault));
            nav += (bal * price) / 1e18; // token 18 dec * prijs 8 dec / 1e18 = 8 dec
        }
    }

    /// @notice NAV per index-share in USD (8 decimals). 0 als er geen supply is.
    function navPerShareUSD8() external view returns (uint256) {
        uint256 supply = vault.totalSupply();
        if (supply == 0) return 0;
        return (totalNavUSD8() * 1e18) / supply;
    }

    /// @notice USD-waarde (8 dec) van de creation basket voor 1e18 shares —
    ///         wat een mint kost, onafhankelijk van vault-balansen.
    function mintCostUSD8PerShare() external view returns (uint256 cost) {
        address[] memory comps = vault.allComponents();
        for (uint256 i = 0; i < comps.length; i++) {
            (uint256 price,) = _freshPrice(comps[i]);
            cost += (vault.unitsPerShare(comps[i]) * price) / 1e18;
        }
    }

    /// @notice Volledige breakdown voor de frontend; revert niet op stale feeds
    ///         maar markeert ze.
    function breakdown() external view returns (ComponentView[] memory views) {
        address[] memory comps = vault.allComponents();
        views = new ComponentView[](comps.length);
        for (uint256 i = 0; i < comps.length; i++) {
            IAggregatorV3 feed = IAggregatorV3(feedOf[comps[i]]);
            (, int256 answer,, uint256 updatedAt,) = feed.latestRoundData();
            uint256 bal = IERC20(comps[i]).balanceOf(address(vault));
            bool stale = block.timestamp - updatedAt > MAX_FEED_AGE || answer <= 0;
            views[i] = ComponentView({
                token: comps[i],
                balance: bal,
                priceUSD8: answer,
                updatedAt: updatedAt,
                stale: stale,
                valueUSD8: answer > 0 ? (bal * uint256(answer)) / 1e18 : 0
            });
        }
    }

    function _freshPrice(address token) internal view returns (uint256 price, uint256 updatedAt) {
        address feed = feedOf[token];
        if (feed == address(0)) revert UnknownComponent(token);
        (, int256 answer,, uint256 updatedAt_,) = IAggregatorV3(feed).latestRoundData();
        if (answer <= 0) revert BadPrice(token);
        if (block.timestamp - updatedAt_ > MAX_FEED_AGE) revert StaleFeed(token);
        return (uint256(answer), updatedAt_);
    }
}