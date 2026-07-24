// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IBasaltMath} from "../../interfaces/IBasaltMath.sol";
import {IDepositHandlerVaultCore} from "../../interfaces/IDepositHandlerVaultCore.sol";
import {IDolomiteIsolationVault} from "../../interfaces/IDolomiteVault.sol";
import {IDolomiteMargin} from "../../interfaces/IDolomiteMargin.sol";
import {BasaltAddresses} from "../../libraries/BasaltAddresses.sol";
import {DolomiteReader} from "../../libraries/DolomiteReader.sol";
import {VaultState} from "../../core/VaultState.sol";
import {DepositContext} from "./DepositHandlerTypes.sol";

library DepositHandlerReaders {
    // ────────────────────────────────────────────────────────────────────────
    //  ADDRESS READERS
    // ────────────────────────────────────────────────────────────────────────

    function readDolomiteMarginContractAddress() internal pure returns (address) {
        return BasaltAddresses.DOLOMITE_MARGIN;
    }

    function readBasaltMathContractAddress(IDepositHandlerVaultCore targetVaultCore) internal view returns (address) {
        return targetVaultCore.basaltMath();
    }

    function readVaultDolomiteIsolationVaultAddress(IDepositHandlerVaultCore targetVaultCore)
        internal
        view
        returns (address)
    {
        return VaultState(targetVaultCore.basaltState()).dolomiteIsolationVault();
    }

    // ────────────────────────────────────────────────────────────────────────
    //  PRICE READERS
    // ────────────────────────────────────────────────────────────────────────

    function readDolomiteGmPriceE18(IDolomiteMargin dolomiteMargin) internal view returns (uint256) {
        return DolomiteReader.getGmPriceE18(dolomiteMargin);
    }

    function readDolomiteWbtcPriceE18(DepositContext memory depositContext) internal view returns (uint256) {
        return depositContext.basaltMath.toWbtcPriceE18FromE28(
            DolomiteReader.getWbtcPriceE28(depositContext.dolomiteMargin, depositContext.basaltMath)
        );
    }

    // ────────────────────────────────────────────────────────────────────────
    //  VAULT POSITION READERS (sourced directly from Dolomite)
    // ────────────────────────────────────────────────────────────────────────

    // GM collateral on isolation account 100 (E18); 0 if no iso vault.
    function readVaultGmCollateralE18(IDepositHandlerVaultCore targetVaultCore) internal view returns (uint256) {
        address dolomiteIsolationVaultAddress = readVaultDolomiteIsolationVaultAddress(targetVaultCore);
        if (dolomiteIsolationVaultAddress == address(0)) return 0;
        return DolomiteReader.getActualGmCollateralE18(
            IDolomiteMargin(BasaltAddresses.DOLOMITE_MARGIN),
            dolomiteIsolationVaultAddress
        );
    }

    // WBTC debt on isolation account 100 (E8).
    function readVaultWbtcDebtE8(IDepositHandlerVaultCore targetVaultCore) internal view returns (uint256) {
        address dolomiteIsolationVaultAddress = readVaultDolomiteIsolationVaultAddress(targetVaultCore);
        if (dolomiteIsolationVaultAddress == address(0)) return 0;
        return DolomiteReader.getActualWbtcDebtE8(
            IDolomiteMargin(BasaltAddresses.DOLOMITE_MARGIN),
            dolomiteIsolationVaultAddress
        );
    }

    // WBTC surplus on isolation account 100 (E8).
    function readVaultWbtcSurplusE8(IDepositHandlerVaultCore targetVaultCore) internal view returns (uint256) {
        address dolomiteIsolationVaultAddress = readVaultDolomiteIsolationVaultAddress(targetVaultCore);
        if (dolomiteIsolationVaultAddress == address(0)) return 0;
        return DolomiteReader.getActualWbtcSurplusE8(
            IDolomiteMargin(BasaltAddresses.DOLOMITE_MARGIN),
            dolomiteIsolationVaultAddress
        );
    }

    // NAV in USD E18; 0 if no iso vault.
    function readVaultNavUsdE18(IDepositHandlerVaultCore targetVaultCore) internal view returns (uint256) {
        address dolomiteIsolationVaultAddress = readVaultDolomiteIsolationVaultAddress(targetVaultCore);
        IBasaltMath basaltMath = IBasaltMath(targetVaultCore.basaltMath());
        return DolomiteReader.getActualNavUsdE18(
            IDolomiteMargin(BasaltAddresses.DOLOMITE_MARGIN),
            dolomiteIsolationVaultAddress,
            basaltMath
        );
    }

    function readIfIsolationVaultCreated(IDepositHandlerVaultCore targetVaultCore) internal view returns (bool) {
        return readVaultDolomiteIsolationVaultAddress(targetVaultCore) != address(0);
    }

    // True iff iso vault exists and its freezable-adapter reports pending async op.
    function readIsVaultFrozen(IDepositHandlerVaultCore targetVaultCore) internal view returns (bool) {
        address dolomiteIsolationVaultAddress = readVaultDolomiteIsolationVaultAddress(targetVaultCore);
        if (dolomiteIsolationVaultAddress == address(0)) return false;
        return IDolomiteIsolationVault(dolomiteIsolationVaultAddress).isVaultFrozen();
    }

    function readVaultSurplusGm(IDepositHandlerVaultCore targetVaultCore) internal view returns (uint256) {
        return IERC20(BasaltAddresses.GM_MARKET_TOKEN).balanceOf(address(targetVaultCore));
    }

    // ────────────────────────────────────────────────────────────────────────
    //  CONFIG READERS
    // ────────────────────────────────────────────────────────────────────────

    function readTargetLtvBps(IDepositHandlerVaultCore targetVaultCore) internal view returns (uint256) {
        return VaultState(targetVaultCore.basaltState()).targetLtvBps();
    }

    function readKeeperDeadline(IDepositHandlerVaultCore targetVaultCore) internal view returns (uint256) {
        return VaultState(targetVaultCore.basaltState()).keeperDeadline();
    }
}
