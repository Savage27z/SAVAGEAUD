// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IBasaltMath} from "./IBasaltMath.sol";
import {IFeeAccountingHandlerVaultCore} from "./IFeeAccountingHandlerVaultCore.sol";

interface IFeeAccountingHandler {
    function accrueManagerFee(IFeeAccountingHandlerVaultCore targetVaultCore, IBasaltMath basaltMath, address initiator)
        external;
}
