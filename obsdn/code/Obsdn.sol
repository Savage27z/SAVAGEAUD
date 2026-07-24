// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { ReentrancyGuardUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import { EIP712Upgradeable } from "@openzeppelin/contracts-upgradeable/utils/cryptography/EIP712Upgradeable.sol";
import { EnumerableSet } from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";

import { AccessControl } from "./access/AccessControl.sol";
import { IObsdn } from "./interfaces/IObsdn.sol";
import { ISpotLedger } from "./interfaces/ISpotLedger.sol";
import { IPerpLedger } from "./interfaces/IPerpLedger.sol";
import { IMatching } from "./interfaces/IMatching.sol";
import { IVaultManager } from "./interfaces/IVaultManager.sol";
import { ISigValidator } from "./interfaces/ISigValidator.sol";
import { ObsdnStorage } from "./ObsdnStorage.sol";
import { Roles } from "./libraries/Roles.sol";
import { Errors } from "./libraries/Errors.sol";
import { AdminModule } from "./libraries/core/AdminModule.sol";
import { BalanceModule } from "./libraries/core/BalanceModule.sol";
import { FundingModule } from "./libraries/core/FundingModule.sol";
import { OrderModule } from "./libraries/core/OrderModule.sol";
import { AccountModule } from "./libraries/core/AccountModule.sol";
import { VaultModule } from "./libraries/core/VaultModule.sol";

/// @title Obsdn
/// @notice Main entry point for the Obsidian perpetual exchange protocol
/// @dev Upgradeable contract using EIP-712 signatures and role-based access control
contract Obsdn is Initializable, ReentrancyGuardUpgradeable, EIP712Upgradeable, ObsdnStorage, IObsdn {
    using EnumerableSet for EnumerableSet.AddressSet;

    // ══════════════════════════════════════════════════════════════════════════
    //                                MODIFIERS
    // ══════════════════════════════════════════════════════════════════════════

    modifier onlyRole(bytes32 role) {
        if (!accessControl.hasRole(role, msg.sender)) {
            revert IAccessControl.AccessControlUnauthorizedAccount(msg.sender, role);
        }
        _;
    }

    modifier depositEnabled() {
        if (!canDeposit) {
            revert Errors.Obsdn_DepositDisabled();
        }
        _;
    }

    modifier isCollateral(address token) {
        if (!isCollateralToken(token)) {
            revert Errors.Obsdn_InvalidCollateralToken(token);
        }
        _;
    }

    modifier sequencerEnabled() {
        if (pauseSequencerOps) {
            revert Errors.Obsdn_SequencerOpsPaused();
        }
        _;
    }

    // ══════════════════════════════════════════════════════════════════════════
    //                              INITIALIZATION
    // ══════════════════════════════════════════════════════════════════════════

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes the Obsdn contract with core dependencies
    /// @param accessControl_ The access control contract address
    /// @param spotLedger_ The spot ledger contract address
    /// @param perpLedger_ The perp ledger contract address
    /// @param matching_ The matching engine contract address
    /// @param vaultManager_ The vault manager contract address
    /// @param protocolFeeRecipient_ The initial protocol fee recipient address
    /// @param quoteToken_ The quote token address
    /// @param sigValidator_ The signature validator contract address
    function initialize(
        address accessControl_,
        address spotLedger_,
        address perpLedger_,
        address matching_,
        address vaultManager_,
        address protocolFeeRecipient_,
        address quoteToken_,
        address sigValidator_
    )
        external
        initializer
    {
        __ReentrancyGuard_init();
        __EIP712_init("Obsidian", "1");

        if (
            accessControl_ == address(0) || spotLedger_ == address(0) || perpLedger_ == address(0)
                || matching_ == address(0) || vaultManager_ == address(0) || protocolFeeRecipient_ == address(0)
                || quoteToken_ == address(0) || sigValidator_ == address(0)
        ) {
            revert Errors.ZeroAddress();
        }

        accessControl = AccessControl(accessControl_);
        spotLedger = ISpotLedger(spotLedger_);
        perpLedger = IPerpLedger(perpLedger_);
        matching = IMatching(matching_);
        vaultManager = IVaultManager(vaultManager_);
        protocolFeeRecipient = protocolFeeRecipient_;
        quoteToken = quoteToken_;
        sigValidator = ISigValidator(sigValidator_);

        collateralTokens.add(quoteToken_);
        canDeposit = true;
        pauseSequencerOps = false;
    }

    // ══════════════════════════════════════════════════════════════════════════
    //                            ADMIN FUNCTIONS
    // ══════════════════════════════════════════════════════════════════════════

    /// @inheritdoc IObsdn
    function setProtocolFeeRecipient(address _protocolFeeRecipient) external onlyRole(Roles.FEE_MANAGER_ROLE) {
        if (_protocolFeeRecipient == address(0)) {
            revert Errors.ZeroAddress();
        }
        protocolFeeRecipient = _protocolFeeRecipient;
    }

    /// @inheritdoc IObsdn
    function setCanDeposit(bool enabled) external onlyRole(Roles.EXCHANGE_OPERATOR_ROLE) {
        canDeposit = enabled;
    }

    /// @inheritdoc IObsdn
    function setPauseSequencerOps(bool paused) external onlyRole(Roles.EXCHANGE_OPERATOR_ROLE) {
        pauseSequencerOps = paused;
    }

    /// @inheritdoc IObsdn
    function claimTradingFee(address token) external onlyRole(Roles.FEE_MANAGER_ROLE) nonReentrant isCollateral(token) {
        AdminModule.claimTradingFee(IObsdn(address(this)), token, protocolFeeRecipient);
    }

    /// @inheritdoc IObsdn
    function claimSequencerFee(address token)
        external
        onlyRole(Roles.FEE_MANAGER_ROLE)
        nonReentrant
        isCollateral(token)
    {
        AdminModule.claimSequencerFee(IObsdn(address(this)), token, protocolFeeRecipient);
    }

    /// @inheritdoc IObsdn
    function withdrawInsuranceFund(
        address token,
        uint128 amountX18
    )
        external
        onlyRole(Roles.FEE_MANAGER_ROLE)
        nonReentrant
        isCollateral(token)
    {
        AdminModule.withdrawInsuranceFund(IObsdn(address(this)), token, amountX18, msg.sender);
    }

    /// @inheritdoc IObsdn
    function settleMakerRebateDebtWithFees(address token)
        external
        onlyRole(Roles.FEE_MANAGER_ROLE)
        nonReentrant
        isCollateral(token)
    {
        AdminModule.settleMakerRebateDebtWithFees(IObsdn(address(this)), token);
    }

    /// @inheritdoc IObsdn
    function depositInsuranceFund(
        address token,
        uint128 amountX18
    )
        external
        onlyRole(Roles.FEE_MANAGER_ROLE)
        nonReentrant
        isCollateral(token)
    {
        BalanceModule.depositInsuranceFund(IObsdn(address(this)), token, amountX18);
    }

    /// @inheritdoc IObsdn
    function depositMakerRebatePayer(
        address token,
        uint128 amountX18
    )
        external
        onlyRole(Roles.FEE_MANAGER_ROLE)
        nonReentrant
        isCollateral(token)
    {
        BalanceModule.depositMakerRebatePayer(IObsdn(address(this)), token, amountX18);
    }

    // ══════════════════════════════════════════════════════════════════════════
    //                             USER FUNCTIONS
    // ══════════════════════════════════════════════════════════════════════════

    /// @inheritdoc IObsdn
    function deposit(address token, uint128 amountX18) external nonReentrant {
        _deposit(msg.sender, token, amountX18);
    }

    /// @inheritdoc IObsdn
    function deposit(address recipient, address token, uint128 amountX18) external nonReentrant {
        _deposit(recipient, token, amountX18);
    }

    /// @dev Internal deposit handler shared by both deposit overloads
    function _deposit(address recipient, address token, uint128 amountX18) internal depositEnabled isCollateral(token) {
        BalanceModule.deposit(IObsdn(address(this)), recipient, token, amountX18);
    }

    /// @inheritdoc IObsdn
    function registerSigner(RegisterSignerParams calldata params) external {
        if (params.sender != msg.sender) {
            revert Errors.Obsdn_SenderMismatch(params.sender, msg.sender);
        }
        _registerSigner(params);
    }

    /// @dev Internal signer registration shared by direct and sequencer-submitted paths
    function _registerSigner(RegisterSignerParams memory params) internal {
        if (signerRegNonceUsed[params.sender][params.nonce]) {
            revert Errors.Obsdn_SignerRegNonceUsed(params.sender, params.nonce);
        }
        signerRegNonceUsed[params.sender][params.nonce] = true;
        AccountModule.registerSigner(IObsdn(address(this)), signerWallets, params);
    }

    /// @inheritdoc IObsdn
    function createVault(CreateVaultParams calldata params) external nonReentrant onlyRole(Roles.OBSDNBE_GENERAL_ROLE) {
        AccountModule.createVault(IObsdn(address(this)), accounts, params);
    }

    /// @inheritdoc IObsdn
    function createSubaccount(CreateSubaccountParams calldata params)
        external
        nonReentrant
        onlyRole(Roles.OBSDNBE_GENERAL_ROLE)
    {
        AccountModule.createSubaccount(IObsdn(address(this)), accounts, params);
    }

    // ══════════════════════════════════════════════════════════════════════════
    //                          SEQUENCER FUNCTIONS
    // ══════════════════════════════════════════════════════════════════════════

    /// @dev Validates and advances the sequencer operation nonce
    function _validateOpNonce(uint64 opNonce) internal {
        if (opNonce != sequencerOpNonce + 1) {
            revert Errors.Obsdn_InvalidOpNonce(opNonce, sequencerOpNonce + 1);
        }
        sequencerOpNonce = opNonce;
    }

    /// @dev Validates and updates the offchain sequence number (must be non-decreasing)
    function _validateSeqNum(uint256 newSeqNum) internal {
        if (newSeqNum < seqNum) {
            revert Errors.Obsdn_InvalidSeqNum(newSeqNum, seqNum);
        }
        seqNum = newSeqNum;
    }

    /// @inheritdoc IObsdn
    function matchOrders(
        uint64 opNonce,
        uint256 seqNum_,
        MatchOrdersParams calldata params
    )
        external
        onlyRole(Roles.SEQUENCER_ROLE)
        nonReentrant
        sequencerEnabled
    {
        _validateOpNonce(opNonce);
        _validateSeqNum(seqNum_);
        OrderModule.matchOrders(IObsdn(address(this)), params);
    }

    /// @inheritdoc IObsdn
    function updateFundingRate(
        uint64 opNonce,
        uint256 seqNum_,
        UpdateFundingRateParams calldata params
    )
        external
        onlyRole(Roles.SEQUENCER_ROLE)
        nonReentrant
        sequencerEnabled
    {
        _validateOpNonce(opNonce);
        _validateSeqNum(seqNum_);
        FundingModule.updateFundingRate(IObsdn(address(this)), params, seqNum_);
    }

    /// @inheritdoc IObsdn
    function processFundingPayment(
        uint64 opNonce,
        uint256 seqNum_,
        ProcessFundingPaymentParams calldata params
    )
        external
        onlyRole(Roles.SEQUENCER_ROLE)
        nonReentrant
        sequencerEnabled
    {
        _validateOpNonce(opNonce);
        _validateSeqNum(seqNum_);
        FundingModule.processFundingPayment(IObsdn(address(this)), params, seqNum_);
    }

    /// @inheritdoc IObsdn
    function processRegisterSigner(
        uint64 opNonce,
        uint256,
        /* seqNum */
        RegisterSignerParams calldata params
    )
        external
        onlyRole(Roles.SEQUENCER_ROLE)
        nonReentrant
        sequencerEnabled
    {
        _validateOpNonce(opNonce);
        _registerSigner(params);
    }

    /// @inheritdoc IObsdn
    function processWithdraw(
        uint64 opNonce,
        uint256 seqNum_,
        WithdrawParams calldata params
    )
        external
        onlyRole(Roles.SEQUENCER_ROLE)
        nonReentrant
        sequencerEnabled
    {
        _validateOpNonce(opNonce);
        _validateSeqNum(seqNum_);

        if (seqNonceUsed[params.sender][params.nonce]) {
            revert Errors.Obsdn_SeqNonceUsed(params.sender, params.nonce);
        }
        seqNonceUsed[params.sender][params.nonce] = true;

        try BalanceModule.withdraw(IObsdn(address(this)), params) {
            emit Withdraw(
                params.sender, params.token, params.nonce, params.amount, params.sequencerFee, OpStatus.Success, seqNum_
            );
        } catch {
            emit Withdraw(
                params.sender, params.token, params.nonce, params.amount, params.sequencerFee, OpStatus.Failure, seqNum_
            );
        }
    }

    /// @inheritdoc IObsdn
    function processTransfer(
        uint64 opNonce,
        uint256 seqNum_,
        TransferParams calldata params
    )
        external
        onlyRole(Roles.SEQUENCER_ROLE)
        nonReentrant
        sequencerEnabled
    {
        _validateOpNonce(opNonce);
        _validateSeqNum(seqNum_);

        // Main wallet always signs — nonce tracked against signer
        address signer =
            accounts[params.from].accountType == AccountType.Subaccount ? accounts[params.from].main : params.from;

        if (seqNonceUsed[signer][params.nonce]) {
            revert Errors.Obsdn_SeqNonceUsed(signer, params.nonce);
        }
        seqNonceUsed[signer][params.nonce] = true;

        try BalanceModule.transfer(IObsdn(address(this)), params) {
            emit Transfer(params.from, params.to, params.token, params.nonce, params.amount, OpStatus.Success, seqNum_);
        } catch {
            emit Transfer(params.from, params.to, params.token, params.nonce, params.amount, OpStatus.Failure, seqNum_);
        }
    }

    /// @inheritdoc IObsdn
    function stakeVault(
        uint64 opNonce,
        uint256 seqNum_,
        StakeVaultParams calldata params
    )
        external
        onlyRole(Roles.SEQUENCER_ROLE)
        nonReentrant
        sequencerEnabled
    {
        _validateOpNonce(opNonce);
        _validateSeqNum(seqNum_);

        if (seqNonceUsed[params.staker][params.nonce]) {
            revert Errors.Obsdn_SeqNonceUsed(params.staker, params.nonce);
        }
        seqNonceUsed[params.staker][params.nonce] = true;

        try VaultModule.stake(IObsdn(address(this)), params) returns (uint256 shares) {
            emit StakeVault(
                params.vault,
                params.staker,
                params.nonce,
                params.token,
                params.amountX18,
                shares,
                OpStatus.Success,
                seqNum_
            );
        } catch {
            emit StakeVault(
                params.vault, params.staker, params.nonce, params.token, params.amountX18, 0, OpStatus.Failure, seqNum_
            );
        }
    }

    /// @inheritdoc IObsdn
    function unstakeVault(
        uint64 opNonce,
        uint256 seqNum_,
        UnstakeVaultParams calldata params
    )
        external
        onlyRole(Roles.SEQUENCER_ROLE)
        nonReentrant
        sequencerEnabled
    {
        _validateOpNonce(opNonce);
        _validateSeqNum(seqNum_);

        if (seqNonceUsed[params.staker][params.nonce]) {
            revert Errors.Obsdn_SeqNonceUsed(params.staker, params.nonce);
        }
        seqNonceUsed[params.staker][params.nonce] = true;

        try VaultModule.unstake(IObsdn(address(this)), params) returns (
            uint256 amountUnstakedX18, uint256 shares, uint256 feeX18, address feeRecipient
        ) {
            emit UnstakeVault(
                params.vault,
                params.staker,
                params.nonce,
                params.token,
                amountUnstakedX18,
                shares,
                feeX18,
                feeRecipient,
                OpStatus.Success,
                seqNum_
            );
        } catch {
            emit UnstakeVault(
                params.vault,
                params.staker,
                params.nonce,
                params.token,
                params.amountX18,
                0,
                0,
                address(0),
                OpStatus.Failure,
                seqNum_
            );
        }
    }

    /// @inheritdoc IObsdn
    function registerChildAccountSigner(
        uint64 opNonce,
        uint256,
        /* seqNum */
        RegisterChildAccountSignerParams calldata params
    )
        external
        onlyRole(Roles.SEQUENCER_ROLE)
        nonReentrant
        sequencerEnabled
    {
        _validateOpNonce(opNonce);

        if (signerRegNonceUsed[params.main][params.nonce]) {
            revert Errors.Obsdn_SignerRegNonceUsed(params.main, params.nonce);
        }
        signerRegNonceUsed[params.main][params.nonce] = true;

        AccountModule.registerChildAccountSigner(IObsdn(address(this)), signerWallets, params);
    }

    // ══════════════════════════════════════════════════════════════════════════
    //                             VIEW FUNCTIONS
    // ══════════════════════════════════════════════════════════════════════════

    /// @inheritdoc IObsdn
    function hashTypedDataV4(bytes32 structHash) external view returns (bytes32) {
        return _hashTypedDataV4(structHash);
    }

    /// @inheritdoc IObsdn
    function balanceOf(address account, address token) external view returns (int256) {
        return spotLedger.getBalance(account, token);
    }

    /// @inheritdoc IObsdn
    function isRegisteredSigner(address sender, address signer) external view returns (bool) {
        return signerWallets[sender][signer];
    }

    /// @inheritdoc IObsdn
    function isSeqNonceUsed(address account, uint64 nonce) external view returns (bool) {
        return seqNonceUsed[account][nonce];
    }

    /// @inheritdoc IObsdn
    function isSignerRegNonceUsed(address account, uint64 nonce) external view returns (bool) {
        return signerRegNonceUsed[account][nonce];
    }

    /// @inheritdoc IObsdn
    function getCollateralTokens() external view returns (address[] memory tokens) {
        uint256 length = collateralTokens.length();
        tokens = new address[](length);
        for (uint256 index = 0; index < length; index++) {
            tokens[index] = collateralTokens.at(index);
        }
    }

    /// @inheritdoc IObsdn
    function isCollateralToken(address token) public view returns (bool) {
        return collateralTokens.contains(token);
    }

    /// @inheritdoc IObsdn
    function getAccountType(address account) external view returns (AccountType) {
        return accounts[account].accountType;
    }

    /// @inheritdoc IObsdn
    function getSignerWallet(address account, address signer) external view returns (bool) {
        return signerWallets[account][signer];
    }

    /// @inheritdoc IObsdn
    function getAccountVaults(address account) external view returns (address[] memory) {
        return accounts[account].vaults;
    }

    /// @inheritdoc IObsdn
    function getAccountSubaccounts(address account) external view returns (address[] memory) {
        return accounts[account].subaccounts;
    }

    /// @inheritdoc IObsdn
    function getAccountMain(address account) external view returns (address) {
        return accounts[account].main;
    }

    /// @inheritdoc IObsdn
    function getSpotLedger() external view returns (ISpotLedger) {
        return spotLedger;
    }

    /// @inheritdoc IObsdn
    function getPerpLedger() external view returns (IPerpLedger) {
        return perpLedger;
    }

    /// @inheritdoc IObsdn
    function getMatching() external view returns (IMatching) {
        return matching;
    }

    /// @inheritdoc IObsdn
    function getVaultManager() external view returns (IVaultManager) {
        return vaultManager;
    }

    /// @inheritdoc IObsdn
    function getSigValidator() external view returns (ISigValidator) {
        return sigValidator;
    }

    /// @inheritdoc IObsdn
function getQuoteToken() external view returns (address) {
        return quoteToken;
    }

    /// @inheritdoc IObsdn
    function getProtocolFeeRecipient() external view returns (address) {
        return protocolFeeRecipient;
    }
}