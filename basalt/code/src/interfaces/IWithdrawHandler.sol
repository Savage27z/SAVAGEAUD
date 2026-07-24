// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IWithdrawHandlerVaultCore} from "./IWithdrawHandlerVaultCore.sol";

interface IWithdrawHandler {
    function withdrawManagerFeeShares(IWithdrawHandlerVaultCore targetVaultCore, uint256 sharesToWithdraw, uint256 minWbtcOutE8)
        external
        payable;

    function finalizeWithdraw(IWithdrawHandlerVaultCore targetVaultCore) external;
}
