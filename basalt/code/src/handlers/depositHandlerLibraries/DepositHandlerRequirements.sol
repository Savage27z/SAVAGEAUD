// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IChainlinkAggregator} from "../../interfaces/IChainlinkAggregator.sol";
import {IDepositHandlerVaultCore} from "../../interfaces/IDepositHandlerVaultCore.sol";
import {IDepositHandlerVaultCoreNftFactory} from "../../interfaces/IDepositHandlerVaultCoreNftFactory.sol";
import {BasaltAddresses} from "../../libraries/BasaltAddresses.sol";
import {BasaltConstants} from "../../libraries/BasaltConstants.sol";
import {OracleGuard} from "../../libraries/OracleGuard.sol";
import {VaultState} from "../../core/VaultState.sol";
import {DepositHandlerReaders} from "./DepositHandlerReaders.sol";
import {
    DepositContext,
    NotVaultNftOwner,
    NotManagerOrNftOwner,
    NotIdle,
    CooldownNotPassed,
    DepositTooSmall,
    InvalidSlippage,
    DepositNotPending,
    VaultStillFrozen,
    InvalidWbtcAsDepositValue,
    PostDepositLtvTooHigh
} from "./DepositHandlerTypes.sol";

library DepositHandlerRequirements {
    // ────────────────────────────────────────────────────────────────────────
    //  ACCESS REQUIREMENTS
    // ────────────────────────────────────────────────────────────────────────

    function requireVaultNftOwner(IDepositHandlerVaultCore targetVaultCore) internal view {
        address vaultOwner =
            IDepositHandlerVaultCoreNftFactory(targetVaultCore.FACTORY()).ownerOfVault(address(targetVaultCore));
        if (msg.sender != vaultOwner) revert NotVaultNftOwner();
    }

    function requireCallerIsProtocolManagerOrVaultNftOwner(IDepositHandlerVaultCore targetVaultCore) internal view {
        if (msg.sender == IDepositHandlerVaultCoreNftFactory(targetVaultCore.FACTORY()).protocolManager()) return;
        address vaultNftOwner =
            IDepositHandlerVaultCoreNftFactory(targetVaultCore.FACTORY()).ownerOfVault(address(targetVaultCore));
        if (msg.sender != vaultNftOwner) revert NotManagerOrNftOwner();
    }

    // ────────────────────────────────────────────────────────────────────────
    //  VAULT STATE REQUIREMENTS
    // ────────────────────────────────────────────────────────────────────────

    function requireAllIdle(IDepositHandlerVaultCore targetVaultCore) internal view {
        VaultState vaultState = VaultState(targetVaultCore.basaltState());
        if (vaultState.depositState() != VaultState.State.IDLE) revert NotIdle();
        if (vaultState.withdrawState() != VaultState.State.IDLE) revert NotIdle();
        if (vaultState.rebalanceState() != VaultState.State.IDLE) revert NotIdle();
    }

    function requireDepositPending(VaultState vaultState) internal view {
        if (vaultState.depositState() != VaultState.State.PENDING) revert DepositNotPending();
    }

    function requireVaultNotFrozen(IDepositHandlerVaultCore targetVaultCore) internal view {
        if (DepositHandlerReaders.readIsVaultFrozen(targetVaultCore)) revert VaultStillFrozen();
    }

    // ────────────────────────────────────────────────────────────────────────
    //  COOLDOWN REQUIREMENTS
    // ────────────────────────────────────────────────────────────────────────

    function requireCooldownPassed(IDepositHandlerVaultCore targetVaultCore) internal view {
        uint256 cooldownEndBlock = VaultState(targetVaultCore.basaltState()).globalActionCooldownEndBlock();
        if (block.number < cooldownEndBlock) revert CooldownNotPassed(cooldownEndBlock - block.number);
    }

    // ────────────────────────────────────────────────────────────────────────
    //  USER INPUT REQUIREMENTS
    // ────────────────────────────────────────────────────────────────────────

    function requireValidDepositParams(uint256 amountGmE18, uint256 userSlippageBps) internal pure {
        if (amountGmE18 < 1e18) revert DepositTooSmall(amountGmE18, 1e18);
        requireValidSlippage(userSlippageBps);
    }

    function requireValidSlippage(uint256 userSlippageBps) internal pure {
        if (
            userSlippageBps < BasaltConstants.MIN_DEPOSIT_SLIPPAGE_BPS
                || userSlippageBps > BasaltConstants.MAX_DEPOSIT_SLIPPAGE_BPS
        ) {
            revert InvalidSlippage();
        }
    }

    function requireWbtcSurplusValueWithinDustLimit(uint256 valueUsdE18) internal pure {
        if (valueUsdE18 == 0 || valueUsdE18 > BasaltConstants.MAX_WBTC_SURPLUS_AS_DEPOSIT_USD_E18) {
            revert InvalidWbtcAsDepositValue(valueUsdE18, 0, BasaltConstants.MAX_WBTC_SURPLUS_AS_DEPOSIT_USD_E18);
        }
    }

    // ────────────────────────────────────────────────────────────────────────
    //  ORACLE REQUIREMENTS
    // ────────────────────────────────────────────────────────────────────────

    function requireSequencerUp() internal view {
        OracleGuard.requireSequencerUp(IChainlinkAggregator(BasaltAddresses.CL_SEQUENCER));
    }

    // ────────────────────────────────────────────────────────────────────────
    //  SOLVENCY REQUIREMENTS
    // ────────────────────────────────────────────────────────────────────────

    function requireLtvBelowCap(DepositContext memory depositContext) internal pure {
        uint256 ltvBps = depositContext.basaltMath
            .calcPostDepositLtvBps(
                depositContext.gmCollateral,
                depositContext.amountGmE18,
                depositContext.gmReceivedMinE18,
                depositContext.gmPriceE18,
                depositContext.wbtcDebt,
                depositContext.borrowWbtcE8,
                depositContext.wbtcPriceE18
            );
        if (ltvBps > BasaltConstants.MAX_POST_DEPOSIT_LTV_BPS) {
            revert PostDepositLtvTooHigh(ltvBps);
        }
    }
}
