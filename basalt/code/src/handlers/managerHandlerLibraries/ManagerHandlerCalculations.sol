// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// ════════════════════════════════════════════════════════════════════════════
//  ManagerHandler — pure / view math (LTV, rebalance sizing, slippage)
// ════════════════════════════════════════════════════════════════════════════

import {BasaltMath} from "../../pure/BasaltMath.sol";
import {IManagerHandlerVaultCore} from "../../interfaces/IManagerHandlerVaultCore.sol";
import {ManagerHandlerReaders} from "./ManagerHandlerReaders.sol";
import {RebalanceSnapshot} from "./ManagerHandlerTypes.sol";

library ManagerHandlerCalculations {
    function calcExpectedGmOutE18(
        IManagerHandlerVaultCore targetVaultCore,
        uint256 borrowWbtcE8,
        RebalanceSnapshot memory rebalanceSnapshot
    ) internal view returns (uint256) {
        return BasaltMath(targetVaultCore.basaltMath())
            .calcExpectedGmOutE18(borrowWbtcE8, rebalanceSnapshot.wbtcPriceUsdE18, rebalanceSnapshot.gmPriceUsdE18);
    }

    function calcExpectedWbtcOutE8(
        IManagerHandlerVaultCore targetVaultCore,
        uint256 gmToSellE18,
        RebalanceSnapshot memory rebalanceSnapshot
    ) internal view returns (uint256) {
        uint256 unwrapBps = ManagerHandlerReaders.readVaultState(targetVaultCore).unwrapLongShareBps();
        return BasaltMath(targetVaultCore.basaltMath())
            .calcExpectedWbtcOutLongSideE8(gmToSellE18, rebalanceSnapshot.gmPriceUsdE18, rebalanceSnapshot.wbtcPriceUsdE18, unwrapBps);
    }

    function applySlippage(BasaltMath basaltMath, uint256 amount, uint256 slippageBps) internal pure returns (uint256) {
        return basaltMath.applySlippage(amount, slippageBps);
    }

    // returns (0,0,0) on no GM collateral; caller decides revert.
    function calcCollDebtUsdAndLtvBps(BasaltMath basaltMath, RebalanceSnapshot memory rebalanceSnapshot)
        internal
        pure
        returns (uint256 collUsdE18, uint256 debtUsdE18, uint256 ltvBps)
    {
        if (rebalanceSnapshot.totalGmCollateralE18 == 0) {
            return (0, 0, 0);
        }
        collUsdE18 = basaltMath.calcCollUsdE18(rebalanceSnapshot.totalGmCollateralE18, rebalanceSnapshot.gmPriceUsdE18);
        debtUsdE18 = basaltMath.calcDebtUsdE18(rebalanceSnapshot.totalWbtcDebtE8, rebalanceSnapshot.wbtcPriceUsdE18);
        ltvBps = basaltMath.calcLtvBps(debtUsdE18, collUsdE18);
    }

    function currentLtvBpsFromSnapshot(BasaltMath basaltMath, RebalanceSnapshot memory rebalanceSnapshot)
        internal
        pure
        returns (uint256)
    {
        (,, uint256 ltvBps) = calcCollDebtUsdAndLtvBps(basaltMath, rebalanceSnapshot);
        return ltvBps;
    }

    function gmToSellForRebalanceDown(
        BasaltMath basaltMath,
        RebalanceSnapshot memory rebalanceSnapshot,
        uint256 collUsdE18,
        uint256 debtUsdE18,
        uint256 targetLtvBps
    ) internal pure returns (uint256 gmToSellE18) {
        uint256 targetDebtUsdE18 = basaltMath.calcTargetDebtUsdE18(collUsdE18, targetLtvBps);
        uint256 gapUsdE18 = basaltMath.subFloorZero(debtUsdE18, targetDebtUsdE18);
        uint256 deltaUsdE18 = basaltMath.calcRebalanceDelta(gapUsdE18, targetLtvBps);
        gmToSellE18 = basaltMath.calcGmFromUsdE18(deltaUsdE18, rebalanceSnapshot.gmPriceUsdE18);
    }

    function borrowWbtcForRebalanceUp(
        BasaltMath basaltMath,
        RebalanceSnapshot memory rebalanceSnapshot,
        uint256 collUsdE18,
        uint256 debtUsdE18,
        uint256 targetLtvBps
    ) internal pure returns (uint256 borrowWbtcE8) {
        uint256 targetDebtUsdE18 = basaltMath.calcTargetDebtUsdE18(collUsdE18, targetLtvBps);
        uint256 gapUsdE18 = basaltMath.subFloorZero(targetDebtUsdE18, debtUsdE18);
        uint256 deltaUsdE18 = basaltMath.calcRebalanceDelta(gapUsdE18, targetLtvBps);
        borrowWbtcE8 = basaltMath.calcWbtcFromUsdE18(deltaUsdE18, rebalanceSnapshot.wbtcPriceUsdE18);
    }
}
