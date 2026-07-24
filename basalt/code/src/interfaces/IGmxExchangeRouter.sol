// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

interface IGmxExchangeRouter {
    struct CreateDepositParamsAddresses {
        address receiver;
        address callbackContract;
        address uiFeeReceiver;
        address market;
        address initialLongToken;
        address initialShortToken;
        address[] longTokenSwapPath;
        address[] shortTokenSwapPath;
    }

    struct CreateDepositParams {
        CreateDepositParamsAddresses addresses;
        uint256 minMarketTokens;
        bool shouldUnwrapNativeToken;
        uint256 executionFee;
        uint256 callbackGasLimit;
        bytes32[] dataList;
    }

    function sendWnt(address receiver, uint256 amount) external payable;

    function sendTokens(
        address token,
        address receiver,
        uint256 amount
    ) external payable;

    function createDeposit(
        CreateDepositParams calldata params
    ) external payable returns (bytes32);

    function cancelDeposit(bytes32 key) external payable;

    // ── Withdrawal side ─────────────────────────────────────────────────

    // Sub-struct must be NESTED to match v2.2 ABI; flat layout breaks selector.
    struct CreateWithdrawalParamsAddresses {
        address receiver;
        address callbackContract;
        address uiFeeReceiver;
        address market;
        address[] longTokenSwapPath;
        address[] shortTokenSwapPath;
    }

    struct CreateWithdrawalParams {
        CreateWithdrawalParamsAddresses addresses;
        uint256 minLongTokenAmount;
        uint256 minShortTokenAmount;
        bool shouldUnwrapNativeToken;
        uint256 executionFee;
        uint256 callbackGasLimit;
        bytes32[] dataList;
    }

    function createWithdrawal(
        CreateWithdrawalParams calldata params
    ) external payable returns (bytes32);

    function cancelWithdrawal(bytes32 key) external payable;

    function multicall(
        bytes[] calldata data
    ) external payable returns (bytes[] memory results);
}
