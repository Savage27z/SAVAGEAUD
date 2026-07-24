// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IndexVault} from "./IndexVault.sol";

/// @title IndexFactory — permissionless creatie van nieuwe index-vaults
/// @notice Iedereen kan een nieuwe index samenstellen uit willekeurige ERC-20's
///         (stock tokens, ETF-tokens, ...) met dezelfde rug-proof garanties:
///         immutable basket, gecapte fees, in-kind mint/redeem. De factory houdt
///         een on-chain register bij zodat frontends alle indexen kunnen tonen.
contract IndexFactory {
    address[] public allIndexes;

    event IndexCreated(
        address indexed vault, address indexed creator, string name, string symbol, address[] components
    );

    function indexCount() external view returns (uint256) {
        return allIndexes.length;
    }

    function getAllIndexes() external view returns (address[] memory) {
        return allIndexes;
    }

    /// @notice Deploy een nieuwe IndexVault. De caller wordt owner (fee-beheer
    ///         binnen caps + feeCollector-keuze); de basket ligt daarna voor
    ///         altijd vast.
    function createIndex(
        string memory name,
        string memory symbol,
        address[] memory components,
        uint256[] memory unitsPerShare,
        uint16 mintFeeBps,
        uint16 redeemFeeBps,
        uint16 streamingFeeBps,
        address feeCollector
    ) external returns (address vault) {
        vault = address(
            new IndexVault(
                name, symbol, components, unitsPerShare, mintFeeBps, redeemFeeBps, streamingFeeBps, feeCollector, msg.sender
            )
        );
        allIndexes.push(vault);
        emit IndexCreated(vault, msg.sender, name, symbol, components);
    }
}