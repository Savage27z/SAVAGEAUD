// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {IDepositHandler} from "../interfaces/IDepositHandler.sol";
import {IDepositHandlerVaultCore} from "../interfaces/IDepositHandlerVaultCore.sol";
import {IDepositHandlerVaultCoreNftFactory} from "../interfaces/IDepositHandlerVaultCoreNftFactory.sol";
import {IDolomiteMargin} from "../interfaces/IDolomiteMargin.sol";
import {BasaltMath} from "../pure/BasaltMath.sol";
import {VaultState} from "../core/VaultState.sol";
import {DepositHandlerCalculations} from "./depositHandlerLibraries/DepositHandlerCalculations.sol";
import {DepositHandlerExecutors} from "./depositHandlerLibraries/DepositHandlerExecutors.sol";
import {DepositHandlerReaders} from "./depositHandlerLibraries/DepositHandlerReaders.sol";
import {DepositHandlerRequirements} from "./depositHandlerLibraries/DepositHandlerRequirements.sol";
import {
    DepositBranch,
    DepositContext,
    InvalidDepositBranch,
    NeedToAbsorbSurplus,
    NoSurplusToAbsorb,
    ZeroAbsorbAmount
} from "./depositHandlerLibraries/DepositHandlerTypes.sol";

contract DepositHandler is ReentrancyGuard, IDepositHandler {
    // ────────────────────────────────────────────────────────────────────────
    //  EVENTS
    // ────────────────────────────────────────────────────────────────────────

    event DepositInitiated(address indexed depositor, address indexed targetVaultCore, DepositContext depositContext);
    event DepositFinalized(
        address indexed finalizer,
        address indexed targetVaultCore,
        uint256 totalDepositedGmE18,
        uint256 totalDepositedUsdE18,
        uint256 navUsdE18,
        uint256 gmCollateralE18,
        uint256 wbtcDebtE8
    );
    event DepositRefunded(address indexed depositor, uint256 gmReturned);
    event DepositBranchSelected(address indexed vaultCore, DepositBranch branch);
    event SurplusAbsorbInitiated(
        address indexed initiator,
        address indexed targetVaultCore,
        uint256 surplusWbtcE8,
        uint256 expectedGmE18,
        uint256 minGmE18
    );
    event WbtcAddedAsDeposit(
        address indexed depositor,
        address indexed targetVaultCore,
        uint256 previousSurplusWbtcE8,
        uint256 amountWbtcE8,
        uint256 valueUsdE18
    );

    // ────────────────────────────────────────────────────────────────────────
    //  MODIFIERS
    // ────────────────────────────────────────────────────────────────────────

    modifier onlyVaultNftOwner(IDepositHandlerVaultCore targetVaultCore) {
        DepositHandlerRequirements.requireVaultNftOwner(targetVaultCore);
        _;
    }

    // ════════════════════════════════════════════════════════════════════════
    //  NFT OWNER EXTERNAL WRITE FUNCTIONS
    // ════════════════════════════════════════════════════════════════════════

    function deposit(IDepositHandlerVaultCore targetVaultCore, uint256 amountGmE18, uint256 userSlippageBps)
        external
        payable
        nonReentrant
        onlyVaultNftOwner(targetVaultCore)
    {
        DepositHandlerRequirements.requireAllIdle(targetVaultCore);
        DepositHandlerRequirements.requireCooldownPassed(targetVaultCore);
        DepositHandlerRequirements.requireValidDepositParams(amountGmE18, userSlippageBps);
        DepositHandlerRequirements.requireSequencerUp();
        _executeDepositBranch(targetVaultCore, amountGmE18, userSlippageBps);
    }

    function absorbSurplus(IDepositHandlerVaultCore targetVaultCore, uint256 userSlippageBps)
        external
        payable
        nonReentrant
        onlyVaultNftOwner(targetVaultCore)
    {
        DepositHandlerRequirements.requireAllIdle(targetVaultCore);
        DepositHandlerRequirements.requireCooldownPassed(targetVaultCore);
        DepositHandlerRequirements.requireValidSlippage(userSlippageBps);
        DepositHandlerRequirements.requireSequencerUp();

        uint256 surplusWbtcE8 = DepositHandlerReaders.readVaultWbtcSurplusE8(targetVaultCore);
        if (surplusWbtcE8 == 0) revert NoSurplusToAbsorb();

        DepositContext memory depositContext = collectVaultData(targetVaultCore);
        uint256 expectedGmE18 = DepositHandlerCalculations.calcExpectedAbsorbGmE18(depositContext, surplusWbtcE8);
        uint256 minGmE18 =
            DepositHandlerCalculations.calcSlippageAdjustedGmE18(depositContext, expectedGmE18, userSlippageBps);
        if (minGmE18 == 0) revert ZeroAbsorbAmount();

        // no external GM input; surplus wraps via finalize.
        depositContext.amountGmE18 = 0;
        DepositHandlerExecutors.setPendingDepositAccounting(targetVaultCore, depositContext);
        DepositHandlerExecutors.setDepositStatePending(targetVaultCore);
        DepositHandlerExecutors.asyncWrap(
            targetVaultCore,
            DepositHandlerReaders.readVaultDolomiteIsolationVaultAddress(targetVaultCore),
            surplusWbtcE8,
            minGmE18,
            msg.value
        );

        emit SurplusAbsorbInitiated(msg.sender, address(targetVaultCore), surplusWbtcE8, expectedGmE18, minGmE18);
    }

    function addWbtcAsDeposit(IDepositHandlerVaultCore targetVaultCore, uint256 amountWbtcE8)
        external
        nonReentrant
        onlyVaultNftOwner(targetVaultCore)
    {
        DepositHandlerRequirements.requireAllIdle(targetVaultCore);
        DepositHandlerRequirements.requireCooldownPassed(targetVaultCore);
        DepositHandlerRequirements.requireSequencerUp();

        uint256 surplusWbtcE8 = DepositHandlerReaders.readVaultWbtcSurplusE8(targetVaultCore);
        DepositContext memory depositContext = collectVaultData(targetVaultCore);
        uint256 surplusValueUsdE18 =
            DepositHandlerCalculations.calcWbtcSurplusValueUsdE18(depositContext, surplusWbtcE8);
        DepositHandlerRequirements.requireWbtcSurplusValueWithinDustLimit(surplusValueUsdE18);

        uint256 depositValueUsdE18 = DepositHandlerCalculations.calcWbtcSurplusValueUsdE18(depositContext, amountWbtcE8);
        DepositHandlerRequirements.requireWbtcSurplusValueWithinDustLimit(depositValueUsdE18);

        address dolomiteIsolationVault = DepositHandlerReaders.readVaultDolomiteIsolationVaultAddress(targetVaultCore);
        DepositHandlerExecutors.transferWbtcFromDepositorToVaultCore(targetVaultCore, amountWbtcE8);
        DepositHandlerExecutors.depositWbtcToAccount0AndTransferToPosition(
            targetVaultCore, dolomiteIsolationVault, amountWbtcE8
        );
        DepositHandlerExecutors.addDepositedUsdE18(targetVaultCore, depositValueUsdE18);

        emit WbtcAddedAsDeposit(msg.sender, address(targetVaultCore), surplusWbtcE8, amountWbtcE8, depositValueUsdE18);
    }

    // ════════════════════════════════════════════════════════════════════════
    //  MANAGER OR VAULT NFT OWNER — FINALIZE
    // ════════════════════════════════════════════════════════════════════════

    function finalizeDeposit(IDepositHandlerVaultCore targetVaultCore) external nonReentrant {
        DepositHandlerRequirements.requireCallerIsProtocolManagerOrVaultNftOwner(targetVaultCore);
        VaultState vaultState = VaultState(targetVaultCore.basaltState());
        DepositHandlerRequirements.requireDepositPending(vaultState);
        DepositHandlerRequirements.requireVaultNotFrozen(targetVaultCore);
        DepositHandlerRequirements.requireSequencerUp();

        uint256 navUsdE18 = DepositHandlerReaders.readVaultNavUsdE18(targetVaultCore);
        uint256 gmCollateralE18 = DepositHandlerReaders.readVaultGmCollateralE18(targetVaultCore);
        uint256 wbtcDebtE8 = DepositHandlerReaders.readVaultWbtcDebtE8(targetVaultCore);

        if (decideDepositSuccessOrFail(BasaltMath(targetVaultCore.basaltMath()), vaultState, gmCollateralE18) == false) {
            _execRefundDepositPath(targetVaultCore, vaultState);
            return;
        }

        uint256 depositedUsdE18 = BasaltMath(targetVaultCore.basaltMath()).calcGmValueE18(
            vaultState.pendingDepositAmountGmE18(), vaultState.pendingDepositGmPriceE18()
        );
        DepositHandlerExecutors.finalizeDepositAccounting(
            targetVaultCore, depositedUsdE18, navUsdE18, gmCollateralE18, wbtcDebtE8
        );
        DepositHandlerExecutors.accrueManagerFeeAfterDepositFinalize(targetVaultCore);
        DepositHandlerExecutors.startGlobalActionCooldown(targetVaultCore);

        emit DepositFinalized(
            msg.sender,
            address(targetVaultCore),
            vaultState.totalDepositedGmE18(),
            vaultState.totalDepositedUsdE18(),
            navUsdE18,
            gmCollateralE18,
            wbtcDebtE8
        );
    }

    // ════════════════════════════════════════════════════════════════════════
    //  PUBLIC VIEW / PURE FUNCTIONS
    // ════════════════════════════════════════════════════════════════════════

    function decideDepositSuccessOrFail(BasaltMath basaltMath, VaultState vaultState, uint256 currentGmCollateralE18)
        public
        view
        returns (bool)
    {
        uint256 requiredGmCollateralE18 = basaltMath.calcPendingTotalGmE18(
            vaultState.pendingDepositGmCollateralSnapshotE18(), vaultState.pendingDepositAmountGmE18()
        );
        return currentGmCollateralE18 > requiredGmCollateralE18;
    }

    function collectVaultData(IDepositHandlerVaultCore targetVaultCore)
        public
        view
        returns (DepositContext memory depositContext)
    {
        depositContext.dolomiteMargin = IDolomiteMargin(DepositHandlerReaders.readDolomiteMarginContractAddress());
        depositContext.basaltMath = BasaltMath(DepositHandlerReaders.readBasaltMathContractAddress(targetVaultCore));
        depositContext.gmPriceE18 = DepositHandlerReaders.readDolomiteGmPriceE18(depositContext.dolomiteMargin);
        depositContext.wbtcPriceE18 = DepositHandlerReaders.readDolomiteWbtcPriceE18(depositContext);
        depositContext.wbtcPriceE8 = DepositHandlerCalculations.toWbtcPriceE8(depositContext);
        depositContext.gmCollateral = DepositHandlerReaders.readVaultGmCollateralE18(targetVaultCore);
        depositContext.wbtcDebt = DepositHandlerReaders.readVaultWbtcDebtE8(targetVaultCore);
        depositContext.isolationVaultCreated = DepositHandlerReaders.readIfIsolationVaultCreated(targetVaultCore);
        depositContext.surplusGm = DepositHandlerReaders.readVaultSurplusGm(targetVaultCore);
    }

    function checkLtvBelowCap(DepositContext memory depositContext) public pure {
        DepositHandlerRequirements.requireLtvBelowCap(depositContext);
    }

    function selectDepositBranch(IDepositHandlerVaultCore targetVaultCore, uint256 amountGmE18, uint256 userSlippageBps)
        public
        view
        returns (DepositContext memory depositContext)
    {
        depositContext = collectVaultData(targetVaultCore);
        depositContext.amountGmE18 = amountGmE18;
        depositContext.userSlippageBps = userSlippageBps;

        if (depositContext.isolationVaultCreated == false) {
            depositContext.branch = DepositBranch.CreateIsolationVault;
        } else if (depositContext.wbtcDebt > 0 && depositContext.gmCollateral > 0) {
            depositContext.branch = DepositBranch.Standard;
        } else if (depositContext.wbtcDebt == 0 && depositContext.surplusGm > 0) {
            depositContext.branch = DepositBranch.DebtFreeSurplus;
        } else if (depositContext.gmCollateral == 0 && depositContext.wbtcDebt == 0 && depositContext.surplusGm == 0) {
            depositContext.branch = DepositBranch.EmptyIsolationVault;
        } else if (depositContext.gmCollateral > 0 && depositContext.wbtcDebt == 0 && depositContext.surplusGm == 0) {
            depositContext.branch = DepositBranch.CollateralOnly;
        } else {
            revert InvalidDepositBranch(depositContext.gmCollateral, depositContext.wbtcDebt, depositContext.surplusGm);
        }
    }

    // ════════════════════════════════════════════════════════════════════════
    //  BRANCH ROUTING HELPER
    // ════════════════════════════════════════════════════════════════════════

    function _executeDepositBranch(
        IDepositHandlerVaultCore targetVaultCore,
        uint256 amountGmE18,
        uint256 userSlippageBps
    ) internal returns (DepositContext memory depositContext) {
        depositContext = selectDepositBranch(targetVaultCore, amountGmE18, userSlippageBps);

        if (depositContext.branch == DepositBranch.CreateIsolationVault) {
            _depositCreateIsolationVault(targetVaultCore, depositContext);
        } else if (depositContext.branch == DepositBranch.EmptyIsolationVault) {
            _depositInEmptyIsolationVault(targetVaultCore, depositContext);
        } else if (depositContext.branch == DepositBranch.CollateralOnly) {
            _depositWithCollateralInVaultOnly(targetVaultCore, depositContext);
        } else if (depositContext.branch == DepositBranch.DebtFreeSurplus) {
            _depositDebtFreeAndSurplus();
        } else if (depositContext.branch == DepositBranch.Standard) {
            _depositStandard(targetVaultCore, depositContext);
        }
    }

    // ════════════════════════════════════════════════════════════════════════
    //  BRANCH EXECUTION HELPERS
    // ════════════════════════════════════════════════════════════════════════

    function _execRefundDepositPath(IDepositHandlerVaultCore targetVaultCore, VaultState vaultState) internal {
        address vaultOwner =
            IDepositHandlerVaultCoreNftFactory(targetVaultCore.FACTORY()).ownerOfVault(address(targetVaultCore));
        uint256 refundGmE18 = vaultState.pendingDepositAmountGmE18();
        DepositHandlerExecutors.refundGmFromPositionToUser(
            targetVaultCore,
            DepositHandlerReaders.readVaultDolomiteIsolationVaultAddress(targetVaultCore),
            vaultOwner,
            refundGmE18
        );
        DepositHandlerExecutors.clearPendingDepositAccounting(targetVaultCore);
        DepositHandlerExecutors.startGlobalActionCooldown(targetVaultCore);

        emit DepositRefunded(vaultOwner, refundGmE18);
    }

    function _depositCreateIsolationVault(
        IDepositHandlerVaultCore targetVaultCore,
        DepositContext memory depositContext
    ) internal {
        depositContext.targetLtvBps = DepositHandlerReaders.readTargetLtvBps(targetVaultCore);
        depositContext.depositValueE18 = DepositHandlerCalculations.calcDepositValueE18(depositContext);
        depositContext = DepositHandlerCalculations.fillTargetLtvDepositContext(
            depositContext, DepositHandlerCalculations.calcBorrowValueE18(depositContext)
        );

        address dolomiteIsolationVault = DepositHandlerExecutors.createAndSaveDolomiteIsolationVault(targetVaultCore);

        DepositHandlerExecutors.transferGmFromDepositorToVaultCore(targetVaultCore, depositContext.amountGmE18);
        DepositHandlerExecutors.depositGmToAccount0(targetVaultCore, dolomiteIsolationVault, depositContext.amountGmE18);

        uint256 dolomiteFeeSpent =
            DepositHandlerExecutors.transferToPosition(targetVaultCore, dolomiteIsolationVault, depositContext.amountGmE18);

        DepositHandlerExecutors.startAsyncDeposit(
            targetVaultCore,
            dolomiteIsolationVault,
            depositContext,
            depositContext.basaltMath.calcRefundEthWei(msg.value, dolomiteFeeSpent)
        );
        emit DepositInitiated(msg.sender, address(targetVaultCore), depositContext);
    }

    function _depositInEmptyIsolationVault(
        IDepositHandlerVaultCore targetVaultCore,
        DepositContext memory depositContext
    ) internal {
        depositContext.targetLtvBps = DepositHandlerReaders.readTargetLtvBps(targetVaultCore);
        depositContext.depositValueE18 = DepositHandlerCalculations.calcDepositValueE18(depositContext);
        depositContext = DepositHandlerCalculations.fillTargetLtvDepositContext(
            depositContext, DepositHandlerCalculations.calcBorrowValueE18(depositContext)
        );

        address dolomiteIsolationVault = DepositHandlerReaders.readVaultDolomiteIsolationVaultAddress(targetVaultCore);
        DepositHandlerExecutors.transferGmFromDepositorToVaultCore(targetVaultCore, depositContext.amountGmE18);
        DepositHandlerExecutors.depositGmToAccount0(targetVaultCore, dolomiteIsolationVault, depositContext.amountGmE18);
        uint256 dolomiteFeeSpent =
            DepositHandlerExecutors.transferToPosition(targetVaultCore, dolomiteIsolationVault, depositContext.amountGmE18);
        DepositHandlerExecutors.startAsyncDeposit(
            targetVaultCore,
            dolomiteIsolationVault,
            depositContext,
            depositContext.basaltMath.calcRefundEthWei(msg.value, dolomiteFeeSpent)
        );
        emit DepositInitiated(msg.sender, address(targetVaultCore), depositContext);
    }

    function _depositWithCollateralInVaultOnly(
        IDepositHandlerVaultCore targetVaultCore,
        DepositContext memory depositContext
    ) internal {
        depositContext.targetLtvBps = DepositHandlerReaders.readTargetLtvBps(targetVaultCore);
        depositContext.depositValueE18 = DepositHandlerCalculations.calcDepositValueE18(depositContext);
        depositContext = DepositHandlerCalculations.fillTargetLtvDepositContext(
            depositContext, DepositHandlerCalculations.calcBorrowValueForCollateralInVaultOnly(depositContext)
        );

        address dolomiteIsolationVault = DepositHandlerReaders.readVaultDolomiteIsolationVaultAddress(targetVaultCore);
        DepositHandlerExecutors.transferGmFromDepositorToVaultCore(targetVaultCore, depositContext.amountGmE18);
        DepositHandlerExecutors.depositGmToAccount0(targetVaultCore, dolomiteIsolationVault, depositContext.amountGmE18);
        uint256 dolomiteFeeSpent =
            DepositHandlerExecutors.transferToPosition(targetVaultCore, dolomiteIsolationVault, depositContext.amountGmE18);
        DepositHandlerExecutors.startAsyncDeposit(
            targetVaultCore,
            dolomiteIsolationVault,
            depositContext,
            depositContext.basaltMath.calcRefundEthWei(msg.value, dolomiteFeeSpent)
        );
        emit DepositInitiated(msg.sender, address(targetVaultCore), depositContext);
    }

    function _depositDebtFreeAndSurplus() internal pure {
        revert NeedToAbsorbSurplus();
    }

    function _depositStandard(IDepositHandlerVaultCore targetVaultCore, DepositContext memory depositContext) internal {
        depositContext.borrowWbtcE8 = DepositHandlerCalculations.calcRatioPreservingBorrowWbtcE8(depositContext);
        depositContext.borrowValueE18 = DepositHandlerCalculations.calcBorrowValueFromBorrowWbtcE8(depositContext);
        depositContext.gmReceivedMinE18 = DepositHandlerCalculations.calcGmReceivedMinE18(depositContext);
        DepositHandlerRequirements.requireLtvBelowCap(depositContext);

        address dolomiteIsolationVault = DepositHandlerReaders.readVaultDolomiteIsolationVaultAddress(targetVaultCore);
        DepositHandlerExecutors.transferGmFromDepositorToVaultCore(targetVaultCore, depositContext.amountGmE18);
        DepositHandlerExecutors.depositGmToAccount0(targetVaultCore, dolomiteIsolationVault, depositContext.amountGmE18);
        uint256 dolomiteFeeSpent =
            DepositHandlerExecutors.transferToPosition(targetVaultCore, dolomiteIsolationVault, depositContext.amountGmE18);
        DepositHandlerExecutors.startAsyncDeposit(
            targetVaultCore,
            dolomiteIsolationVault,
            depositContext,
            depositContext.basaltMath.calcRefundEthWei(msg.value, dolomiteFeeSpent)
        );
        emit DepositInitiated(msg.sender, address(targetVaultCore), depositContext);
    }
}
