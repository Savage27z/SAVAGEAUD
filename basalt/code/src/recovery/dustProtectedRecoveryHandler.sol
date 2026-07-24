// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";

import {IDolomiteMargin} from "../interfaces/IDolomiteMargin.sol";
import {IDolomiteIsolationVault} from "../interfaces/IDolomiteVault.sol";
import {BasaltAddresses} from "../libraries/BasaltAddresses.sol";
import {BasaltConstants} from "../libraries/BasaltConstants.sol";

/*
 * ============================================================================
 *  WHAT THIS CONTRACT IS (and why it exists)
 * ============================================================================
 *
 *  A Basalt deposit is a two-step, GMX-async operation: your GM is placed into
 *  your isolation position, then a leverage step borrows WBTC and swaps it into
 *  more GM through GMX to build the delta-neutral hedge.
 *
 *  If that GMX leverage swap is CANCELLED by GMX (e.g. the minimum-out slippage
 *  was a hair too tight), Dolomite unwinds the borrow but its par/index rounding
 *  can leave a **1-satoshi WBTC dust debt** on your position. The normal deposit
 *  finalize then takes the refund branch, which withdraws 100% of your GM — and
 *  that 100% withdrawal against a non-zero (1-wei) debt makes Dolomite revert
 *  with "Undercollateralized". Result: your deposit is stuck PENDING and cannot
 *  be finalized, even though your GM is safe in the position.
 *
 *  This handler is the surgical, minimal fix for exactly that state. It lets the
 *  vault's own NFT owner send a tiny, capped amount of WBTC into their own
 *  position to cover the dust debt. Once the debt is covered, the ordinary
 *  finalize/refund succeeds and the deposited GM is returned to the owner.
 *
 *  It does NOTHING else: WBTC only, a small hard cap, only while the deposit is
 *  PENDING and has been stuck past a grace period, only callable by the vault's
 *  own NFT owner. It cannot touch any other vault or any other operation.
 *
 * ============================================================================
 *  NOTICE FOR THE VAULT OWNER (the person whose deposit is stuck)
 * ============================================================================
 *
 *  "This is a handler that lets YOU finalize your own stuck deposit. While the
 *   deposit is still PENDING, you (the owner of your vault NFT) send a small
 *   amount of WBTC into your own vault's position to cover a tiny dust debt that
 *   is blocking the finalize. This contract's address is already published in
 *   the official repository. You will need to ACCEPT this handler for your vault
 *   first (nobody can attach it to your vault without your signature). After the
 *   dust is covered, your deposit is finalized — by you, or by the protocol
 *   keeper at its own cost — and your deposited funds are returned to you."
 *
 * ============================================================================
 *  HOW IT IS CALLED
 * ============================================================================
 *
 *  Called DIRECTLY by the vault NFT owner (not through the ManagerContract — the
 *  ManagerContract only has hardcoded functions for the known handlers and has
 *  no way to route to this one). The owner first accepts this handler into a
 *  free extension slot (proposeHandler by the protocol manager -> acceptHandler
 *  by the NFT owner), then calls addDustWbtcToUnblockStuckDeposit(...). This
 *  handler drives the vault through VaultCore.universalCall with
 *  initiator = the NFT owner, which the VaultCore authorizes.
 * ============================================================================
 */
contract DustProtectedRecoveryHandler is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ------------------------------------------------------------------------
    //  Tunables (all named in full; no shorthand)
    // ------------------------------------------------------------------------

    /// VaultState.State enum value for a PENDING operation (IDLE = 0, PENDING = 1).
    uint8 internal constant DEPOSIT_STATE_ENUM_VALUE_PENDING = 1;

    /// The deposit must have been stuck at least this long past its keeper
    /// deadline before recovery is allowed. Normal GMX settle is ~60 seconds,
    /// so ten minutes makes it unambiguous that the operation is genuinely
    /// broken and not merely in-flight.
    uint256 internal constant RECOVERY_GRACE_PERIOD_IN_SECONDS = 10 minutes;

    /// Hard ceiling on how much WBTC may be added in a single call, expressed in
    /// satoshis (WBTC has 8 decimals). 20_000 satoshis is ~0.0002 WBTC (roughly
    /// ten to twelve US dollars). The dust actually needing coverage is typically
    /// a single satoshi; this ceiling exists purely so the function can never be
    /// used to push meaningful value in, keeping it a pure rescue and never a
    /// donation vector.
    uint256 internal constant MAXIMUM_WBTC_TOP_UP_IN_SATOSHIS = 20_000;

    /// Dolomite balance-check flag used when moving WBTC from the vault's Dolomite
    /// account zero into the isolation position (mirrors the deposit handler:
    /// check the FROM side only).
    uint8 internal constant DOLOMITE_BALANCE_CHECK_FLAG_FROM = 1;

    /// The vault's transient Dolomite account (account number zero).
    uint256 internal constant DOLOMITE_TRANSIENT_ACCOUNT_NUMBER = 0;

    // ------------------------------------------------------------------------
    //  Events
    // ------------------------------------------------------------------------

    event DustWbtcAddedToUnblockStuckDeposit(
        address indexed vaultCoreContract,
        address indexed vaultNonFungibleTokenOwner,
        uint256 wbtcAddedInSatoshis
    );

    // ------------------------------------------------------------------------
    //  Errors
    // ------------------------------------------------------------------------

    error OnlyTheVaultNftOwnerMayRecover(address caller, address vaultNonFungibleTokenOwner);
    error DepositIsNotPending(uint8 currentDepositStateEnumValue);
    error DepositHasNotBeenStuckLongEnough(uint256 nowTimestamp, uint256 recoveryUnlocksAtTimestamp);
    error WbtcTopUpAmountMustBeGreaterThanZero();
    error WbtcTopUpAmountExceedsHardCeiling(uint256 requestedSatoshis, uint256 maximumSatoshis);
    error IsolationVaultDoesNotExist();

    // ------------------------------------------------------------------------
    //  The single recovery entrypoint
    // ------------------------------------------------------------------------

    /**
     * @notice Add a tiny, capped amount of WBTC into your OWN stuck vault's
     *         Dolomite position to cover the dust debt that is blocking the
     *         deposit finalize. After this succeeds, call the ordinary
     *         DepositHandler.finalizeDeposit (or let the keeper do it) to have
     *         your deposited GM returned to you.
     * @param  vaultCoreContract         Your vault's VaultCore contract.
     * @param  wbtcAmountToAddInSatoshis WBTC to add (8 decimals), <= the hard
     *                                   ceiling. In practice one satoshi is enough.
     *
     * The caller (msg.sender) must be the NFT owner of this vault and must have
     * approved this handler to move `wbtcAmountToAddInSatoshis` of WBTC. The WBTC
     * is pulled from the caller — the rescue is paid for by the caller.
     */
    function addDustWbtcToUnblockStuckDeposit(
        IRecoverableVaultCore vaultCoreContract,
        uint256 wbtcAmountToAddInSatoshis
    ) external nonReentrant {
        IRecoverableVaultState vaultStateContract = IRecoverableVaultState(vaultCoreContract.basaltState());
        IRecoverableVaultCoreNftFactory vaultCoreNftFactory =
            IRecoverableVaultCoreNftFactory(vaultCoreContract.FACTORY());

        address vaultNonFungibleTokenOwner = vaultCoreNftFactory.ownerOfVault(address(vaultCoreContract));

        // --- Access: only this vault's NFT owner, on their own vault. ---
        if (msg.sender != vaultNonFungibleTokenOwner) {
            revert OnlyTheVaultNftOwnerMayRecover(msg.sender, vaultNonFungibleTokenOwner);
        }

        // --- State: the deposit must actually be stuck PENDING. If IDLE, this
        //     whole function is unusable (nothing to recover). ---
        uint8 currentDepositStateEnumValue = vaultStateContract.depositState();
        if (currentDepositStateEnumValue != DEPOSIT_STATE_ENUM_VALUE_PENDING) {
            revert DepositIsNotPending(currentDepositStateEnumValue);
        }

        // --- Time: must be genuinely stuck (past the keeper deadline + grace),
        //     so we never interfere with a deposit GMX is still settling. ---
        uint256 recoveryUnlocksAtTimestamp =
            vaultStateContract.pendingDepositDeadline() + RECOVERY_GRACE_PERIOD_IN_SECONDS;
        if (block.timestamp <= recoveryUnlocksAtTimestamp) {
            revert DepositHasNotBeenStuckLongEnough(block.timestamp, recoveryUnlocksAtTimestamp);
        }

        // --- Amount: strictly bounded so this can only ever cover dust. ---
        if (wbtcAmountToAddInSatoshis == 0) {
            revert WbtcTopUpAmountMustBeGreaterThanZero();
        }
        if (wbtcAmountToAddInSatoshis > MAXIMUM_WBTC_TOP_UP_IN_SATOSHIS) {
            revert WbtcTopUpAmountExceedsHardCeiling(wbtcAmountToAddInSatoshis, MAXIMUM_WBTC_TOP_UP_IN_SATOSHIS);
        }

        address dolomiteIsolationVaultAddress = vaultStateContract.dolomiteIsolationVault();
        if (dolomiteIsolationVaultAddress == address(0)) {
            revert IsolationVaultDoesNotExist();
        }

        // --- Step 1: pull the WBTC from the caller into the VaultCore. ---
        IERC20(BasaltAddresses.WBTC).safeTransferFrom(
            msg.sender, address(vaultCoreContract), wbtcAmountToAddInSatoshis
        );

        // --- Step 2: deposit that WBTC into the vault's Dolomite account zero. ---
        _depositWbtcIntoDolomiteAccountZero(vaultCoreContract, vaultNonFungibleTokenOwner, wbtcAmountToAddInSatoshis);

        // --- Step 3: move the WBTC from account zero into the isolation
        //     position (account 100), covering the dust debt there. ---
        _transferWbtcFromAccountZeroIntoIsolationPosition(
            vaultCoreContract, vaultNonFungibleTokenOwner, dolomiteIsolationVaultAddress
        );

        emit DustWbtcAddedToUnblockStuckDeposit(
            address(vaultCoreContract), vaultNonFungibleTokenOwner, wbtcAmountToAddInSatoshis
        );
    }

    // ------------------------------------------------------------------------
    //  Internal Dolomite plumbing (driven through VaultCore.universalCall)
    // ------------------------------------------------------------------------

    function _depositWbtcIntoDolomiteAccountZero(
        IRecoverableVaultCore vaultCoreContract,
        address vaultNonFungibleTokenOwner,
        uint256 wbtcAmountToAddInSatoshis
    ) internal {
        IDolomiteMargin.AccountInfo[] memory dolomiteAccountsToOperateOn = new IDolomiteMargin.AccountInfo[](1);
        dolomiteAccountsToOperateOn[0] = IDolomiteMargin.AccountInfo({
            owner: address(vaultCoreContract),
            number: DOLOMITE_TRANSIENT_ACCOUNT_NUMBER
        });

        IDolomiteMargin.ActionArgs[] memory dolomiteDepositActions = new IDolomiteMargin.ActionArgs[](1);
        dolomiteDepositActions[0] = IDolomiteMargin.ActionArgs({
            actionType: 0, // Deposit
            accountId: 0,
            amount: IDolomiteMargin.AssetAmount({sign: true, denomination: 0, ref: 0, value: wbtcAmountToAddInSatoshis}),
            primaryMarketId: BasaltConstants.DOLOMITE_MARKET_WBTC,
            secondaryMarketId: 0,
            otherAddress: address(vaultCoreContract),
            otherAccountId: 0,
            data: ""
        });

        vaultCoreContract.universalCall(
            vaultNonFungibleTokenOwner,
            BasaltAddresses.DOLOMITE_MARGIN,
            abi.encodeCall(IDolomiteMargin.operate, (dolomiteAccountsToOperateOn, dolomiteDepositActions)),
            0,
            false
        );
    }

    function _transferWbtcFromAccountZeroIntoIsolationPosition(
        IRecoverableVaultCore vaultCoreContract,
        address vaultNonFungibleTokenOwner,
        address dolomiteIsolationVaultAddress
    ) internal {
        uint256 wbtcNowSittingInDolomiteAccountZero = IDolomiteMargin(BasaltAddresses.DOLOMITE_MARGIN)
            .getAccountWei(
                IDolomiteMargin.AccountInfo({
                    owner: address(vaultCoreContract),
                    number: DOLOMITE_TRANSIENT_ACCOUNT_NUMBER
                }),
                BasaltConstants.DOLOMITE_MARKET_WBTC
            )
            .value;

        vaultCoreContract.universalCall(
            vaultNonFungibleTokenOwner,
            dolomiteIsolationVaultAddress,
            abi.encodeCall(
                IDolomiteIsolationVault.transferIntoPositionWithOtherToken,
                (
                    DOLOMITE_TRANSIENT_ACCOUNT_NUMBER,
                    BasaltConstants.DOLOMITE_ISOLATION_ACCOUNT,
                    BasaltConstants.DOLOMITE_MARKET_WBTC,
                    wbtcNowSittingInDolomiteAccountZero,
                    DOLOMITE_BALANCE_CHECK_FLAG_FROM
                )
            ),
            0,
            false
        );
    }
}

// ============================================================================
//  Minimal interfaces this handler needs (spelled out, no imports of internals)
// ============================================================================

interface IRecoverableVaultCore {
    function basaltState() external view returns (address);
    function FACTORY() external view returns (address);
    function universalCall(
        address initiator,
        address target,
        bytes calldata data,
        uint256 value,
        bool useDelegateCall
    ) external payable returns (bytes memory);
}

interface IRecoverableVaultState {
    function depositState() external view returns (uint8);
    function pendingDepositDeadline() external view returns (uint256);
    function dolomiteIsolationVault() external view returns (address);
}

interface IRecoverableVaultCoreNftFactory {
    function ownerOfVault(address vaultCoreContract) external view returns (address);
}
