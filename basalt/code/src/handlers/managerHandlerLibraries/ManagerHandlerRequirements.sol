// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// ════════════════════════════════════════════════════════════════════════════
//  ManagerHandler — access control, idle/cooldown, slippage, rebalance gates
// ════════════════════════════════════════════════════════════════════════════

import {IChainlinkAggregator} from "../../interfaces/IChainlinkAggregator.sol";
import {IDolomiteMargin} from "../../interfaces/IDolomiteMargin.sol";
import {IManagerHandlerVaultCore} from "../../interfaces/IManagerHandlerVaultCore.sol";
import {IManagerHandlerVaultCoreNftFactory} from "../../interfaces/IManagerHandlerVaultCoreNftFactory.sol";
import {BasaltAddresses} from "../../libraries/BasaltAddresses.sol";
import {BasaltConstants} from "../../libraries/BasaltConstants.sol";
import {BasaltMath} from "../../pure/BasaltMath.sol";
import {DolomiteReader} from "../../libraries/DolomiteReader.sol";
import {OracleGuard} from "../../libraries/OracleGuard.sol";
import {VaultState} from "../../core/VaultState.sol";
import {
    AsyncOperationPending,
    CooldownNotPassed,
    InvalidSlippage,
    InvalidSlippageCap,
    InvalidTargetLtv,
    InvalidThreshold,
    InvalidUnwrapLongShare,
    NotIdle,
    NotVaultNftOwner,
    NotManagerOrNftOwner,
    PostSettlementLtvTooHigh,
    RebalanceWithinNftOwnerBand,
    SlippageExceedsCap,
    SlippageTooTight
} from "./ManagerHandlerTypes.sol";
import {ManagerHandlerReaders} from "./ManagerHandlerReaders.sol";

library ManagerHandlerRequirements {
    uint256 internal constant MAX_SAFE_LTV_BPS = BasaltConstants.MAX_SAFE_LTV_BPS;
    uint256 internal constant MAX_MANAGER_SLIPPAGE_BPS = BasaltConstants.MANAGER_MAX_SLIPPAGE_BPS;
    uint256 internal constant MIN_SLIPPAGE_BPS = BasaltConstants.MANAGER_MIN_SLIPPAGE_BPS;

    function requireVaultNftOwner(IManagerHandlerVaultCore targetVaultCore) internal view {
        address vaultOwner =
            IManagerHandlerVaultCoreNftFactory(targetVaultCore.FACTORY()).ownerOfVault(address(targetVaultCore));
        if (msg.sender != vaultOwner) revert NotVaultNftOwner();
    }

    function requireCallerIsProtocolManagerOrVaultNftOwner(IManagerHandlerVaultCore targetVaultCore) internal view {
        if (msg.sender == IManagerHandlerVaultCoreNftFactory(targetVaultCore.FACTORY()).protocolManager()) return;
        address vaultNftOwner =
            IManagerHandlerVaultCoreNftFactory(targetVaultCore.FACTORY()).ownerOfVault(address(targetVaultCore));
        if (msg.sender != vaultNftOwner) revert NotManagerOrNftOwner();
    }

    function requireAllIdle(IManagerHandlerVaultCore targetVaultCore) internal view {
        VaultState vaultState = ManagerHandlerReaders.readVaultState(targetVaultCore);
        if (vaultState.depositState() != VaultState.State.IDLE) revert NotIdle();
        if (vaultState.withdrawState() != VaultState.State.IDLE) revert NotIdle();
        if (vaultState.rebalanceState() != VaultState.State.IDLE) revert NotIdle();
    }

    function requireCooldownPassed(IManagerHandlerVaultCore targetVaultCore) internal view {
        uint256 cooldownEndBlock = ManagerHandlerReaders.readVaultState(targetVaultCore).globalActionCooldownEndBlock();
        if (block.number < cooldownEndBlock) {
            revert CooldownNotPassed(
                BasaltMath(targetVaultCore.basaltMath()).calcRemainingCooldownBlocks(cooldownEndBlock, block.number)
            );
        }
    }

    function requireSequencerUp() internal view {
        OracleGuard.requireSequencerUp(IChainlinkAggregator(BasaltAddresses.CL_SEQUENCER));
    }

    // NFT owner: LTV must be past rebalanceThreshold* on the trade side.
    function requireNftOwnerRebalanceDeviation(
        IManagerHandlerVaultCore targetVaultCore,
        uint256 currentLtvBps,
        uint256 targetLtvBps
    ) internal view {
        VaultState vaultState = ManagerHandlerReaders.readVaultState(targetVaultCore);
        uint256 rebalanceThresholdUpBps = vaultState.rebalanceThresholdUpBps();
        uint256 rebalanceThresholdDownBps = vaultState.rebalanceThresholdDownBps();
        BasaltMath basaltMath = BasaltMath(targetVaultCore.basaltMath());
        if (currentLtvBps > targetLtvBps) {
            if (basaltMath.calcLtvDeviationUpBps(currentLtvBps, targetLtvBps) < rebalanceThresholdUpBps) {
                revert RebalanceWithinNftOwnerBand(currentLtvBps, targetLtvBps);
            }
        } else {
            if (basaltMath.calcLtvDeviationDownBps(currentLtvBps, targetLtvBps) < rebalanceThresholdDownBps) {
                revert RebalanceWithinNftOwnerBand(currentLtvBps, targetLtvBps);
            }
        }
    }

    function requireValidSlippage(IManagerHandlerVaultCore targetVaultCore, uint256 slippageBps) internal view {
        if (slippageBps == 0 || slippageBps > MAX_MANAGER_SLIPPAGE_BPS) {
            revert InvalidSlippage(slippageBps);
        }
        uint256 vaultRebalanceSlippageCapBps =
            ManagerHandlerReaders.readVaultState(targetVaultCore).rebalanceSlippageCapBps();
        if (slippageBps > vaultRebalanceSlippageCapBps) {
            revert SlippageExceedsCap(slippageBps, vaultRebalanceSlippageCapBps);
        }
    }

    function requireRebalanceThresholdInBounds(uint256 bps) internal pure {
        if (bps < BasaltConstants.MIN_REBALANCE_THRESHOLD_BPS || bps > BasaltConstants.MAX_REBALANCE_THRESHOLD_BPS) {
            revert InvalidThreshold(
                bps, BasaltConstants.MIN_REBALANCE_THRESHOLD_BPS, BasaltConstants.MAX_REBALANCE_THRESHOLD_BPS
            );
        }
    }

    function requireUnwrapLongShareInBounds(uint256 bps) internal pure {
        if (bps < BasaltConstants.MIN_UNWRAP_LONG_SHARE_BPS || bps > BasaltConstants.MAX_UNWRAP_LONG_SHARE_BPS) {
            revert InvalidUnwrapLongShare(
                bps, BasaltConstants.MIN_UNWRAP_LONG_SHARE_BPS, BasaltConstants.MAX_UNWRAP_LONG_SHARE_BPS
            );
        }
    }

    function requireSlippageCapInBounds(uint256 bps) internal pure {
        if (
            bps < BasaltConstants.MIN_REBALANCE_SLIPPAGE_CAP_BPS
                || bps > BasaltConstants.MAX_REBALANCE_SLIPPAGE_CAP_BPS
        ) {
            revert InvalidSlippageCap(
                bps, BasaltConstants.MIN_REBALANCE_SLIPPAGE_CAP_BPS, BasaltConstants.MAX_REBALANCE_SLIPPAGE_CAP_BPS
            );
        }
    }

    function requireTargetLtvInBounds(uint256 nextTargetLtvBps) internal pure {
        if (
            nextTargetLtvBps < BasaltConstants.MIN_TARGET_LTV_BPS
                || nextTargetLtvBps > BasaltConstants.MAX_TARGET_LTV_BPS
        ) {
            revert InvalidTargetLtv(
                nextTargetLtvBps, BasaltConstants.MIN_TARGET_LTV_BPS, BasaltConstants.MAX_TARGET_LTV_BPS
            );
        }
    }

    function requireAsyncPreChecks(IManagerHandlerVaultCore targetVaultCore, uint256 managerSlippageBps)
        internal
        view
    {
        if (ManagerHandlerReaders.readIsVaultFrozen(targetVaultCore)) revert AsyncOperationPending();
        if (managerSlippageBps < MIN_SLIPPAGE_BPS) {
            revert SlippageTooTight(managerSlippageBps);
        }
    }

    function requirePostLtvSafe(BasaltMath basaltMath, uint256 projectedCollateralE18, uint256 projectedDebtE8)
        internal
        view
    {
        if (projectedDebtE8 == 0) return;
        IDolomiteMargin dol = IDolomiteMargin(BasaltAddresses.DOLOMITE_MARGIN);
        uint256 collE36 = basaltMath.calcCollValueE36(projectedCollateralE18, DolomiteReader.getGmPriceE18(dol));
        uint256 debtE36 = basaltMath.calcDebtValueE36(projectedDebtE8, DolomiteReader.getWbtcPriceE28(dol, basaltMath));
        uint256 adjCollE36 =
            basaltMath.applyCollateralPremiumE36(collE36, dol.getMarketMarginPremium(DolomiteReader.MARKET_GM));
        uint256 adjDebtE36 =
            basaltMath.applyDebtPremiumE36(debtE36, dol.getMarketMarginPremium(DolomiteReader.MARKET_WBTC));
        uint256 ltv = basaltMath.calcLtvBpsE36(adjDebtE36, adjCollE36);
        if (ltv > MAX_SAFE_LTV_BPS) {
            revert PostSettlementLtvTooHigh(ltv, MAX_SAFE_LTV_BPS);
        }
    }
}
