// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { IObsdn } from "../../interfaces/IObsdn.sol";
import { IMatching } from "../../interfaces/IMatching.sol";
import { ISigValidator } from "../../interfaces/ISigValidator.sol";
import { Errors } from "../Errors.sol";

library OrderModule {
    bytes32 public constant ORDER_TYPEHASH =
        keccak256("Order(address sender,uint16 marketIndex,uint8 side,uint128 size,uint128 price,uint64 nonce)");

    function matchOrders(IObsdn obsdn, IObsdn.MatchOrdersParams memory params) external {
        _validateSystemOrderFlags(params.maker);
        _validateSystemOrderFlags(params.taker);
        if (params.maker.isLiquidation) revert Errors.Matching_MakerCannotBeLiquidation();
        if (params.taker.isAdl) revert Errors.Matching_TakerCannotBeAdl();

        bool makerSigCheck = !(params.maker.isAdl || params.maker.isForceClosed);
        bool takerSigCheck = !(params.taker.isLiquidation || params.taker.isForceClosed);
        ISigValidator sigValidator = obsdn.getSigValidator();

        params.maker.orderHash = _getOrderDigest(obsdn.hashTypedDataV4, params.maker);
        if (makerSigCheck) _validateSignature(sigValidator, obsdn, params.maker);

        params.taker.orderHash = _getOrderDigest(obsdn.hashTypedDataV4, params.taker);
        if (takerSigCheck) _validateSignature(sigValidator, obsdn, params.taker);

        IMatching matching = obsdn.getMatching();
        matching.matchOrders(params.maker, params.taker, params.matchSize, params.fees, params.referrals, params.expectations);

        emit IObsdn.MatchOrders(params.maker.marketIndex, params.maker.sender, params.taker.sender, params.maker.nonce, params.taker.nonce);
    }

    function _validateSystemOrderFlags(IMatching.Order memory order) private pure {
        uint256 count;
        if (order.isAdl) ++count;
        if (order.isLiquidation) ++count;
        if (order.isForceClosed) ++count;
        if (count > 1) revert Errors.Matching_MutuallyExclusiveSystemOrderFlags();
    }

    function _validateSignature(ISigValidator sigValidator, IObsdn obsdn, IMatching.Order memory order) private view {
        if (!sigValidator.isValidSig(order.signer, order.orderHash, order.signature)) revert Errors.InvalidSig(order.signer);
        if (!obsdn.getSignerWallet(order.sender, order.signer)) revert Errors.Obsdn_UnauthorizedSigner(order.sender, order.signer);
    }

    function _getOrderDigest(function(bytes32) external view returns (bytes32) _hashTypedDataV4, IMatching.Order memory order)
        internal view returns (bytes32)
    {
        return _hashTypedDataV4(keccak256(abi.encode(ORDER_TYPEHASH, order.sender, order.marketIndex, order.side, order.size, order.price, order.nonce)));
    }
}