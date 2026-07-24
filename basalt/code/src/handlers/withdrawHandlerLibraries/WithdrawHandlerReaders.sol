// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IBasaltMath} from "../../interfaces/IBasaltMath.sol";
import {IDolomiteIsolationVault} from "../../interfaces/IDolomiteVault.sol";
import {IDolomiteMargin} from "../../interfaces/IDolomiteMargin.sol";
import {IWithdrawHandlerVaultCore} from "../../interfaces/IWithdrawHandlerVaultCore.sol";
import {BasaltAddresses} from "../../libraries/BasaltAddresses.sol";
import {BasaltConstants} from "../../libraries/BasaltConstants.sol";
import {DolomiteReader} from "../../libraries/DolomiteReader.sol";
import {VaultState} from "../../core/VaultState.sol";

library WithdrawHandlerReaders {
    // ────────────────────────────────────────────────────────────────────────
    //  ADDRESS READERS
    // ────────────────────────────────────────────────────────────────────────

    function readVaultDolomiteIsolationVaultAddress(IWithdrawHandlerVaultCore targetVaultCore)
        internal
        view
        returns (address)
    {
        return VaultState(targetVaultCore.basaltState()).dolomiteIsolationVault();
    }

    // ────────────────────────────────────────────────────────────────────────
    //  VAULT POSITION READERS (sourced directly from Dolomite)
    // ────────────────────────────────────────────────────────────────────────

    function readVaultGmCollateralE18(IWithdrawHandlerVaultCore targetVaultCore) internal view returns (uint256) {
        address dolomiteIsolationVaultAddress = readVaultDolomiteIsolationVaultAddress(targetVaultCore);
        if (dolomiteIsolationVaultAddress == address(0)) return 0;
        return DolomiteReader.getActualGmCollateralE18(
            IDolomiteMargin(BasaltAddresses.DOLOMITE_MARGIN),
            dolomiteIsolationVaultAddress
        );
    }

    function readVaultWbtcDebtE8(IWithdrawHandlerVaultCore targetVaultCore) internal view returns (uint256) {
        address dolomiteIsolationVaultAddress = readVaultDolomiteIsolationVaultAddress(targetVaultCore);
        if (dolomiteIsolationVaultAddress == address(0)) return 0;
        return DolomiteReader.getActualWbtcDebtE8(
            IDolomiteMargin(BasaltAddresses.DOLOMITE_MARGIN),
            dolomiteIsolationVaultAddress
        );
    }

    function readVaultWbtcSurplusE8(IWithdrawHandlerVaultCore targetVaultCore) internal view returns (uint256) {
        address dolomiteIsolationVaultAddress = readVaultDolomiteIsolationVaultAddress(targetVaultCore);
        if (dolomiteIsolationVaultAddress == address(0)) return 0;
        return DolomiteReader.getActualWbtcSurplusE8(
            IDolomiteMargin(BasaltAddresses.DOLOMITE_MARGIN),
            dolomiteIsolationVaultAddress
        );
    }

    function readVaultNavUsdE18(IWithdrawHandlerVaultCore targetVaultCore) internal view returns (uint256) {
        address dolomiteIsolationVaultAddress = readVaultDolomiteIsolationVaultAddress(targetVaultCore);
        IBasaltMath basaltMath = IBasaltMath(targetVaultCore.basaltMath());
        return DolomiteReader.getActualNavUsdE18(
            IDolomiteMargin(BasaltAddresses.DOLOMITE_MARGIN),
            dolomiteIsolationVaultAddress,
            basaltMath
        );
    }

    function readIsVaultFrozen(IWithdrawHandlerVaultCore targetVaultCore) internal view returns (bool) {
        address dolomiteIsolationVaultAddress = readVaultDolomiteIsolationVaultAddress(targetVaultCore);
        if (dolomiteIsolationVaultAddress == address(0)) return false;
        return IDolomiteIsolationVault(dolomiteIsolationVaultAddress).isVaultFrozen();
    }

    // ────────────────────────────────────────────────────────────────────────
    //  DOLOMITE ACCOUNT READERS
    // ────────────────────────────────────────────────────────────────────────

    function readWbtcAccount0RealWei(IWithdrawHandlerVaultCore targetVaultCore) internal view returns (uint256) {
        IDolomiteMargin.Par memory wbtcAccountPar = IDolomiteMargin(BasaltAddresses.DOLOMITE_MARGIN)
            .getAccountPar(
                IDolomiteMargin.AccountInfo({owner: address(targetVaultCore), number: 0}),
                BasaltConstants.DOLOMITE_MARKET_WBTC
            );
        if (!wbtcAccountPar.sign || wbtcAccountPar.value == 0) return 0;

        uint256 wbtcSupplyIndexE18 = uint256(
            IDolomiteMargin(BasaltAddresses.DOLOMITE_MARGIN)
                .getMarketCurrentIndex(BasaltConstants.DOLOMITE_MARKET_WBTC)
                .supply
        );
        IBasaltMath basaltMath = IBasaltMath(targetVaultCore.basaltMath());
        return basaltMath.calcScaledByIndexE18(uint256(wbtcAccountPar.value), wbtcSupplyIndexE18);
    }
}
