// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {IDolomiteIsolationVault, TraderParam, Account, UserConfig} from "../../interfaces/IDolomiteVault.sol";
import {IDolomiteMargin} from "../../interfaces/IDolomiteMargin.sol";
import {IGmxV2Registry} from "../../interfaces/IDolomiteAsyncTraders.sol";
import {IDepositHandlerVaultCore, IVaultFactory} from "../../interfaces/IDepositHandlerVaultCore.sol";
import {BasaltAddresses} from "../../libraries/BasaltAddresses.sol";
import {BasaltConstants} from "../../libraries/BasaltConstants.sol";
import {IBasaltMath} from "../../interfaces/IBasaltMath.sol";
import {VaultState} from "../../core/VaultState.sol";
import {IFeeAccountingHandlerVaultCore} from "../../interfaces/IFeeAccountingHandlerVaultCore.sol";
import {FeeAccountingHandler} from "../FeeAccountingHandler.sol";
import {DepositHandlerReaders} from "./DepositHandlerReaders.sol";
import {DepositContext} from "./DepositHandlerTypes.sol";

library DepositHandlerExecutors {
    using SafeERC20 for IERC20;

    error DolomiteIsolationVaultNotCreated();
    error GmRefundFailed(address dolomiteIsolationVault, address user, uint256 amountGmE18);
    error InsufficientKeeperFee(uint256 providedMsgValue, uint256 dolomiteExecutionFeeRequired);

    // ────────────────────────────────────────────────────────────────────────
    //  DOLOMITE ISOLATION VAULT SETUP
    // ────────────────────────────────────────────────────────────────────────

    // griefer can front-run createVault — fall back to getVaultByAccount.
    function createAndSaveDolomiteIsolationVault(IDepositHandlerVaultCore targetVaultCore)
        internal
        returns (address dolomiteIsolationVault)
    {
        IVaultFactory dolomiteIsolationVaultFactory = IVaultFactory(BasaltAddresses.VAULT_FACTORY);
        try dolomiteIsolationVaultFactory.createVault(address(targetVaultCore)) returns (address freshlyCreated) {
            dolomiteIsolationVault = freshlyCreated;
        } catch {
            dolomiteIsolationVault = dolomiteIsolationVaultFactory.getVaultByAccount(address(targetVaultCore));
        }
        if (dolomiteIsolationVault == address(0)) {
            revert DolomiteIsolationVaultNotCreated();
        }
        callVaultCore(
            targetVaultCore,
            targetVaultCore.basaltState(),
            abi.encodeCall(VaultState.setDolomiteIsolationVault, (dolomiteIsolationVault)),
            0
        );
        _approveDolomitePullsOnce(targetVaultCore, dolomiteIsolationVault);
    }

    // one-shot max approvals: GM via iso vault, WBTC/WETH/USDC via DolomiteMargin.
    function _approveDolomitePullsOnce(
        IDepositHandlerVaultCore targetVaultCore,
        address dolomiteIsolationVault
    ) private {
        callVaultCore(
            targetVaultCore,
            BasaltAddresses.GM_MARKET_TOKEN,
            abi.encodeCall(IERC20.approve, (dolomiteIsolationVault, type(uint256).max)),
            0
        );
        callVaultCore(
            targetVaultCore,
            BasaltAddresses.WBTC,
            abi.encodeCall(IERC20.approve, (BasaltAddresses.DOLOMITE_MARGIN, type(uint256).max)),
            0
        );
        callVaultCore(
            targetVaultCore,
            BasaltAddresses.WETH,
            abi.encodeCall(IERC20.approve, (BasaltAddresses.DOLOMITE_MARGIN, type(uint256).max)),
            0
        );
        callVaultCore(
            targetVaultCore,
            BasaltAddresses.USDC,
            abi.encodeCall(IERC20.approve, (BasaltAddresses.DOLOMITE_MARGIN, type(uint256).max)),
            0
        );
    }

    // ────────────────────────────────────────────────────────────────────────
    //  VAULT STATE TRANSITIONS
    // ────────────────────────────────────────────────────────────────────────

    function setDepositStatePending(IDepositHandlerVaultCore targetVaultCore) internal {
        callVaultCore(
            targetVaultCore,
            targetVaultCore.basaltState(),
            abi.encodeCall(VaultState.setDepositState, (VaultState.State.PENDING)),
            0
        );
    }

    function startGlobalActionCooldown(IDepositHandlerVaultCore targetVaultCore) internal {
        uint256 cooldownEndBlock = IBasaltMath(targetVaultCore.basaltMath())
            .calcCooldownEndBlock(block.number, BasaltConstants.GLOBAL_ACTION_COOLDOWN_BLOCKS);
        callVaultCore(
            targetVaultCore,
            targetVaultCore.basaltState(),
            abi.encodeCall(VaultState.startGlobalActionCooldown, (cooldownEndBlock)),
            0
        );
    }

    // ────────────────────────────────────────────────────────────────────────
    //  DEPOSIT ACCOUNTING
    // ────────────────────────────────────────────────────────────────────────

    function setPendingDepositAccounting(IDepositHandlerVaultCore targetVaultCore, DepositContext memory depositContext)
        internal
    {
        uint256 deadline = IBasaltMath(targetVaultCore.basaltMath())
            .calcKeeperDeadlineTimestamp(block.timestamp, DepositHandlerReaders.readKeeperDeadline(targetVaultCore));
        callVaultCore(
            targetVaultCore,
            targetVaultCore.basaltState(),
            abi.encodeCall(
                VaultState.setPendingDepositAccounting,
                (
                    depositContext.amountGmE18,
                    depositContext.gmPriceE18,
                    depositContext.gmCollateral,
                    deadline
                )
            ),
            0
        );
    }

    function clearPendingDepositAccounting(IDepositHandlerVaultCore targetVaultCore) internal {
        callVaultCore(
            targetVaultCore,
            targetVaultCore.basaltState(),
            abi.encodeCall(VaultState.clearPendingDepositAccounting, ()),
            0
        );
    }

    function finalizeDepositAccounting(
        IDepositHandlerVaultCore targetVaultCore,
        uint256 depositedUsdE18,
        uint256 navUsdE18,
        uint256 gmCollateralE18,
        uint256 wbtcDebtE8
    ) internal {
        callVaultCore(
            targetVaultCore,
            targetVaultCore.basaltState(),
            abi.encodeCall(
                VaultState.finalizeDepositAccounting, (depositedUsdE18, navUsdE18, gmCollateralE18, wbtcDebtE8)
            ),
            0
        );
    }

    function addDepositedUsdE18(IDepositHandlerVaultCore targetVaultCore, uint256 depositedUsdE18) internal {
        callVaultCore(
            targetVaultCore,
            targetVaultCore.basaltState(),
            abi.encodeCall(VaultState.addDepositedUsdE18, (depositedUsdE18)),
            0
        );
    }

    // ────────────────────────────────────────────────────────────────────────
    //  ASYNC DEPOSIT ORCHESTRATION
    // ────────────────────────────────────────────────────────────────────────

    function startAsyncDeposit(
        IDepositHandlerVaultCore targetVaultCore,
        address dolomiteIsolationVault,
        DepositContext memory depositContext,
        uint256 keeperFee
    ) internal {
        setPendingDepositAccounting(targetVaultCore, depositContext);
        setDepositStatePending(targetVaultCore);
        asyncWrap(
            targetVaultCore,
            dolomiteIsolationVault,
            depositContext.borrowWbtcE8,
            depositContext.gmReceivedMinE18,
            keeperFee
        );
    }

    function accrueManagerFeeAfterDepositFinalize(IDepositHandlerVaultCore targetVaultCore) internal {
        FeeAccountingHandler(targetVaultCore.feeAccountingHandler()).accrueManagerFee(
            IFeeAccountingHandlerVaultCore(address(targetVaultCore)),
            IBasaltMath(targetVaultCore.basaltMath()),
            msg.sender
        );
    }

    // ────────────────────────────────────────────────────────────────────────
    //  USER TOKEN TRANSFERS
    // ────────────────────────────────────────────────────────────────────────

    function transferGmFromDepositorToVaultCore(IDepositHandlerVaultCore targetVaultCore, uint256 amountGmE18)
        internal
    {
        IERC20(BasaltAddresses.GM_MARKET_TOKEN).safeTransferFrom(msg.sender, address(targetVaultCore), amountGmE18);
    }

    function refundGmFromPositionToUser(
        IDepositHandlerVaultCore targetVaultCore,
        address dolomiteIsolationVault,
        address user,
        uint256 amountGmE18
    ) internal {
        callVaultCore(
            targetVaultCore,
            dolomiteIsolationVault,
            abi.encodeCall(
                IDolomiteIsolationVault.transferFromPositionWithUnderlyingToken,
                (BasaltConstants.DOLOMITE_ISOLATION_ACCOUNT, 0, amountGmE18)
            ),
            0
        );
        callVaultCore(
            targetVaultCore,
            dolomiteIsolationVault,
            abi.encodeCall(IDolomiteIsolationVault.withdrawFromVaultForDolomiteMargin, (0, amountGmE18)),
            0
        );
        // manual SafeERC20 semantics: require true or empty return data.
        bytes memory transferReturnData = callVaultCoreReturning(
            targetVaultCore,
            BasaltAddresses.GM_MARKET_TOKEN,
            abi.encodeWithSelector(IERC20.transfer.selector, user, amountGmE18),
            0
        );
        if (transferReturnData.length != 0 && !abi.decode(transferReturnData, (bool))) {
            revert GmRefundFailed(dolomiteIsolationVault, user, amountGmE18);
        }
    }

    function transferWbtcFromDepositorToVaultCore(IDepositHandlerVaultCore targetVaultCore, uint256 amountWbtcE8)
        internal
    {
        IERC20(BasaltAddresses.WBTC).safeTransferFrom(msg.sender, address(targetVaultCore), amountWbtcE8);
    }

    // ────────────────────────────────────────────────────────────────────────
    //  DOLOMITE ACCOUNT 0 TRANSFERS
    // ────────────────────────────────────────────────────────────────────────

    function depositWbtcToAccount0AndTransferToPosition(
        IDepositHandlerVaultCore targetVaultCore,
        address dolomiteIsolationVault,
        uint256 amountWbtcE8
    ) internal {
        IDolomiteMargin.AccountInfo[] memory accounts = new IDolomiteMargin.AccountInfo[](1);
        accounts[0] = IDolomiteMargin.AccountInfo({owner: address(targetVaultCore), number: 0});

        IDolomiteMargin.ActionArgs[] memory actions = new IDolomiteMargin.ActionArgs[](1);
        actions[0] = IDolomiteMargin.ActionArgs({
            actionType: 0,
            accountId: 0,
            amount: IDolomiteMargin.AssetAmount({sign: true, denomination: 0, ref: 0, value: amountWbtcE8}),
            primaryMarketId: BasaltConstants.DOLOMITE_MARKET_WBTC,
            secondaryMarketId: 0,
            otherAddress: address(targetVaultCore),
            otherAccountId: 0,
            data: ""
        });

        callVaultCore(
            targetVaultCore,
            BasaltAddresses.DOLOMITE_MARGIN,
            abi.encodeCall(IDolomiteMargin.operate, (accounts, actions)),
            0
        );

        callVaultCore(
            targetVaultCore,
            dolomiteIsolationVault,
            abi.encodeCall(
                IDolomiteIsolationVault.transferIntoPositionWithOtherToken,
                (
                    0,
                    BasaltConstants.DOLOMITE_ISOLATION_ACCOUNT,
                    BasaltConstants.DOLOMITE_MARKET_WBTC,
                    _readWbtcAccount0Wei(targetVaultCore),
                    1
                )
            ),
            0
        );
    }

    function depositGmToAccount0(
        IDepositHandlerVaultCore targetVaultCore,
        address dolomiteIsolationVault,
        uint256 amountGmE18
    ) internal {
        callVaultCore(
            targetVaultCore,
            dolomiteIsolationVault,
            abi.encodeCall(IDolomiteIsolationVault.depositIntoVaultForDolomiteMargin, (0, amountGmE18)),
            0
        );
    }

    // ────────────────────────────────────────────────────────────────────────
    //  DOLOMITE ISOLATION POSITION TRANSFERS
    // ────────────────────────────────────────────────────────────────────────

    function transferToPosition(
        IDepositHandlerVaultCore targetVaultCore,
        address dolomiteIsolationVault,
        uint256 amountGmE18
    ) internal returns (uint256 dolomiteFeeSpent) {
        if (
            DepositHandlerReaders.readVaultGmCollateralE18(targetVaultCore) == 0
                && DepositHandlerReaders.readVaultWbtcDebtE8(targetVaultCore) == 0
        ) {
            dolomiteFeeSpent = IVaultFactory(BasaltAddresses.VAULT_FACTORY).executionFee();
            // explicit revert beats msg.value-fee underflow downstream.
            if (msg.value < dolomiteFeeSpent) {
                revert InsufficientKeeperFee(msg.value, dolomiteFeeSpent);
            }
            callVaultCore(
                targetVaultCore,
                dolomiteIsolationVault,
                abi.encodeCall(
                    IDolomiteIsolationVault.openBorrowPosition,
                    (0, BasaltConstants.DOLOMITE_ISOLATION_ACCOUNT, amountGmE18)
                ),
                dolomiteFeeSpent
            );
        } else {
            callVaultCore(
                targetVaultCore,
                dolomiteIsolationVault,
                abi.encodeCall(
                    IDolomiteIsolationVault.transferIntoPositionWithUnderlyingToken,
                    (0, BasaltConstants.DOLOMITE_ISOLATION_ACCOUNT, amountGmE18)
                ),
                0
            );
        }
    }

    // ────────────────────────────────────────────────────────────────────────
    //  ASYNC WRAP EXECUTION
    // ────────────────────────────────────────────────────────────────────────

    function asyncWrap(
        IDepositHandlerVaultCore targetVaultCore,
        address dolomiteIsolationVault,
        uint256 borrowWbtcE8,
        uint256 gmReceivedMinE18,
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
        callVaultCore(
            targetVaultCore,
            dolomiteIsolationVault,
            abi.encodeCall(
                IDolomiteIsolationVault.swapExactInputForOutput,
                (
                    BasaltConstants.DOLOMITE_ISOLATION_ACCOUNT,
                    marketIds,
                    borrowWbtcE8,
                    gmReceivedMinE18,
                    traders,
                    new Account[](0),
                    UserConfig({
                        deadline: IBasaltMath(targetVaultCore.basaltMath())
                            .calcKeeperDeadlineTimestamp(block.timestamp, DepositHandlerReaders.readKeeperDeadline(targetVaultCore)),
                        balanceCheckFlag: 3,
                        eventType: 1
                    })
                )
            ),
            keeperFee
        );
    }

    // ────────────────────────────────────────────────────────────────────────
    //  VAULT CORE CALL PRIMITIVES
    // ────────────────────────────────────────────────────────────────────────

    function callVaultCore(IDepositHandlerVaultCore targetVaultCore, address target, bytes memory data, uint256 value)
        internal
    {
        targetVaultCore.universalCall{value: value}(msg.sender, target, data, value, false);
    }

    function callVaultCoreReturning(
        IDepositHandlerVaultCore targetVaultCore,
        address target,
        bytes memory data,
        uint256 value
    ) internal returns (bytes memory) {
        return targetVaultCore.universalCall{value: value}(msg.sender, target, data, value, false);
    }

    // ────────────────────────────────────────────────────────────────────────
    //  INTERNAL READ HELPERS
    // ────────────────────────────────────────────────────────────────────────

    function _readWbtcAccount0Wei(IDepositHandlerVaultCore targetVaultCore) internal view returns (uint256) {
        IDolomiteMargin.Wei memory wbtcAccount0Wei = IDolomiteMargin(BasaltAddresses.DOLOMITE_MARGIN)
            .getAccountWei(
                IDolomiteMargin.AccountInfo({owner: address(targetVaultCore), number: 0}),
                BasaltConstants.DOLOMITE_MARKET_WBTC
            );
        return wbtcAccount0Wei.value;
    }
}
