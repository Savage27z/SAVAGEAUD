// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { IMatching } from "./interfaces/IMatching.sol";
import { ISpotLedger } from "./interfaces/ISpotLedger.sol";
import { IPerpLedger } from "./interfaces/IPerpLedger.sol";
import { Errors } from "./libraries/Errors.sol";
import { FeeRates } from "./libraries/FeeRates.sol";
import { Math } from "./libraries/Math.sol";

contract Matching is IMatching, Initializable {
    using Math for int128;
    using Math for uint128;

    uint16 internal constant ONE_HUNDRED_PERCENT = 10_000;

    address public obsdn;
    ISpotLedger public spotLedger;
    IPerpLedger public perpLedger;
    address public quoteToken;

    mapping(bytes32 orderHash => uint128 filledAmount) public filledAmounts;
    mapping(address account => mapping(bytes32 orderHash => bool isFulfilled)) public isOrderFulfilled;
    mapping(bytes32 orderHashPair => bool isMatched) public matchedOrderPairs;

    constructor() { _disableInitializers(); }

    function initialize(address _obsdn, address _spotLedger, address _perpLedger, address _quoteToken) public initializer {
        if (_obsdn == address(0) || _spotLedger == address(0) || _perpLedger == address(0) || _quoteToken == address(0))
            revert Errors.ZeroAddress();
        obsdn = _obsdn;
        spotLedger = ISpotLedger(_spotLedger);
        perpLedger = IPerpLedger(_perpLedger);
        quoteToken = _quoteToken;
    }

    modifier onlyObsdn() { if (msg.sender != obsdn) revert Errors.Unauthorized(); _; }

    function matchOrders(
        Order memory maker, Order memory taker, uint128 matchSize,
        Fees memory fees, Referrals memory referrals, MatchExpectations memory expectations
    ) external onlyObsdn {
        _validateOrders(maker, taker);
        _validateMatchSize(maker, taker, matchSize);
        _validateMatchId(maker.orderHash, taker.orderHash);

        uint128 matchPrice = maker.price;
        uint128 matchQuoteSize = matchPrice.mulX18(matchSize);

        _validateTradingFee(fees.maker, matchQuoteSize);
        _validateTradingFee(fees.taker.safeInt128(), matchQuoteSize);
        _validateSequencerFee(fees.sequencer);
        if (fees.liquidation > 0) _validateLiquidationFee(fees.liquidation, matchQuoteSize);
        _validateReferrals(fees, referrals);

        if (fees.maker < 0) {
            spotLedger.payMakerRebate(maker.sender, quoteToken, fees.maker.abs());
            fees.maker = 0;
        }
        _collectFees(maker.sender, taker.sender, fees);
        _payTradingReferrals(referrals);
        _fillOrder(maker, matchSize);
        _fillOrder(taker, matchSize);

        uint16 marketIndex = maker.marketIndex;
        Amounts memory newMakerPosition = _settleQuoteBalance(marketIndex, maker.sender, maker.side, matchSize.safeInt128(), matchQuoteSize.safeInt128(), matchPrice);
        Amounts memory newTakerPosition = _settleQuoteBalance(marketIndex, taker.sender, taker.side, matchSize.safeInt128(), matchQuoteSize.safeInt128(), matchPrice);
        _updatePerpPositions(marketIndex, maker.sender, taker.sender, newMakerPosition, newTakerPosition);

        emit OrdersMatched(marketIndex, maker.sender, taker.sender, maker.side, maker.nonce, taker.nonce, matchSize, matchPrice);
        emit OrdersMatchedFees(marketIndex, maker.nonce, taker.nonce, fees);
        if (referrals.makerReferrer != address(0) || referrals.takerReferrer != address(0))
            emit OrdersMatchedReferrals(marketIndex, maker.nonce, taker.nonce, referrals);
        _assertMatchExpectations(maker, taker, marketIndex, expectations);
    }

    function hashOrderPair(bytes32 makerOrderHash, bytes32 takerOrderHash) public pure returns (bytes32 result) {
        assembly { mstore(0x00, makerOrderHash); mstore(0x20, takerOrderHash); result := keccak256(0x00, 0x40) }
    }

    function isMatched(bytes32 makerOrderHash, bytes32 takerOrderHash) external view returns (bool) {
        return matchedOrderPairs[hashOrderPair(makerOrderHash, takerOrderHash)];
    }

    // ── Internal ──

    function _settleQuoteBalance(uint16 marketIndex, address account, OrderSide side, int128 matchSize, int128 matchQuoteSize, uint128 matchPrice)
        internal returns (Amounts memory newPosition)
    {
        IPerpLedger.Position memory position = perpLedger.getPosition(account, marketIndex);
        if (side == OrderSide.SELL) { matchSize = -matchSize; matchQuoteSize = -matchQuoteSize; }

        int128 newSize = position.size + matchSize;
        int128 amountToSettle;
        int128 newQuote;

        // Case 1: Position flip (sign change)
        if ((position.size > 0 && newSize < 0) || (position.size < 0 && newSize > 0)) {
            int128 closeAmount = position.quoteBalance + position.size.mulX18(matchPrice.safeInt128());
            amountToSettle = closeAmount;
            newQuote = -newSize.mulX18(matchPrice.safeInt128());
        }
        // Case 2: Position increase
        else if (position.size.abs() < newSize.abs()) {
            newQuote = position.quoteBalance - matchQuoteSize;
            amountToSettle = 0;
        }
        // Case 3: Position full close
        else if (newSize == 0) {
            newQuote = position.quoteBalance - matchQuoteSize;
            amountToSettle = newQuote;
            newQuote = 0;
        }
        // Case 4: Position partial close
        else if (position.size.abs() > newSize.abs()) {
            int128 cost = Math.mulDiv(-matchSize, position.quoteBalance, position.size);
            amountToSettle = cost - matchQuoteSize;
            newQuote = position.quoteBalance - cost;
        } else revert Errors.Matching_InvalidSettlementState();

        spotLedger.settleQuoteBalance(account, quoteToken, amountToSettle);
        return Amounts({ baseAmount: newSize, quoteAmount: newQuote });
    }

    function _fillOrder(Order memory order, uint128 matchSize) internal {
        filledAmounts[order.orderHash] += matchSize;
        if (filledAmounts[order.orderHash] == order.size)
            isOrderFulfilled[order.sender][order.orderHash] = true;
    }

    function _payTradingReferrals(Referrals memory referrals) internal {
        if (referrals.makerReferrer != address(0) && referrals.makerReferralRebate > 0)
            spotLedger.payTradingReferral(referrals.makerReferrer, quoteToken, referrals.makerReferralRebate);
        if (referrals.takerReferrer != address(0) && referrals.takerReferralRebate > 0)
            spotLedger.payTradingReferral(referrals.takerReferrer, quoteToken, referrals.takerReferralRebate);
    }

    function _collectFees(address maker, address taker, Fees memory fees) internal {
        spotLedger.collectTradingFee(maker, quoteToken, fees.maker.safeUInt128());
        spotLedger.collectTradingFee(taker, quoteToken, fees.taker);
        spotLedger.collectSequencerFee(taker, quoteToken, fees.sequencer);
        if (fees.liquidation > 0) spotLedger.collectLiquidationFee(taker, quoteToken, fees.liquidation);
    }

    function _validateOrders(Order memory maker, Order memory taker) internal view {
        if (maker.marketIndex != taker.marketIndex) revert Errors.Matching_MarketIndexMismatch();
        if (maker.side == taker.side) revert Errors.Matching_SameSides();
        if (maker.sender == taker.sender) revert Errors.Matching_SelfTrade();
        if (isOrderFulfilled[maker.sender][maker.orderHash]) revert Errors.Matching_OrderFulfilled(maker.sender, maker.orderHash);
        if (isOrderFulfilled[taker.sender][taker.orderHash]) revert Errors.Matching_OrderFulfilled(taker.sender, taker.orderHash);
        if ((maker.side == OrderSide.BUY && maker.price < taker.price) || (maker.side == OrderSide.SELL && maker.price > taker.price))
            revert Errors.Matching_InvalidOrderPrice();
    }

    function _validateMatchId(bytes32 maker, bytes32 taker) internal {
        bytes32 matchId = hashOrderPair(maker, taker);
        if (matchedOrderPairs[matchId]) revert Errors.Matching_OrderPairAlreadyMatched();
        matchedOrderPairs[matchId] = true;
    }

    function _validateMatchSize(Order memory maker, Order memory taker, uint128 matchSize) internal view {
        uint128 makerRemainingSize = maker.size - filledAmounts[maker.orderHash];
        uint128 takerRemainingSize = taker.size - filledAmounts[taker.orderHash];
        if (matchSize == 0 || matchSize > makerRemainingSize || matchSize > takerRemainingSize)
            revert Errors.Matching_InvalidMatchSize();
    }

    function _validateReferrals(Fees memory fees, Referrals memory referrals) internal pure {
        if (fees.maker > 0) {
            uint128 maxMakerReferralRebate = _calculatePercentage(fees.maker.safeUInt128(), FeeRates.MAX_REF_REBATE_RATE);
            if (referrals.makerReferralRebate > maxMakerReferralRebate) revert Errors.Matching_MaxRebateExceeded();
        } else if (referrals.makerReferralRebate > 0) revert Errors.Matching_MaxRebateExceeded();
        uint128 maxTakerReferralRebate = _calculatePercentage(fees.taker, FeeRates.MAX_REF_REBATE_RATE);
        if (referrals.takerReferralRebate > maxTakerReferralRebate) revert Errors.Matching_MaxRebateExceeded();
    }

    function _validateTradingFee(int128 fee, uint128 matchQuoteSize) internal pure {
        uint128 maxTradingFee = _calculatePercentage(matchQuoteSize, FeeRates.MAX_TRADING_FEE_RATE);
        if (fee > maxTradingFee.safeInt128()) revert Errors.Matching_MaxTradingFeeExceeded();
    }

    function _validateSequencerFee(uint128 fee) internal pure {
        if (fee > FeeRates.MAX_TAKER_SEQUENCER_FEE_USD) revert Errors.Matching_MaxSequencerFeeExceeded();
    }

    function _validateLiquidationFee(uint128 fee, uint128 matchQuoteSize) internal pure {
        uint128 maxLiquidationFee = _calculatePercentage(matchQuoteSize, FeeRates.MAX_LIQUIDATION_FEE_RATE);
        if (fee > maxLiquidationFee) revert Errors.Matching_MaxLiquidationFeeExceeded();
    }

    function _calculatePercentage(uint128 amount, uint16 percentage) internal pure returns (uint128) {
        return (amount * percentage) / ONE_HUNDRED_PERCENT;
    }

    function _assertMatchExpectations(Order memory maker, Order memory taker, uint16 marketIndex, MatchExpectations memory expectations) internal view {
        if (expectations.doAssertMaker) {
            IPerpLedger.Position memory makerPos = perpLedger.getPosition(maker.sender, marketIndex);
            if (makerPos.size != expectations.makerPosSize) revert Errors.Matching_ExpectationFailed();
            if (makerPos.quoteBalance != expectations.makerPosQuoteBalance) revert Errors.Matching_ExpectationFailed();
            if (filledAmounts[maker.orderHash] != expectations.makerOrderFilledAmount) revert Errors.Matching_ExpectationFailed();
            if (spotLedger.getBalance(maker.sender, quoteToken) < expectations.makerMinQuoteBalanceAfter) revert Errors.Matching_ExpectationFailed();
        }
        if (expectations.doAssertTaker) {
            IPerpLedger.Position memory takerPos = perpLedger.getPosition(taker.sender, marketIndex);
            if (takerPos.size != expectations.takerPosSize) revert Errors.Matching_ExpectationFailed();
            if (takerPos.quoteBalance != expectations.takerPosQuoteBalance) revert Errors.Matching_ExpectationFailed();
            if (filledAmounts[taker.orderHash] != expectations.takerOrderFilledAmount) revert Errors.Matching_ExpectationFailed();
            if (spotLedger.getBalance(taker.sender, quoteToken) < expectations.takerMinQuoteBalanceAfter) revert Errors.Matching_ExpectationFailed();
        }
    }

    function _updatePerpPositions(uint16 marketIndex, address maker, address taker, Amounts memory newMakerPosition, Amounts memory newTakerPosition) internal {
        IPerpLedger.PositionUpdate[] memory updates = new IPerpLedger.PositionUpdate[](2);
        updates[0] = IPerpLedger.PositionUpdate({ account: maker, marketIndex: marketIndex, newSize: newMakerPosition.baseAmount, newQuoteBalance: newMakerPosition.quoteAmount });
        updates[1] = IPerpLedger.PositionUpdate({ account: taker, marketIndex: marketIndex, newSize: newTakerPosition.baseAmount, newQuoteBalance: newTakerPosition.quoteAmount });
        perpLedger.updatePositions(updates);
    }
}