// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// ════════════════════════════════════════════════════════════════════════════
//  ManagerHandler — `VaultState` writes, Dolomite async calls
// ════════════════════════════════════════════════════════════════════════════

import {IBasaltMath} from "../../interfaces/IBasaltMath.sol";
import {IDolomiteIsolationVault, TraderParam, Account, UserConfig} from "../../interfaces/IDolomiteVault.sol";
import {IGmxV2Registry} from "../../interfaces/IDolomiteAsyncTraders.sol";
import {IManagerHandlerVaultCore} from "../../interfaces/IManagerHandlerVaultCore.sol";
import {BasaltAddresses} from "../../libraries/BasaltAddresses.sol";
import {BasaltConstants} from "../../libraries/BasaltConstants.sol";
import {VaultState} from "../../core/VaultState.sol";
import {REBALANCE_DIR_DOWN, REBALANCE_DIR_UP, REBALANCE_KIND_LTV} from "./ManagerHandlerTypes.sol";
import {ManagerHandlerReaders} from "./ManagerHandlerReaders.sol";

library ManagerHandlerExecutors {
    function callVaultCore(IManagerHandlerVaultCore targetVaultCore, address target, bytes memory data, uint256 value)
        internal
    {
        targetVaultCore.universalCall{value: value}(msg.sender, target, data, value, false);
    }

    function startGlobalActionCooldown(IManagerHandlerVaultCore targetVaultCore) internal {
        uint256 cooldownEndBlock = IBasaltMath(targetVaultCore.basaltMath())
            .calcCooldownEndBlock(block.number, BasaltConstants.GLOBAL_ACTION_COOLDOWN_BLOCKS);
        callVaultCore(
            targetVaultCore,
            targetVaultCore.basaltState(),
            abi.encodeCall(VaultState.startGlobalActionCooldown, (cooldownEndBlock)),
            0
        );
    }

    function clearPendingRebalanceAccounting(IManagerHandlerVaultCore targetVaultCore) internal {
        callVaultCore(
            targetVaultCore, targetVaultCore.basaltState(), abi.encodeCall(VaultState.clearPendingRebalance, ()), 0
        );
        startGlobalActionCooldown(targetVaultCore);
    }

    function bumpLastManagerAction(IManagerHandlerVaultCore targetVaultCore) internal {
        callVaultCore(
            targetVaultCore,
            targetVaultCore.basaltState(),
            abi.encodeCall(VaultState.bumpLastManagerAction, ()),
            0
        );
    }

    // ── Protocol manager (`VaultCoreNftFactory.protocolManager`) — VaultState config ──

    function configureSetTargetLtvBps(IManagerHandlerVaultCore targetVaultCore, uint256 nextTargetLtvBps) internal {
        callVaultCore(
            targetVaultCore,
            targetVaultCore.basaltState(),
            abi.encodeCall(VaultState.setTargetLtvBps, (nextTargetLtvBps)),
            0
        );
        startGlobalActionCooldown(targetVaultCore);
    }

    function configureSetKeeperDeadline(IManagerHandlerVaultCore targetVaultCore, uint256 nextKeeperDeadline)
        internal
    {
        callVaultCore(
            targetVaultCore,
            targetVaultCore.basaltState(),
            abi.encodeCall(VaultState.setKeeperDeadline, (nextKeeperDeadline)),
            0
        );
        startGlobalActionCooldown(targetVaultCore);
    }

    function configureSetRebalanceSlippageCapBps(IManagerHandlerVaultCore targetVaultCore, uint256 bps) internal {
        callVaultCore(
            targetVaultCore,
            targetVaultCore.basaltState(),
            abi.encodeCall(VaultState.setRebalanceSlippageCapBps, (bps)),
            0
        );
        startGlobalActionCooldown(targetVaultCore);
    }

    function configureSetUnwrapLongShareBps(IManagerHandlerVaultCore targetVaultCore, uint256 bps) internal {
        callVaultCore(
            targetVaultCore,
            targetVaultCore.basaltState(),
            abi.encodeCall(VaultState.setUnwrapLongShareBps, (bps)),
            0
        );
        startGlobalActionCooldown(targetVaultCore);
    }

    function configureSetRebalanceThresholdUpBps(IManagerHandlerVaultCore targetVaultCore, uint256 bps) internal {
        callVaultCore(
            targetVaultCore,
            targetVaultCore.basaltState(),
            abi.encodeCall(VaultState.setRebalanceThresholdUpBps, (bps)),
            0
        );
        startGlobalActionCooldown(targetVaultCore);
    }

    function configureSetRebalanceThresholdDownBps(IManagerHandlerVaultCore targetVaultCore, uint256 bps) internal {
        callVaultCore(
            targetVaultCore,
            targetVaultCore.basaltState(),
            abi.encodeCall(VaultState.setRebalanceThresholdDownBps, (bps)),
            0
        );
        startGlobalActionCooldown(targetVaultCore);
    }

    function setPendingRebalanceLtvUp(
        IManagerHandlerVaultCore targetVaultCore,
        address initiator,
        uint256 ltvSnapBps,
        uint256 keeperDeadline
    ) internal {
        callVaultCore(
            targetVaultCore,
            targetVaultCore.basaltState(),
            abi.encodeCall(
                VaultState.setPendingRebalance,
                (
                    uint8(REBALANCE_KIND_LTV),
                    uint8(REBALANCE_DIR_UP),
                    initiator,
                    ltvSnapBps,
                    block.timestamp + keeperDeadline
                )
            ),
            0
        );
    }

    function setPendingRebalanceLtvDown(
        IManagerHandlerVaultCore targetVaultCore,
        address initiator,
        uint256 ltvSnapBps,
        uint256 keeperDeadline
    ) internal {
        callVaultCore(
            targetVaultCore,
            targetVaultCore.basaltState(),
            abi.encodeCall(
                VaultState.setPendingRebalance,
                (
                    uint8(REBALANCE_KIND_LTV),
                    uint8(REBALANCE_DIR_DOWN),
                    initiator,
                    ltvSnapBps,
                    block.timestamp + keeperDeadline
                )
            ),
            0
        );
    }

    function dolomiteAsyncWrapForRebalance(
        IManagerHandlerVaultCore targetVaultCore,
        address dolomiteIsolationVault,
        uint256 borrowWbtcE8,
        uint256 minGmOutE18,
        uint256 keeperFee
    ) internal {
        address wrapper = IGmxV2Registry(BasaltAddresses.GMX_V2_REGISTRY).getWrapperByToken(BasaltAddresses.VAULT_FACTORY);
        TraderParam[] memory traders = new TraderParam[](1);
        traders[0] = TraderParam({
            traderType: 3,
            makerAccountIndex: 0,
            trader: wrapper,
            tradeData: abi.encode(BasaltConstants.DOLOMITE_ISOLATION_ACCOUNT, abi.encode(keeperFee))
        });
        uint256[] memory marketIds = new uint256[](2);
        marketIds[0] = BasaltConstants.DOLOMITE_MARKET_WBTC;
        marketIds[1] = BasaltConstants.DOLOMITE_MARKET_GM;
        uint256 deadline = IBasaltMath(targetVaultCore.basaltMath())
            .calcKeeperDeadlineTimestamp(block.timestamp, ManagerHandlerReaders.readKeeperDeadline(targetVaultCore));
        callVaultCore(
            targetVaultCore,
            dolomiteIsolationVault,
            abi.encodeCall(
                IDolomiteIsolationVault.swapExactInputForOutput,
                (
                    BasaltConstants.DOLOMITE_ISOLATION_ACCOUNT,
                    marketIds,
                    borrowWbtcE8,
                    minGmOutE18,
                    traders,
                    new Account[](0),
                    UserConfig({deadline: deadline, balanceCheckFlag: 3, eventType: 1})
                )
            ),
            keeperFee
        );
    }

    function dolomiteAsyncUnwrapForRebalance(
        IManagerHandlerVaultCore targetVaultCore,
        address dolomiteIsolationVault,
        uint256 gmAmountE18,
        uint256 minWbtcOutE8,
        uint256 keeperFee
    ) internal {
        bytes memory extraData = abi.encode(uint256(0), uint256(1));
        callVaultCore(
            targetVaultCore,
            dolomiteIsolationVault,
            abi.encodeCall(
                IDolomiteIsolationVault.initiateUnwrapping,
                (
                    BasaltConstants.DOLOMITE_ISOLATION_ACCOUNT,
                    gmAmountE18,
                    BasaltAddresses.WBTC,
                    minWbtcOutE8 + 1,
                    extraData
                )
            ),
            keeperFee
        );
    }
}
