// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IManagerHandlerVaultCore} from "./IManagerHandlerVaultCore.sol";

interface IManagerHandler {
    function setTargetLtv(IManagerHandlerVaultCore targetVaultCore, uint256 nextTargetLtvBps) external;

    function setKeeperDeadline(IManagerHandlerVaultCore targetVaultCore, uint256 nextKeeperDeadline) external;

    function setRebalanceSlippageCapBps(IManagerHandlerVaultCore targetVaultCore, uint256 bps) external;

    function setUnwrapLongShareBps(IManagerHandlerVaultCore targetVaultCore, uint256 bps) external;

    function setRebalanceThresholdUpBps(IManagerHandlerVaultCore targetVaultCore, uint256 bps) external;

    function setRebalanceThresholdDownBps(IManagerHandlerVaultCore targetVaultCore, uint256 bps) external;

    function rebalance(IManagerHandlerVaultCore targetVaultCore, uint256 managerSlippageBps) external payable;

    function finalizeRebalance(IManagerHandlerVaultCore targetVaultCore) external;

    function pingHeartbeat(IManagerHandlerVaultCore targetVaultCore) external;
}
