// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IBasaltMath} from "../interfaces/IBasaltMath.sol";
import {IChainlinkAggregator} from "../interfaces/IChainlinkAggregator.sol";
import {IDolomiteMargin} from "../interfaces/IDolomiteMargin.sol";
import {IFeeAccountingHandler} from "../interfaces/IFeeAccountingHandler.sol";
import {VaultState} from "../core/VaultState.sol";
import {IFeeAccountingHandlerVaultCore} from "../interfaces/IFeeAccountingHandlerVaultCore.sol";
import {IVaultCoreNftFactory} from "../interfaces/IVaultCoreNftFactory.sol";
import {BasaltAddresses} from "../libraries/BasaltAddresses.sol";
import {DolomiteReader} from "../libraries/DolomiteReader.sol";
import {OracleGuard} from "../libraries/OracleGuard.sol";

contract FeeAccountingHandler is IFeeAccountingHandler {
    error InvalidInitiator();
    error NotAuthorizedCaller();

    event ManagerFeeAccrued(
        address indexed relayer,
        address indexed initiator,
        address indexed targetVaultCore,
        uint256 currentNavUsdE18,
        uint256 currentProfitUsdE18,
        uint256 profitDeltaUsdE18,
        uint256 performanceFeeUsdE18,
        uint256 highWaterMarkProfitUsdE18,
        uint256 managerAccruedFeeUsdE18
    );

    function accrueManagerFee(IFeeAccountingHandlerVaultCore targetVaultCore, IBasaltMath basaltMath, address initiator)
        external
    {
        _requireInitiatorAndCaller(targetVaultCore, initiator);
        OracleGuard.requireSequencerUp(IChainlinkAggregator(BasaltAddresses.CL_SEQUENCER));

        VaultState vaultState = VaultState(targetVaultCore.basaltState());
        (
            uint256 currentNavUsdE18,
            uint256 currentProfitUsdE18,
            uint256 profitDeltaUsdE18,
            uint256 performanceFeeUsdE18,
            uint256 nextHighWaterMarkProfitUsdE18,
            uint256 nextManagerAccruedFeeUsdE18
        ) = calculateManagerFee(targetVaultCore, basaltMath);

        if (performanceFeeUsdE18 > 0) {
            _setFeeAccounting(
                targetVaultCore, vaultState, initiator, nextHighWaterMarkProfitUsdE18, nextManagerAccruedFeeUsdE18
            );
        }

        emit ManagerFeeAccrued(
            msg.sender,
            initiator,
            address(targetVaultCore),
            currentNavUsdE18,
            currentProfitUsdE18,
            profitDeltaUsdE18,
            performanceFeeUsdE18,
            nextHighWaterMarkProfitUsdE18,
            nextManagerAccruedFeeUsdE18
        );
    }

    function calculateManagerFee(IFeeAccountingHandlerVaultCore targetVaultCore, IBasaltMath basaltMath)
        public
        view
        returns (
            uint256 currentNavUsdE18,
            uint256 currentProfitUsdE18,
            uint256 profitDeltaUsdE18,
            uint256 performanceFeeUsdE18,
            uint256 nextHighWaterMarkProfitUsdE18,
            uint256 nextManagerAccruedFeeUsdE18
        )
    {
        VaultState vaultState = VaultState(targetVaultCore.basaltState());
        currentNavUsdE18 = DolomiteReader.getActualNavUsdE18(
            IDolomiteMargin(BasaltAddresses.DOLOMITE_MARGIN), vaultState.dolomiteIsolationVault(), basaltMath
        );
        currentProfitUsdE18 = basaltMath.calcProfitUsdE18(
            currentNavUsdE18, vaultState.totalDepositedUsdE18(), vaultState.totalWithdrawnUsdE18()
        );
        uint256 prevHwmProfitUsdE18 = vaultState.highWaterMarkProfitUsdE18();
        (profitDeltaUsdE18, performanceFeeUsdE18) = basaltMath.calcPerformanceFeeByHwmProfit(
            currentProfitUsdE18, prevHwmProfitUsdE18, vaultState.managementFeeBps()
        );
        nextHighWaterMarkProfitUsdE18 = basaltMath.calcNextHighWaterMarkProfit(currentProfitUsdE18, prevHwmProfitUsdE18);
        nextManagerAccruedFeeUsdE18 =
            basaltMath.calcNextAccruedManagerFee(vaultState.managerAccruedFeeUsdE18(), performanceFeeUsdE18);
    }

    function _requireInitiatorAndCaller(IFeeAccountingHandlerVaultCore targetVaultCore, address initiator)
        internal
        view
    {
        address factory = targetVaultCore.FACTORY();
        address nftOwner = IVaultCoreNftFactory(factory).ownerOfVault(address(targetVaultCore));
        address protocolManager = IVaultCoreNftFactory(factory).protocolManager();
        if (initiator != nftOwner && initiator != protocolManager) revert InvalidInitiator();

        if (msg.sender == initiator) return;
        if (_isVaultHandlerSlot(targetVaultCore, msg.sender)) return;

        revert NotAuthorizedCaller();
    }

    function _isVaultHandlerSlot(IFeeAccountingHandlerVaultCore vaultCore, address caller)
        internal
        view
        returns (bool)
    {
        return caller == vaultCore.depositHandler() || caller == vaultCore.withdrawHandler()
            || caller == vaultCore.managerHandler() || caller == vaultCore.asyncRecoveryHandler()
            || caller == vaultCore.feeAccountingHandler() || caller == vaultCore.extensionHandler1()
            || caller == vaultCore.extensionHandler2() || caller == vaultCore.extensionHandler3();
    }

    function _setFeeAccounting(
        IFeeAccountingHandlerVaultCore targetVaultCore,
        VaultState vaultState,
        address initiator,
        uint256 nextHighWaterMarkProfitUsdE18,
        uint256 nextManagerAccruedFeeUsdE18
    ) internal {
        targetVaultCore.universalCall(
            initiator,
            address(vaultState),
            abi.encodeCall(VaultState.setFeeAccounting, (nextHighWaterMarkProfitUsdE18, nextManagerAccruedFeeUsdE18)),
            0,
            false
        );
    }
}
