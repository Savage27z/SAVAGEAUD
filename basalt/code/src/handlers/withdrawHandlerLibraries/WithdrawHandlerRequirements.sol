// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BasaltAddresses} from "../../libraries/BasaltAddresses.sol";
import {BasaltConstants} from "../../libraries/BasaltConstants.sol";
import {IChainlinkAggregator} from "../../interfaces/IChainlinkAggregator.sol";
import {OracleGuard} from "../../libraries/OracleGuard.sol";
import {VaultState} from "../../core/VaultState.sol";
import {BasaltMath} from "../../pure/BasaltMath.sol";
import {IWithdrawHandlerVaultCore} from "../../interfaces/IWithdrawHandlerVaultCore.sol";
import {IWithdrawHandlerVaultCoreNftFactory} from "../../interfaces/IWithdrawHandlerVaultCoreNftFactory.sol";
import {WithdrawHandlerCalculations} from "./WithdrawHandlerCalculations.sol";
import {WithdrawHandlerReaders} from "./WithdrawHandlerReaders.sol";
import {
    NotIdle,
    CooldownNotPassed,
    InvalidPositionShareToWithdraw,
    WithdrawNotPending,
    VaultStillFrozen,
    UnexpectedValue,
    NotVaultNftOwner,
    NotManagerOrNftOwner,
    NotProtocolManager,
    WithdrawExceedsOwnerEligibleShares,
    WithdrawExceedsManagerFeeShares
} from "./WithdrawHandlerTypes.sol";

library WithdrawHandlerRequirements {
    // ────────────────────────────────────────────────────────────────────────
    //  VAULT STATE REQUIREMENTS
    // ────────────────────────────────────────────────────────────────────────

    function requireAllIdle(IWithdrawHandlerVaultCore targetVaultCore) internal view {
        VaultState vaultState = VaultState(targetVaultCore.basaltState());
        if (vaultState.depositState() != VaultState.State.IDLE) revert NotIdle();
        if (vaultState.withdrawState() != VaultState.State.IDLE) revert NotIdle();
        if (vaultState.rebalanceState() != VaultState.State.IDLE) revert NotIdle();
    }

    function requireWithdrawPending(VaultState vaultState) internal view {
        if (vaultState.withdrawState() == VaultState.State.IDLE) revert WithdrawNotPending();
    }

    function requireVaultNotFrozen(IWithdrawHandlerVaultCore targetVaultCore) internal view {
        if (WithdrawHandlerReaders.readIsVaultFrozen(targetVaultCore)) revert VaultStillFrozen();
    }

    function requireSequencerUp() internal view {
        OracleGuard.requireSequencerUp(IChainlinkAggregator(BasaltAddresses.CL_SEQUENCER));
    }

    // ────────────────────────────────────────────────────────────────────────
    //  COOLDOWN REQUIREMENTS
    // ────────────────────────────────────────────────────────────────────────

    function requireCooldownPassed(IWithdrawHandlerVaultCore targetVaultCore) internal view {
        uint256 cooldownEndBlock = VaultState(targetVaultCore.basaltState()).globalActionCooldownEndBlock();
        if (block.number < cooldownEndBlock) revert CooldownNotPassed(cooldownEndBlock - block.number);
    }

    // ────────────────────────────────────────────────────────────────────────
    //  USER INPUT REQUIREMENTS
    // ────────────────────────────────────────────────────────────────────────

    function requireValidPositionShareToWithdraw(uint256 positionShareToWithdrawE18) internal pure {
        if (positionShareToWithdrawE18 == 0 || positionShareToWithdrawE18 > BasaltConstants.SHARE_UNIT) {
            revert InvalidPositionShareToWithdraw(positionShareToWithdrawE18, BasaltConstants.SHARE_UNIT);
        }
    }

    // ────────────────────────────────────────────────────────────────────────
    //  MANAGER FEE WITHDRAW LIMIT REQUIREMENTS
    // ────────────────────────────────────────────────────────────────────────

    function requireSharesWithinOwnerEligibleWithdraw(
        IWithdrawHandlerVaultCore targetVaultCore,
        uint256 sharesToWithdrawE18
    ) internal view {
        uint256 navUsdE18 = WithdrawHandlerReaders.readVaultNavUsdE18(targetVaultCore);
        uint256 managerAccruedFeeUsdE18 = VaultState(targetVaultCore.basaltState()).managerAccruedFeeUsdE18();
        uint256 eligibleSharesE18 = WithdrawHandlerCalculations.calcOwnerEligibleWithdrawShares(
            BasaltMath(targetVaultCore.basaltMath()), navUsdE18, managerAccruedFeeUsdE18, BasaltConstants.SHARE_UNIT
        );
        if (sharesToWithdrawE18 > eligibleSharesE18) {
            revert WithdrawExceedsOwnerEligibleShares(
                sharesToWithdrawE18, eligibleSharesE18, navUsdE18, managerAccruedFeeUsdE18
            );
        }
    }

    function requireSharesWithinManagerFeeWithdraw(
        IWithdrawHandlerVaultCore targetVaultCore,
        uint256 sharesToWithdrawE18
    ) internal view {
        uint256 navUsdE18 = WithdrawHandlerReaders.readVaultNavUsdE18(targetVaultCore);
        uint256 managerAccruedFeeUsdE18 = VaultState(targetVaultCore.basaltState()).managerAccruedFeeUsdE18();
        uint256 maxSharesE18 = WithdrawHandlerCalculations.calcManagerMaxFeeWithdrawShares(
            BasaltMath(targetVaultCore.basaltMath()), navUsdE18, managerAccruedFeeUsdE18, BasaltConstants.SHARE_UNIT
        );
        if (sharesToWithdrawE18 > maxSharesE18) {
            revert WithdrawExceedsManagerFeeShares(
                sharesToWithdrawE18, maxSharesE18, navUsdE18, managerAccruedFeeUsdE18
            );
        }
    }

    function requireProtocolManager(IWithdrawHandlerVaultCore targetVaultCore) internal view {
        address protocolManager = IWithdrawHandlerVaultCoreNftFactory(targetVaultCore.FACTORY()).protocolManager();
        if (msg.sender != protocolManager) revert NotProtocolManager();
    }

    // ────────────────────────────────────────────────────────────────────────
    //  VALUE REQUIREMENTS
    // ────────────────────────────────────────────────────────────────────────

    function requireNoValue() internal view {
        if (msg.value != 0) revert UnexpectedValue();
    }

    // ────────────────────────────────────────────────────────────────────────
    //  ACCESS REQUIREMENTS
    // ────────────────────────────────────────────────────────────────────────

    function requireVaultNftOwner(IWithdrawHandlerVaultCore targetVaultCore) internal view {
        address owner =
            IWithdrawHandlerVaultCoreNftFactory(targetVaultCore.FACTORY()).ownerOfVault(address(targetVaultCore));
        if (msg.sender != owner) revert NotVaultNftOwner();
    }

    function requireCallerIsProtocolManagerOrVaultNftOwner(IWithdrawHandlerVaultCore targetVaultCore) internal view {
        if (msg.sender == IWithdrawHandlerVaultCoreNftFactory(targetVaultCore.FACTORY()).protocolManager()) return;
        address vaultNftOwner =
            IWithdrawHandlerVaultCoreNftFactory(targetVaultCore.FACTORY()).ownerOfVault(address(targetVaultCore));
        if (msg.sender != vaultNftOwner) revert NotManagerOrNftOwner();
    }
}
