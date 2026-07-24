// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// https://github.com/gmx-io/gmx-synthetics/blob/10cfbce/contracts/market/Market.sol#L37-L42
struct MarketProps {
    address marketToken;
    address indexToken;
    address longToken;
    address shortToken;
}

// https://github.com/gmx-io/gmx-synthetics/blob/10cfbce/contracts/price/Price.sol#L10-L13
struct PriceProps {
    uint256 min;
    uint256 max;
}

// https://github.com/gmx-io/gmx-synthetics/blob/10cfbce/contracts/reader/Reader.sol#L193-L212
interface IGmxReader {
    function getMarketTokenPrice(
        address dataStore,
        MarketProps memory market,
        PriceProps memory indexTokenPrice,
        PriceProps memory longTokenPrice,
        PriceProps memory shortTokenPrice,
        bytes32 pnlFactorType,
        bool maximize
    ) external view returns (int256, MarketPoolValueInfoProps memory);
}

// https://github.com/gmx-io/gmx-synthetics/blob/10cfbce/contracts/market/MarketPoolValueInfo.sol#L20-L36
struct MarketPoolValueInfoProps {
    int256 poolValue;
    int256 longPnl;
    int256 shortPnl;
    int256 netPnl;
    uint256 longTokenAmount;
    uint256 shortTokenAmount;
    uint256 longTokenUsd;
    uint256 shortTokenUsd;
    uint256 totalBorrowingFees;
    uint256 borrowingFeePoolFactor;
    uint256 impactPoolAmount;
    uint256 lentImpactPoolAmount;
}
