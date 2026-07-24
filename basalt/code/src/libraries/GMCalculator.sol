// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {SafeCast} from "openzeppelin-contracts/contracts/utils/math/SafeCast.sol";
import {SignedMath} from "openzeppelin-contracts/contracts/utils/math/SignedMath.sol";
import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";
import {BasaltPrecision} from "./BasaltPrecision.sol";

// ════════════════════════════════════════════════════════════════════════
//  GM TOKEN PRICE — on-chain, computed from GMX DataStore
//  https://github.com/gmx-io/gmx-synthetics/blob/10cfbce/contracts/market/MarketUtils.sol#L157-L400
//  https://github.com/gmx-io/gmx-synthetics/blob/10cfbce/contracts/data/Keys.sol
// ════════════════════════════════════════════════════════════════════════

interface IGmxDataStore {
    function getUint(bytes32 key) external view returns (uint256);
}

interface IGmToken {
    function totalSupply() external view returns (uint256);
}

library GMCalculator {
    using SafeCast for uint256;
    using SafeCast for int256;
    using SignedMath for int256;

    // ── Errors ──

    error GmPriceNonPositive(int256 price);
    // GMX schema rename — hardcoded key hash no longer matches storage.
    error GmxDataStoreZero(bytes32 field);

    // ── GMX DataStore Keys ──

    bytes32 internal constant POOL_AMOUNT =
        keccak256(abi.encode("POOL_AMOUNT"));
    bytes32 internal constant OPEN_INTEREST =
        keccak256(abi.encode("OPEN_INTEREST"));
    bytes32 internal constant OPEN_INTEREST_IN_TOKENS =
        keccak256(abi.encode("OPEN_INTEREST_IN_TOKENS"));
    bytes32 internal constant CUMULATIVE_BORROWING_FACTOR =
        keccak256(abi.encode("CUMULATIVE_BORROWING_FACTOR"));
    bytes32 internal constant TOTAL_BORROWING =
        keccak256(abi.encode("TOTAL_BORROWING"));
    bytes32 internal constant BORROWING_FEE_RECEIVER_FACTOR =
        keccak256(abi.encode("BORROWING_FEE_RECEIVER_FACTOR"));
    bytes32 internal constant POSITION_IMPACT_POOL_AMOUNT =
        keccak256(abi.encode("POSITION_IMPACT_POOL_AMOUNT"));
    bytes32 internal constant LENT_POSITION_IMPACT_POOL_AMOUNT =
        keccak256(abi.encode("LENT_POSITION_IMPACT_POOL_AMOUNT"));
    bytes32 internal constant MIN_POSITION_IMPACT_POOL_AMOUNT =
        keccak256(abi.encode("MIN_POSITION_IMPACT_POOL_AMOUNT"));
    bytes32 internal constant POSITION_IMPACT_POOL_DISTRIBUTION_RATE =
        keccak256(abi.encode("POSITION_IMPACT_POOL_DISTRIBUTION_RATE"));
    bytes32 internal constant POSITION_IMPACT_POOL_DISTRIBUTED_AT =
        keccak256(abi.encode("POSITION_IMPACT_POOL_DISTRIBUTED_AT"));
    bytes32 internal constant MAX_PNL_FACTOR =
        keccak256(abi.encode("MAX_PNL_FACTOR"));
    bytes32 internal constant MAX_PNL_FACTOR_FOR_DEPOSITS =
        keccak256(abi.encode("MAX_PNL_FACTOR_FOR_DEPOSITS"));

    // ── Params ──

    struct GmPriceParams {
        IGmxDataStore dataStore;
        address market;
        address indexToken;
        address longToken;
        address shortToken;
        uint256 indexPriceE30;
        uint256 longPriceE30;
        uint256 shortPriceE30;
    }

    // ════════════════════════════════════════════════════════════════════════
    //  1. GM PRICE — entry point
    //  https://github.com/gmx-io/gmx-synthetics/blob/10cfbce/contracts/market/MarketUtils.sol#L157-L187
    // ════════════════════════════════════════════════════════════════════════

    function calcGmPriceUsdE18(
        GmPriceParams memory p
    ) internal view returns (uint256) {
        int256 poolValueE30 = calcPoolValue(p);
        uint256 supply = IGmToken(p.market).totalSupply();

        if (supply == 0) return BasaltPrecision.WEI_PRECISION; // empty market = $1

        if (poolValueE30 == 0) return 0;
        if (poolValueE30 < 0) revert GmPriceNonPositive(poolValueE30);

        uint256 gmPriceE30 = Math.mulDiv(
            BasaltPrecision.WEI_PRECISION,
            uint256(poolValueE30),
            supply
        );
        return gmPriceE30 / BasaltPrecision.FLOAT_TO_WEI_DIVISOR;
    }

    // ════════════════════════════════════════════════════════════════════════
    //  2. POOL VALUE — main formula
    //  https://github.com/gmx-io/gmx-synthetics/blob/10cfbce/contracts/market/MarketUtils.sol#L298-L400
    // ════════════════════════════════════════════════════════════════════════

    function calcPoolValue(
        GmPriceParams memory p
    ) internal view returns (int256) {
        uint256 longTokenAmount = _getPoolAmount(
            p.dataStore,
            p.market,
            p.longToken
        );
        uint256 shortTokenAmount = _getPoolAmount(
            p.dataStore,
            p.market,
            p.shortToken
        );
        uint256 longTokenUsd = longTokenAmount * p.longPriceE30;
        uint256 shortTokenUsd = shortTokenAmount * p.shortPriceE30;

        int256 poolValue = (longTokenUsd + shortTokenUsd).toInt256();

        uint256 totalBorrowingFees = _getTotalBorrowingFees(p, true) +
            _getTotalBorrowingFees(p, false);
        uint256 borrowingFeePoolFactor = BasaltPrecision.FLOAT_PRECISION -
            p.dataStore.getUint(BORROWING_FEE_RECEIVER_FACTOR);
        poolValue += BasaltPrecision
            .applyFactor(totalBorrowingFees, borrowingFeePoolFactor)
            .toInt256();

        int256 longPnl = _getCappedPnl(
            p.dataStore,
            p.market,
            true,
            _getPnl(p, true),
            longTokenUsd
        );
        int256 shortPnl = _getCappedPnl(
            p.dataStore,
            p.market,
            false,
            _getPnl(p, false),
            shortTokenUsd
        );
        poolValue = poolValue - (longPnl + shortPnl);

        uint256 impactPoolAmount = _getNextImpactPoolAmount(
            p.dataStore,
            p.market
        );
        poolValue -= (impactPoolAmount * p.indexPriceE30).toInt256();

        uint256 lentImpactPoolAmount = p.dataStore.getUint(
            keccak256(abi.encode(LENT_POSITION_IMPACT_POOL_AMOUNT, p.market))
        );
        poolValue += (lentImpactPoolAmount * p.indexPriceE30).toInt256();

        return poolValue;
    }

    // ════════════════════════════════════════════════════════════════════════
    //  3. POOL AMOUNT — DataStore read
    //  https://github.com/gmx-io/gmx-synthetics/blob/10cfbce/contracts/market/MarketUtils.sol#L507-L513
    // ════════════════════════════════════════════════════════════════════════

    function _getPoolAmount(
        IGmxDataStore ds,
        address market,
        address token
    ) internal view returns (uint256) {
        uint256 amount = ds.getUint(
            keccak256(abi.encode(POOL_AMOUNT, market, token))
        );
        if (amount == 0) revert GmxDataStoreZero(POOL_AMOUNT);
        return amount;
    }

    // ════════════════════════════════════════════════════════════════════════
    //  4. BORROWING FEES — called first in calcPoolValue
    //  https://github.com/gmx-io/gmx-synthetics/blob/10cfbce/contracts/market/MarketUtils.sol#L2960-L2981
    // ════════════════════════════════════════════════════════════════════════

    function _getTotalBorrowingFees(
        GmPriceParams memory p,
        bool isLong
    ) internal view returns (uint256) {
        uint256 openInterest = _getOpenInterest(p, isLong);
        uint256 cumulativeFactor = p.dataStore.getUint(
            keccak256(abi.encode(CUMULATIVE_BORROWING_FACTOR, p.market, isLong))
        );
        if (cumulativeFactor == 0) {
            revert GmxDataStoreZero(CUMULATIVE_BORROWING_FACTOR);
        }
        uint256 totalBorrowing = p.dataStore.getUint(
            keccak256(abi.encode(TOTAL_BORROWING, p.market, isLong))
        );
        // lazy update: computed can briefly exceed totalBorrowing → floor at 0.
        uint256 computed = BasaltPrecision.applyFactor(openInterest, cumulativeFactor);
        return computed > totalBorrowing ? computed - totalBorrowing : 0;
    }

    // ════════════════════════════════════════════════════════════════════════
    //  5. OPEN INTEREST — used by borrowing fees AND PnL
    //  https://github.com/gmx-io/gmx-synthetics/blob/10cfbce/contracts/market/MarketUtils.sol#L2203-L2222
    // ════════════════════════════════════════════════════════════════════════

    function _getOpenInterest(
        GmPriceParams memory p,
        bool isLong
    ) internal view returns (uint256) {
        uint256 total = _getOI(p.dataStore, p.market, p.longToken, isLong) +
            _getOI(p.dataStore, p.market, p.shortToken, isLong);
        if (total == 0) revert GmxDataStoreZero(OPEN_INTEREST);
        return total;
    }

    function _getOI(
        IGmxDataStore ds,
        address market,
        address collateral,
        bool isLong
    ) internal view returns (uint256) {
        return
            ds.getUint(
                keccak256(abi.encode(OPEN_INTEREST, market, collateral, isLong))
            );
    }

    // ════════════════════════════════════════════════════════════════════════
    //  6. OPEN INTEREST IN TOKENS — used by PnL AND exposure
    //  https://github.com/gmx-io/gmx-synthetics/blob/10cfbce/contracts/market/MarketUtils.sol#L2309-L2333
    // ════════════════════════════════════════════════════════════════════════

    function _getOpenInterestInTokens(
        GmPriceParams memory p,
        bool isLong
    ) internal view returns (uint256) {
        uint256 total = _getOITokens(
            p.dataStore,
            p.market,
            p.longToken,
            isLong
        ) + _getOITokens(p.dataStore, p.market, p.shortToken, isLong);
        if (total == 0) revert GmxDataStoreZero(OPEN_INTEREST_IN_TOKENS);
        return total;
    }

    function _getOITokens(
        IGmxDataStore ds,
        address market,
        address collateral,
        bool isLong
    ) internal view returns (uint256) {
        return
            ds.getUint(
                keccak256(
                    abi.encode(
                        OPEN_INTEREST_IN_TOKENS,
                        market,
                        collateral,
                        isLong
                    )
                )
            );
    }

    // ════════════════════════════════════════════════════════════════════════
    //  7. PNL — trader profit/loss
    //  https://github.com/gmx-io/gmx-synthetics/blob/10cfbce/contracts/market/MarketUtils.sol#L480-L500
    // ════════════════════════════════════════════════════════════════════════

    function _getPnl(
        GmPriceParams memory p,
        bool isLong
    ) internal view returns (int256) {
        int256 openInterest = _getOpenInterest(p, isLong).toInt256();
        uint256 openInterestInTokens = _getOpenInterestInTokens(p, isLong);

        if (openInterest == 0 || openInterestInTokens == 0) return 0;

        int256 openInterestValue = (openInterestInTokens * p.indexPriceE30)
            .toInt256();
        return
            isLong
                ? openInterestValue - openInterest
                : openInterest - openInterestValue;
    }

    // ════════════════════════════════════════════════════════════════════════
    //  8. CAPPED PNL — cap trader profit to protect pool
    //  https://github.com/gmx-io/gmx-synthetics/blob/10cfbce/contracts/market/MarketUtils.sol#L429-L443
    // ════════════════════════════════════════════════════════════════════════

    function _getCappedPnl(
        IGmxDataStore ds,
        address market,
        bool isLong,
        int256 pnl,
        uint256 poolUsd
    ) internal view returns (int256) {
        if (pnl < 0) return pnl;
        uint256 maxPnlFactor = ds.getUint(
            keccak256(
                abi.encode(
                    MAX_PNL_FACTOR,
                    MAX_PNL_FACTOR_FOR_DEPOSITS,
                    market,
                    isLong
                )
            )
        );
        if (maxPnlFactor == 0) revert GmxDataStoreZero(MAX_PNL_FACTOR);
        int256 maxPnl = BasaltPrecision
            .applyFactor(poolUsd, maxPnlFactor)
            .toInt256();
        return pnl > maxPnl ? maxPnl : pnl;
    }

    // ════════════════════════════════════════════════════════════════════════
    //  9. IMPACT POOL — with time-based distribution
    //  https://github.com/gmx-io/gmx-synthetics/blob/10cfbce/contracts/market/MarketUtils.sol#L2910-L2952
    // ════════════════════════════════════════════════════════════════════════

    function _getNextImpactPoolAmount(
        IGmxDataStore ds,
        address market
    ) internal view returns (uint256) {
        uint256 poolAmount = ds.getUint(
            keccak256(abi.encode(POSITION_IMPACT_POOL_AMOUNT, market))
        );
        if (poolAmount == 0) return 0;

        uint256 distributionRate = ds.getUint(
            keccak256(
                abi.encode(POSITION_IMPACT_POOL_DISTRIBUTION_RATE, market)
            )
        );
        if (distributionRate == 0) return poolAmount;

        uint256 minAmount = ds.getUint(
            keccak256(abi.encode(MIN_POSITION_IMPACT_POOL_AMOUNT, market))
        );
        if (poolAmount <= minAmount) return poolAmount;

        uint256 maxDistribution = poolAmount - minAmount;

        uint256 distributedAt = ds.getUint(
            keccak256(abi.encode(POSITION_IMPACT_POOL_DISTRIBUTED_AT, market))
        );
        uint256 duration = distributedAt == 0
            ? 0
            : block.timestamp - distributedAt;
        uint256 distribution = BasaltPrecision.applyFactor(
            duration,
            distributionRate
        );

        if (distribution > maxDistribution) distribution = maxDistribution;

        return poolAmount - distribution;
    }

}
