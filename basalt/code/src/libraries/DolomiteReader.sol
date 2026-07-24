// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IBasaltMath} from "../interfaces/IBasaltMath.sol";
import {IChainlinkAggregator} from "../interfaces/IChainlinkAggregator.sol";
import {IDolomiteMargin} from "../interfaces/IDolomiteMargin.sol";
import {BasaltAddresses} from "./BasaltAddresses.sol";
import {BasaltConstants} from "./BasaltConstants.sol";
import {OracleGuard} from "./OracleGuard.sol";

// ════════════════════════════════════════════════════════════════════════
//  DOLOMITE PRICE READER
//  DolomiteMargin price precision = (36 - tokenDecimals):
//    WBTC → E28; USDC → E30; GM → E18.
//  https://github.com/dolomite-exchange/dolomite-margin/blob/add64ba/contracts/protocol/impl/OperationImpl.sol
// ════════════════════════════════════════════════════════════════════════

library DolomiteReader {
    error OraclePriceSpreadTooWide(uint256 dolomitePriceE8, uint256 chainlinkPriceE8, uint256 spreadBps);

    uint256 internal constant MARKET_WBTC = BasaltConstants.DOLOMITE_MARKET_WBTC;
    uint256 internal constant MARKET_GM = BasaltConstants.DOLOMITE_MARKET_GM;

    // ════════════════════════════════════════════════════════════════════════
    //  PRICE READS
    // ════════════════════════════════════════════════════════════════════════

    // GM token price from Dolomite oracle (E18).
    // https://github.com/dolomite-exchange/dolomite-margin/blob/add64ba/contracts/protocol/Getters.sol#L268
    function getGmPriceE18(
        IDolomiteMargin dolomiteMargin
    ) internal view returns (uint256) {
        return dolomiteMargin.getMarketPrice(MARKET_GM).value;
    }

    // WBTC price from Dolomite (E28); cross-checked against Chainlink (fail-closed on divergence).
    function getWbtcPriceE28(
        IDolomiteMargin dolomiteMargin,
        IBasaltMath basaltMath
    ) internal view returns (uint256) {
        uint256 dolomitePriceE28 = dolomiteMargin.getMarketPrice(MARKET_WBTC).value;
        uint256 chainlinkPriceE8 = OracleGuard.readChainlinkPrice(
            IChainlinkAggregator(BasaltAddresses.CL_WBTC_USD),
            BasaltConstants.ORACLE_WBTC_MAX_AGE,
            BasaltConstants.ORACLE_WBTC_MAX_PRICE_E8
        );
        uint256 dolomitePriceE8 = basaltMath.toWbtcPriceE8FromE28(dolomitePriceE28);
        uint256 priceDiffE8 = basaltMath.calcAbsDiff(dolomitePriceE8, chainlinkPriceE8);
        uint256 spreadBps = basaltMath.calcBpsRatio(priceDiffE8, chainlinkPriceE8);
        if (spreadBps > BasaltConstants.ORACLE_PRICE_SPREAD_BPS) {
            revert OraclePriceSpreadTooWide(dolomitePriceE8, chainlinkPriceE8, spreadBps);
        }
        return dolomitePriceE28;
    }

    uint256 internal constant ISOLATION_ACCOUNT = BasaltConstants.DOLOMITE_ISOLATION_ACCOUNT;

    // ════════════════════════════════════════════════════════════════════════
    //  BORROW INDEX
    // ════════════════════════════════════════════════════════════════════════

    // Current WBTC borrow index (E18).
    function getWbtcBorrowIndexE18(
        IDolomiteMargin dolomiteMargin
    ) internal view returns (uint256) {
        return uint256(dolomiteMargin.getMarketCurrentIndex(MARKET_WBTC).borrow);
    }

    // ════════════════════════════════════════════════════════════════════════
    //  ON-CHAIN BALANCE READS
    // ════════════════════════════════════════════════════════════════════════

    // Live GM collateral on the isolation account (sign=true → collateral).
    // https://github.com/dolomite-exchange/dolomite-margin/blob/add64ba/contracts/protocol/Getters.sol#L496
    function getActualGmCollateralE18(
        IDolomiteMargin dolomiteMargin,
        address dolomiteIsolationVaultAddress
    ) internal view returns (uint256) {
        IDolomiteMargin.Wei memory gmAccountWei = dolomiteMargin.getAccountWei(
            IDolomiteMargin.AccountInfo({
                owner: dolomiteIsolationVaultAddress,
                number: ISOLATION_ACCOUNT
            }),
            MARKET_GM
        );
        if (gmAccountWei.sign && gmAccountWei.value > 0) return gmAccountWei.value;
        return 0;
    }

    // Live WBTC debt on the isolation account (only when net-borrowed).
    function getActualWbtcDebtE8(
        IDolomiteMargin dolomiteMargin,
        address dolomiteIsolationVaultAddress
    ) internal view returns (uint256) {
        IDolomiteMargin.Wei memory wbtcAccountWei = dolomiteMargin.getAccountWei(
            IDolomiteMargin.AccountInfo({
                owner: dolomiteIsolationVaultAddress,
                number: ISOLATION_ACCOUNT
            }),
            MARKET_WBTC
        );
        if (!wbtcAccountWei.sign && wbtcAccountWei.value > 0) return wbtcAccountWei.value;
        return 0;
    }

    // Live WBTC surplus on the isolation account (only when net-positive).
    function getActualWbtcSurplusE8(
        IDolomiteMargin dolomiteMargin,
        address dolomiteIsolationVaultAddress
    ) internal view returns (uint256) {
        IDolomiteMargin.Wei memory wbtcAccountWei = dolomiteMargin.getAccountWei(
            IDolomiteMargin.AccountInfo({
                owner: dolomiteIsolationVaultAddress,
                number: ISOLATION_ACCOUNT
            }),
            MARKET_WBTC
        );
        if (wbtcAccountWei.sign && wbtcAccountWei.value > 0) return wbtcAccountWei.value;
        return 0;
    }

    // ════════════════════════════════════════════════════════════════════════
    //  NAV COMPUTATION (single source of truth)
    // ════════════════════════════════════════════════════════════════════════

    // NAV in USD E18; 0 if no iso vault.
    function getActualNavUsdE18(
        IDolomiteMargin dolomiteMargin,
        address dolomiteIsolationVaultAddress,
        IBasaltMath basaltMath
    ) internal view returns (uint256) {
        if (dolomiteIsolationVaultAddress == address(0)) return 0;
        uint256 gmCollateralE18 = getActualGmCollateralE18(dolomiteMargin, dolomiteIsolationVaultAddress);
        uint256 wbtcDebtE8 = getActualWbtcDebtE8(dolomiteMargin, dolomiteIsolationVaultAddress);
        uint256 wbtcSurplusE8 = getActualWbtcSurplusE8(dolomiteMargin, dolomiteIsolationVaultAddress);
        uint256 gmPriceUsdE18 = getGmPriceE18(dolomiteMargin);
        uint256 wbtcPriceUsdE18 = basaltMath.toWbtcPriceE18FromE28(getWbtcPriceE28(dolomiteMargin, basaltMath));
        return basaltMath.calcNavUsdE18(gmCollateralE18, wbtcSurplusE8, wbtcDebtE8, gmPriceUsdE18, wbtcPriceUsdE18);
    }
}
