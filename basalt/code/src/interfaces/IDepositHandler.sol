// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IDepositHandlerVaultCore} from "./IDepositHandlerVaultCore.sol";

interface IDepositHandler {
    function deposit(IDepositHandlerVaultCore targetVaultCore, uint256 amountGmE18, uint256 userSlippageBps)
        external
        payable;

    function finalizeDeposit(IDepositHandlerVaultCore targetVaultCore) external;
}
