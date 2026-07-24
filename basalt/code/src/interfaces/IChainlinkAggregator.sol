// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

interface IChainlinkAggregator {
    function latestRoundData()
        external
        view
        returns (uint80, int256, uint256, uint256, uint80);
}
