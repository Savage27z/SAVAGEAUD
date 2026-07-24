// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IBasaltMath} from "../../interfaces/IBasaltMath.sol";
import {BasaltConstants} from "../../libraries/BasaltConstants.sol";
import {AsyncRecoveryPendingOperation} from "./AsyncRecoveryHandlerTypes.sol";

library AsyncRecoveryHandlerCalculations {
    // ────────────────────────────────────────────────────────────────────────
    //  RECOVERY TIME
    // ────────────────────────────────────────────────────────────────────────

    function calcUnstuckNotBefore(
        IBasaltMath basaltMath,
        AsyncRecoveryPendingOperation memory pendingOperation
    ) internal view returns (uint256) {
        return basaltMath.calcUnstuckNotBefore(pendingOperation.deadline, BasaltConstants.UNSTUCK_GRACE_AFTER_DEADLINE);
    }
}
