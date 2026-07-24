// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IDolomiteIsolationVault} from "../../interfaces/IDolomiteVault.sol";
import {IDolomiteMargin} from "../../interfaces/IDolomiteMargin.sol";
import {IFeeAccountingHandlerVaultCore} from "../../interfaces/IFeeAccountingHandlerVaultCore.sol";
import {IWithdrawHandlerVaultCore} from "../../interfaces/IWithdrawHandlerVaultCore.sol";
import {BasaltAddresses} from "../../libraries/BasaltAddresses.sol";
import {BasaltConstants} from "../../libraries/BasaltConstants.sol";
import {DolomiteReader} from "../../libraries/DolomiteReader.sol";
import {IBasaltMath} from "../../interfaces/IBasaltMath.sol";
import {VaultState} from "../../core/VaultState.sol";
import {FeeAccountingHandler} from "../FeeAccountingHandler.sol";
import {WithdrawTransferFailed} from "./WithdrawHandlerTypes.sol";
import {WithdrawHandlerReaders} from "./WithdrawHandlerReaders.sol";

library WithdrawHandlerExecutors {
    // ────────────────────────────────────────────────────────────────────────
    //  WITHDRAW STATE ACCOUNTING
    // ────────────────────────────────────────────────────────────────────────

    function setPendingWithdraw(
        IWithdrawHandlerVaultCore targetVaultCore,
        address withdrawer,
        uint256 sharesToWithdrawE18,
        uint256 gmToSellE18,
        uint256 minWbtcOutE8,
        uint256 gmCollateralSnapshotE18,
        uint256 wbtcDebtSnapshotE8,
        uint256 rawRatioInitialE18,
        uint256 borrowIndexE18,
        bool isManagerFee
    ) internal {
        uint256 deadline = IBasaltMath(targetVaultCore.basaltMath()).calcKeeperDeadlineTimestamp(
            block.timestamp, VaultState(targetVaultCore.basaltState()).keeperDeadline()
        );
        coreCall(
            targetVaultCore,
            targetVaultCore.basaltState(),
            0,
            abi.encodeCall(
                VaultState.setPendingWithdrawAccounting,
                (
                    withdrawer,
                    sharesToWithdrawE18,
                    gmToSellE18,
                    gmCollateralSnapshotE18,
                    wbtcDebtSnapshotE8,
                    rawRatioInitialE18,
                    minWbtcOutE8,
                    borrowIndexE18,
                    deadline,
                    isManagerFee
                )
            )
        );
    }

    function clearPendingWithdraw(IWithdrawHandlerVaultCore targetVaultCore) internal {
        coreCall(
            targetVaultCore,
            targetVaultCore.basaltState(),
            0,
            abi.encodeCall(VaultState.clearPendingWithdrawAccounting, ())
        );
    }

    // ────────────────────────────────────────────────────────────────────────
    //  FEE ACCOUNTING
    // ────────────────────────────────────────────────────────────────────────

    function accrueManagerFeeBeforeWithdraw(IWithdrawHandlerVaultCore targetVaultCore) internal {
        FeeAccountingHandler(targetVaultCore.feeAccountingHandler()).accrueManagerFee(
            IFeeAccountingHandlerVaultCore(address(targetVaultCore)),
            IBasaltMath(targetVaultCore.basaltMath()),
            msg.sender
        );
    }

    // owner-leg payout: adds paid-out USD to totalWithdrawnUsdE18 (feeds profit calc)
    function recordWithdrawnUsd(
        IWithdrawHandlerVaultCore targetVaultCore,
        uint256 gmAmountE18,
        uint256 wbtcAmountE8
    ) internal {
        if (gmAmountE18 == 0 && wbtcAmountE8 == 0) return;
        uint256 withdrawnUsdE18 = _priceWithdrawnUsdE18(targetVaultCore, gmAmountE18, wbtcAmountE8);
        _addWithdrawnUsd(targetVaultCore, withdrawnUsdE18);
    }

    // manager-fee-leg payout: same accumulator + saturating debit of managerAccruedFeeUsdE18
    function recordManagerFeeWithdrawnUsd(
        IWithdrawHandlerVaultCore targetVaultCore,
        uint256 gmAmountE18,
        uint256 wbtcAmountE8
    ) internal {
        if (gmAmountE18 == 0 && wbtcAmountE8 == 0) return;
        uint256 withdrawnUsdE18 = _priceWithdrawnUsdE18(targetVaultCore, gmAmountE18, wbtcAmountE8);
        _addWithdrawnUsd(targetVaultCore, withdrawnUsdE18);
        coreCall(
            targetVaultCore,
            targetVaultCore.basaltState(),
            0,
            abi.encodeCall(VaultState.subAccruedManagerFeeUsdE18, (withdrawnUsdE18))
        );
    }

    function _priceWithdrawnUsdE18(
        IWithdrawHandlerVaultCore targetVaultCore,
        uint256 gmAmountE18,
        uint256 wbtcAmountE8
    ) private view returns (uint256) {
        IBasaltMath basaltMath = IBasaltMath(targetVaultCore.basaltMath());
        IDolomiteMargin dolomiteMargin = IDolomiteMargin(BasaltAddresses.DOLOMITE_MARGIN);
        uint256 gmPriceUsdE18 = DolomiteReader.getGmPriceE18(dolomiteMargin);
        uint256 wbtcPriceUsdE18 =
            basaltMath.toWbtcPriceE18FromE28(DolomiteReader.getWbtcPriceE28(dolomiteMargin, basaltMath));
        return basaltMath.calcWithdrawnUsdE18(gmAmountE18, gmPriceUsdE18, wbtcAmountE8, wbtcPriceUsdE18);
    }

    function _addWithdrawnUsd(IWithdrawHandlerVaultCore targetVaultCore, uint256 withdrawnUsdE18) private {
        coreCall(
            targetVaultCore,
            targetVaultCore.basaltState(),
            0,
            abi.encodeCall(VaultState.addWithdrawnUsdE18, (withdrawnUsdE18))
        );
    }

    // ────────────────────────────────────────────────────────────────────────
    //  GM WITHDRAW EXECUTION
    // ────────────────────────────────────────────────────────────────────────

    function withdrawGmToUser(IWithdrawHandlerVaultCore targetVaultCore, address user, uint256 amountGmE18) internal {
        address dolomiteIsolationVaultAddress = WithdrawHandlerReaders.readVaultDolomiteIsolationVaultAddress(targetVaultCore);
        coreCall(
            targetVaultCore,
            dolomiteIsolationVaultAddress,
            0,
            abi.encodeCall(
                IDolomiteIsolationVault.transferFromPositionWithUnderlyingToken,
                (BasaltConstants.DOLOMITE_ISOLATION_ACCOUNT, 0, amountGmE18)
            )
        );
        coreCall(
            targetVaultCore,
            dolomiteIsolationVaultAddress,
            0,
            abi.encodeCall(IDolomiteIsolationVault.withdrawFromVaultForDolomiteMargin, (0, amountGmE18))
        );
        bytes memory transferReturnData = coreCall(
            targetVaultCore,
            BasaltAddresses.GM_MARKET_TOKEN,
            0,
            abi.encodeWithSelector(IERC20.transfer.selector, user, amountGmE18)
        );
        if (transferReturnData.length != 0 && !abi.decode(transferReturnData, (bool))) {
            revert WithdrawTransferFailed(BasaltAddresses.GM_MARKET_TOKEN, user, amountGmE18);
        }
    }

    // ────────────────────────────────────────────────────────────────────────
    //  WBTC WITHDRAW EXECUTION
    // ────────────────────────────────────────────────────────────────────────

    function withdrawWbtcToUser(IWithdrawHandlerVaultCore targetVaultCore, address user, uint256 amountE8)
        internal
        returns (uint256 actualE8)
    {
        if (amountE8 == 0) return 0;

        address dolomiteIsolationVaultAddress = WithdrawHandlerReaders.readVaultDolomiteIsolationVaultAddress(targetVaultCore);
        coreCall(
            targetVaultCore,
            dolomiteIsolationVaultAddress,
            0,
            abi.encodeCall(
                IDolomiteIsolationVault.transferFromPositionWithOtherToken,
                (
                    BasaltConstants.DOLOMITE_ISOLATION_ACCOUNT,
                    0,
                    BasaltConstants.DOLOMITE_MARKET_WBTC,
                    amountE8,
                    uint8(3)
                )
            )
        );

        actualE8 = WithdrawHandlerReaders.readWbtcAccount0RealWei(targetVaultCore);

        IDolomiteMargin.AccountInfo[] memory accounts = new IDolomiteMargin.AccountInfo[](1);
        accounts[0] = IDolomiteMargin.AccountInfo({owner: address(targetVaultCore), number: 0});

        IDolomiteMargin.ActionArgs[] memory actions = new IDolomiteMargin.ActionArgs[](1);
        actions[0] = IDolomiteMargin.ActionArgs({
            actionType: 1,
            accountId: 0,
            amount: IDolomiteMargin.AssetAmount({sign: false, denomination: 0, ref: 0, value: actualE8}),
            primaryMarketId: BasaltConstants.DOLOMITE_MARKET_WBTC,
            secondaryMarketId: 0,
            otherAddress: address(targetVaultCore),
            otherAccountId: 0,
            data: new bytes(0)
        });

        coreCall(
            targetVaultCore,
            BasaltAddresses.DOLOMITE_MARGIN,
            0,
            abi.encodeCall(IDolomiteMargin.operate, (accounts, actions))
        );

        bytes memory transferReturnData = coreCall(
            targetVaultCore, BasaltAddresses.WBTC, 0, abi.encodeWithSelector(IERC20.transfer.selector, user, actualE8)
        );
        if (transferReturnData.length != 0 && !abi.decode(transferReturnData, (bool))) {
            revert WithdrawTransferFailed(BasaltAddresses.WBTC, user, actualE8);
        }
    }

    // ────────────────────────────────────────────────────────────────────────
    //  ASYNC UNWRAP EXECUTION
    // ────────────────────────────────────────────────────────────────────────

    function asyncUnwrap(
        IWithdrawHandlerVaultCore targetVaultCore,
        uint256 gmAmountE18,
        uint256 minWbtcOutE8,
        uint256 keeperFee
    ) internal {
        bytes memory extraData = abi.encode(uint256(0), uint256(1));
        coreCall(
            targetVaultCore,
            WithdrawHandlerReaders.readVaultDolomiteIsolationVaultAddress(targetVaultCore),
            keeperFee,
            abi.encodeCall(
                IDolomiteIsolationVault.initiateUnwrapping,
                (
                    BasaltConstants.DOLOMITE_ISOLATION_ACCOUNT,
                    gmAmountE18,
                    BasaltAddresses.WBTC,
                    minWbtcOutE8 + 1,
                    extraData
                )
            )
        );
    }

    // ────────────────────────────────────────────────────────────────────────
    //  VAULT CORE CALL PRIMITIVES
    // ────────────────────────────────────────────────────────────────────────

    function coreCall(IWithdrawHandlerVaultCore targetVaultCore, address target, uint256 value, bytes memory data)
        internal
        returns (bytes memory)
    {
        return targetVaultCore.universalCall{value: value}(msg.sender, target, data, value, false);
    }
}
