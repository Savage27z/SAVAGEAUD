// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// ════════════════════════════════════════════════════════════════════════════
//  ManagerHandler — reads VaultState, Dolomite prices, position snapshot.
//  VaultCore stays a dumb execution layer; all view data comes from here.
// ════════════════════════════════════════════════════════════════════════════

import {IBasaltMath} from "../../interfaces/IBasaltMath.sol";
import {IDolomiteIsolationVault} from "../../interfaces/IDolomiteVault.sol";
import {IDolomiteMargin} from "../../interfaces/IDolomiteMargin.sol";
import {IManagerHandlerVaultCore} from "../../interfaces/IManagerHandlerVaultCore.sol";
import {BasaltAddresses} from "../../libraries/BasaltAddresses.sol";
import {DolomiteReader} from "../../libraries/DolomiteReader.sol";
import {VaultState} from "../../core/VaultState.sol";
import {RebalanceSnapshot} from "./ManagerHandlerTypes.sol";

library ManagerHandlerReaders {
    function readVaultState(IManagerHandlerVaultCore targetVaultCore) internal view returns (VaultState) {
        return VaultState(targetVaultCore.basaltState());
    }

    function readKeeperDeadline(IManagerHandlerVaultCore targetVaultCore) internal view returns (uint256) {
        return readVaultState(targetVaultCore).keeperDeadline();
    }

    function readDolomiteIsolationVault(IManagerHandlerVaultCore targetVaultCore) internal view returns (address) {
        return readVaultState(targetVaultCore).dolomiteIsolationVault();
    }

    // ────────────────────────────────────────────────────────────────────────
    //  POSITION READERS (direct from Dolomite)
    // ────────────────────────────────────────────────────────────────────────

    function readVaultGmCollateralE18(IManagerHandlerVaultCore targetVaultCore) internal view returns (uint256) {
        address dolomiteIsolationVaultAddress = readDolomiteIsolationVault(targetVaultCore);
        if (dolomiteIsolationVaultAddress == address(0)) return 0;
        return DolomiteReader.getActualGmCollateralE18(
            IDolomiteMargin(BasaltAddresses.DOLOMITE_MARGIN),
            dolomiteIsolationVaultAddress
        );
    }

    function readVaultWbtcDebtE8(IManagerHandlerVaultCore targetVaultCore) internal view returns (uint256) {
        address dolomiteIsolationVaultAddress = readDolomiteIsolationVault(targetVaultCore);
        if (dolomiteIsolationVaultAddress == address(0)) return 0;
        return DolomiteReader.getActualWbtcDebtE8(
            IDolomiteMargin(BasaltAddresses.DOLOMITE_MARGIN),
            dolomiteIsolationVaultAddress
        );
    }

    function readIsVaultFrozen(IManagerHandlerVaultCore targetVaultCore) internal view returns (bool) {
        address dolomiteIsolationVaultAddress = readDolomiteIsolationVault(targetVaultCore);
        if (dolomiteIsolationVaultAddress == address(0)) return false;
        return IDolomiteIsolationVault(dolomiteIsolationVaultAddress).isVaultFrozen();
    }

    // ────────────────────────────────────────────────────────────────────────
    //  REBALANCE SNAPSHOT
    // ────────────────────────────────────────────────────────────────────────

    function readDolomiteSnapshot(IManagerHandlerVaultCore targetVaultCore)
        internal
        view
        returns (RebalanceSnapshot memory rebalanceSnapshot)
    {
        IDolomiteMargin dolomiteMargin = IDolomiteMargin(BasaltAddresses.DOLOMITE_MARGIN);
        IBasaltMath basaltMath = IBasaltMath(targetVaultCore.basaltMath());
        rebalanceSnapshot.gmPriceUsdE18 = DolomiteReader.getGmPriceE18(dolomiteMargin);
        uint256 wbtcPriceDolomiteE28 = DolomiteReader.getWbtcPriceE28(dolomiteMargin, basaltMath);
        rebalanceSnapshot.wbtcPriceUsdE18 = basaltMath.toWbtcPriceE18FromE28(wbtcPriceDolomiteE28);
        address dolomiteIsolationVaultAddress = readDolomiteIsolationVault(targetVaultCore);
        if (dolomiteIsolationVaultAddress != address(0)) {
            rebalanceSnapshot.totalGmCollateralE18 =
                DolomiteReader.getActualGmCollateralE18(dolomiteMargin, dolomiteIsolationVaultAddress);
            rebalanceSnapshot.totalWbtcDebtE8 =
                DolomiteReader.getActualWbtcDebtE8(dolomiteMargin, dolomiteIsolationVaultAddress);
        }
    }
}
