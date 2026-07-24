// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IChainlinkAggregator} from "../interfaces/IChainlinkAggregator.sol";
import {BasaltConstants} from "./BasaltConstants.sol";

library OracleGuard {

    error OracleStalePrice(address oracle, uint256 updatedAt, uint256 maxAge);
    error OracleNonPositivePrice(address oracle, int256 price);
    error OraclePriceTooHigh(address oracle, uint256 price, uint256 maxPrice);
    error OracleIncompleteRound(address oracle, uint80 roundId, uint80 answeredInRound);
    error SequencerDown();
    error SequencerGracePeriod(uint256 timeSinceUp);

    uint256 internal constant WBTC_MAX_AGE = BasaltConstants.ORACLE_WBTC_MAX_AGE;
    uint256 internal constant USDC_MAX_AGE = BasaltConstants.ORACLE_USDC_MAX_AGE;
    uint256 internal constant SEQUENCER_GRACE_PERIOD = BasaltConstants.ORACLE_SEQUENCER_GRACE_PERIOD;
    uint256 internal constant CL_TO_GMX = BasaltConstants.ORACLE_CL_TO_GMX;
    uint256 internal constant WBTC_MAX_PRICE_E8 = BasaltConstants.ORACLE_WBTC_MAX_PRICE_E8;
    uint256 internal constant USDC_MAX_PRICE_E8 = BasaltConstants.ORACLE_USDC_MAX_PRICE_E8;

    // Validates staleness, positivity, hard ceiling.
    function readChainlinkPrice(
        IChainlinkAggregator oracle,
        uint256 maxAge,
        uint256 maxPrice
    ) internal view returns (uint256) {
        (uint80 roundId, int256 answer,, uint256 updatedAt, uint80 answeredInRound) = oracle.latestRoundData();
        if (answeredInRound < roundId) revert OracleIncompleteRound(address(oracle), roundId, answeredInRound);
        if (answer <= 0) revert OracleNonPositivePrice(address(oracle), answer);
        if (block.timestamp - updatedAt > maxAge) {
            revert OracleStalePrice(address(oracle), updatedAt, maxAge);
        }
        if (uint256(answer) > maxPrice) {
            revert OraclePriceTooHigh(address(oracle), uint256(answer), maxPrice);
        }
        return uint256(answer);
    }

    // Revert if Arbitrum sequencer is down or in grace period.
    function requireSequencerUp(IChainlinkAggregator sequencerOracle) internal view {
        // L2 sequencer: startedAt = last status change.
        (, int256 answer, uint256 startedAt,,) = sequencerOracle.latestRoundData();
        if (answer != 0) revert SequencerDown();
        if (startedAt == 0) revert SequencerDown();
        if (block.timestamp - startedAt <= SEQUENCER_GRACE_PERIOD) {
            revert SequencerGracePeriod(block.timestamp - startedAt);
        }
    }
}
