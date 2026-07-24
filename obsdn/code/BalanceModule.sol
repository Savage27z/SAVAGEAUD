// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IObsdn } from "../../interfaces/IObsdn.sol";
import { ISpotLedger } from "../../interfaces/ISpotLedger.sol";
import { ISigValidator } from "../../interfaces/ISigValidator.sol";
import { Errors } from "../Errors.sol";
import { Math } from "../Math.sol";

library BalanceModule {
    using SafeERC20 for IERC20;
    using Math for uint128;
    using Math for uint256;
    using Math for int256;

    bytes32 public constant WITHDRAW_TYPEHASH = keccak256("Withdraw(address sender,address token,uint128 amount,uint64 nonce)");
    bytes32 public constant TRANSFER_TYPEHASH = keccak256("Transfer(address from,address to,address token,uint128 amount,uint64 nonce)");

    function withdraw(IObsdn obsdn, IObsdn.WithdrawParams calldata params) external {
        ISpotLedger spotLedger = obsdn.getSpotLedger();
        ISigValidator sigValidator = obsdn.getSigValidator();
        if (obsdn.getAccountType(params.sender) != IObsdn.AccountType.Main) revert Errors.Obsdn_NotMainAccount(params.sender);
        if (!obsdn.isCollateralToken(params.token)) revert Errors.Obsdn_InvalidCollateralToken(params.token);

        bytes32 digest = obsdn.hashTypedDataV4(keccak256(abi.encode(WITHDRAW_TYPEHASH, params.sender, params.token, params.amount, params.nonce)));
        if (!sigValidator.isValidSig(params.sender, digest, params.signature)) revert Errors.InvalidSig(params.sender);
        if (params.sequencerFee > _maxWithdrawalFee()) revert Errors.Obsdn_MaxWithdrawalFeeExceeded();

        int256 accountBalanceBefore = spotLedger.getBalance(params.sender, params.token);
        if (accountBalanceBefore < params.amount.safeInt256()) revert Errors.Obsdn_AccountInsufficientBalance(params.sender, params.token, accountBalanceBefore, params.amount);

        uint256 netAmount = params.amount - params.sequencerFee;
        spotLedger.collectSequencerFee(params.sender, params.token, params.sequencerFee);
        spotLedger.withdraw(params.sender, params.token, netAmount);
        int256 accountBalanceAfter = spotLedger.getBalance(params.sender, params.token);
        assert(accountBalanceBefore - accountBalanceAfter == params.amount.safeInt256());

        uint256 transferAmount = netAmount.unscale(params.token);
        uint256 exchangeBalanceBefore = IERC20(params.token).balanceOf(address(this));
        IERC20(params.token).safeTransfer(params.sender, transferAmount);
        uint256 exchangeBalanceAfter = IERC20(params.token).balanceOf(address(this));
        assert(exchangeBalanceBefore - exchangeBalanceAfter == transferAmount);

        if (params.doAssert && accountBalanceAfter < params.minBalanceAfter)
            revert Errors.Obsdn_BalanceBelowMinimum(params.sender, params.token, accountBalanceAfter, params.minBalanceAfter);
    }

    function _maxWithdrawalFee() internal pure returns (uint128 _amountX18) { return 1e18; }

    function transfer(IObsdn obsdn, IObsdn.TransferParams calldata params) external {
        ISpotLedger spotLedger = obsdn.getSpotLedger();
        ISigValidator sigValidator = obsdn.getSigValidator();
        _validateTransfer(obsdn, params.from, params.to);
        if (!obsdn.isCollateralToken(params.token)) revert Errors.Obsdn_InvalidCollateralToken(params.token);
        address signer = obsdn.getAccountType(params.from) == IObsdn.AccountType.Subaccount ? obsdn.getAccountMain(params.from) : params.from;
        bytes32 digest = obsdn.hashTypedDataV4(keccak256(abi.encode(TRANSFER_TYPEHASH, params.from, params.to, params.token, params.amount, params.nonce)));
        if (!sigValidator.isValidSig(signer, digest, params.signature)) revert Errors.InvalidSig(signer);
        int256 fromBalance = spotLedger.getBalance(params.from, params.token);
        if (fromBalance < params.amount.safeInt256()) revert Errors.Obsdn_AccountInsufficientBalance(params.from, params.token, fromBalance, params.amount);
        spotLedger.transfer(params.from, params.to, params.token, params.amount);
    }

    function _validateTransfer(IObsdn obsdn, address from, address to) private view {
        if (from == to) revert Errors.Obsdn_Transfer_SameAccount(from);
        IObsdn.AccountType fromType = obsdn.getAccountType(from);
        IObsdn.AccountType toType = obsdn.getAccountType(to);
        if (fromType == IObsdn.AccountType.Vault) revert Errors.Obsdn_Transfer_VaultNotAllowed(from);
        if (toType == IObsdn.AccountType.Vault) revert Errors.Obsdn_Transfer_VaultNotAllowed(to);
        address fromMain = fromType == IObsdn.AccountType.Subaccount ? obsdn.getAccountMain(from) : from;
        address toMain = toType == IObsdn.AccountType.Subaccount ? obsdn.getAccountMain(to) : to;
        if (fromMain != toMain) revert Errors.Obsdn_Transfer_NotSameMain(from, to);
    }

    function deposit(IObsdn obsdn, address recipient, address token, uint256 amountX18) external {
        ISpotLedger spotLedger = obsdn.getSpotLedger();
        if (obsdn.getAccountType(recipient) != IObsdn.AccountType.Main) revert Errors.Obsdn_NotMainAccount(recipient);
        if (amountX18 == 0) revert Errors.ZeroAmount();
        (uint256 flooredAmount, uint256 rawAmount) = amountX18.floorAndUnscale(token);
        if (flooredAmount == 0 || rawAmount == 0) revert Errors.ZeroAmount();
        if (flooredAmount != amountX18) revert Errors.Obsdn_InvalidAmountX18();
        uint256 balanceBefore = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransferFrom(msg.sender, address(this), rawAmount);
        uint256 balanceAfter = IERC20(token).balanceOf(address(this));
        assert(balanceAfter - balanceBefore == rawAmount);
        spotLedger.deposit(recipient, token, amountX18);
        emit IObsdn.Deposit(recipient, token, amountX18);
    }

    function depositInsuranceFund(IObsdn obsdn, address token, uint256 amountX18) external {
        ISpotLedger spotLedger = obsdn.getSpotLedger();
        if (amountX18 == 0) revert Errors.ZeroAmount();
        (uint256 flooredAmount, uint256 rawAmount) = amountX18.floorAndUnscale(token);
        if (flooredAmount == 0 || rawAmount == 0) revert Errors.ZeroAmount();
        if (flooredAmount != amountX18) revert Errors.Obsdn_InvalidAmountX18();
        uint256 balanceBefore = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransferFrom(msg.sender, address(this), rawAmount);
        uint256 balanceAfter = IERC20(token).balanceOf(address(this));
        assert(balanceAfter - balanceBefore == rawAmount);
        spotLedger.depositInsuranceFund(token, amountX18);
        emit IObsdn.DepositInsuranceFund(msg.sender, token, amountX18);
    }

    function depositMakerRebatePayer(IObsdn obsdn, address token, uint256 amountX18) external {
        ISpotLedger spotLedger = obsdn.getSpotLedger();
        if (amountX18 == 0) revert Errors.ZeroAmount();
        (uint256 flooredAmount, uint256 rawAmount) = amountX18.floorAndUnscale(token);
        if (flooredAmount == 0 || rawAmount == 0) revert Errors.ZeroAmount();
        if (flooredAmount != amountX18) revert Errors.Obsdn_InvalidAmountX18();
        uint256 balanceBefore = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransferFrom(msg.sender, address(this), rawAmount);
        uint256 balanceAfter = IERC20(token).balanceOf(address(this));
        assert(balanceAfter - balanceBefore == rawAmount);
        spotLedger.depositMakerRebatePayer(token, amountX18);
        emit IObsdn.DepositMakerRebatePayer(msg.sender, token, amountX18);
    }
}