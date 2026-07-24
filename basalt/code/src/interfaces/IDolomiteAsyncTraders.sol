// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// Mirror of IUpgradeableAsyncIsolationModeUnwrapperTrader.sol@d9d16e7. Field order critical.
interface IUpgradeableAsyncIsolationModeUnwrapperTrader {
    struct WithdrawalInfo {
        bytes32 key;
        address vault;
        uint256 accountNumber;
        uint256 inputAmount;
        address outputToken;
        uint256 outputAmount;
        bool    isRetryable;
        bool    isLiquidation;
        bytes   extraData;
    }
    function getWithdrawalInfo(bytes32 _key) external view returns (WithdrawalInfo memory);
}

// Mirror of IUpgradeableAsyncIsolationModeWrapperTrader.sol@d9d16e7.
interface IUpgradeableAsyncIsolationModeWrapperTrader {
    struct DepositInfo {
        bytes32 key;
        address vault;
        uint256 accountNumber;
        address inputToken;
        uint256 inputAmount;
        uint256 outputAmount;
        bool    isRetryable;
    }
    function getDepositInfo(bytes32 _key) external view returns (DepositInfo memory);
}

// Runtime wrapper/unwrapper lookup — Dolomite rotates per-token traders.
interface IGmxV2Registry {
    function getUnwrapperByToken(address factory) external view returns (address);
    function getWrapperByToken(address factory) external view returns (address);
}
