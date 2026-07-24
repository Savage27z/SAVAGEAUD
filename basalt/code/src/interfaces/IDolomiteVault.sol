// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// Dolomite GmxV2IsolationModeTokenVaultV1.
// https://github.com/dolomite-exchange/dolomite-margin-modules/blob/d9d16e7/packages/gmx-v2/contracts/GmxV2IsolationModeTokenVaultV1.sol
interface IDolomiteIsolationVault {
    // Deposit GM, credits dGM on account 0.
    // https://github.com/dolomite-exchange/dolomite-margin-modules/blob/d9d16e7/packages/base/contracts/isolation-mode/abstract/IsolationModeTokenVaultV1.sol#L128
    function depositIntoVaultForDolomiteMargin(uint256 toAccountNumber, uint256 amountWei) external;

    // Open borrow position; first-time dGM move from account 0.
    // https://github.com/dolomite-exchange/dolomite-margin-modules/blob/d9d16e7/packages/gmx-v2/contracts/GmxV2IsolationModeTokenVaultV1.sol#L125
    function openBorrowPosition(
        uint256 fromAccountNumber,
        uint256 toAccountNumber,
        uint256 amountWei
    ) external payable;

    // Subsequent dGM move from account 0 to position.
    // https://github.com/dolomite-exchange/dolomite-margin-modules/blob/d9d16e7/packages/gmx-v2/contracts/GmxV2IsolationModeTokenVaultV1.sol#L158
    function transferIntoPositionWithUnderlyingToken(
        uint256 fromAccountNumber,
        uint256 toAccountNumber,
        uint256 amountWei
    ) external;

    // Borrow + wrap via IsolationModeWrapper (async).
    // https://github.com/dolomite-exchange/dolomite-margin-modules/blob/d9d16e7/packages/gmx-v2/contracts/GmxV2IsolationModeTokenVaultV1.sol#L229
    function swapExactInputForOutput(
        uint256 tradeAccountNumber,
        uint256[] calldata marketIdsPath,
        uint256 inputAmountWei,
        uint256 minOutputAmountWei,
        TraderParam[] calldata tradersPath,
        Account[] calldata makerAccounts,
        UserConfig calldata userConfig
    ) external payable;

    // Transfer dGM from borrow position back to account 0.
    function transferFromPositionWithUnderlyingToken(
        uint256 borrowAccountNumber,
        uint256 toAccountNumber,
        uint256 amountWei
    ) external;

    // Async unwrap GM → output (vault-owner only).
    // https://github.com/dolomite-exchange/dolomite-margin-modules/blob/d9d16e7/packages/base/contracts/isolation-mode/interfaces/IIsolationModeTokenVaultV1WithAsyncFreezable.sol#L48
    function initiateUnwrapping(
        uint256 tradeAccountNumber,
        uint256 inputAmount,
        address outputToken,
        uint256 minOutputAmount,
        bytes calldata extraData
    ) external payable;

    // Withdraw GM from vault back to owner.
    function withdrawFromVaultForDolomiteMargin(uint256 fromAccountNumber, uint256 amountWei) external;

    // Deposit non-underlying token (WBTC) into borrow position.
    // https://github.com/dolomite-exchange/dolomite-margin-modules/blob/d9d16e7/packages/base/contracts/isolation-mode/interfaces/IIsolationModeTokenVaultV1.sol#L195
    function transferIntoPositionWithOtherToken(
        uint256 fromAccountNumber,
        uint256 borrowAccountNumber,
        uint256 marketId,
        uint256 amountWei,
        uint8 balanceCheckFlag
    ) external;

    // Transfer non-underlying token (e.g. WBTC surplus) out of position.
    // https://github.com/dolomite-exchange/dolomite-margin-modules/blob/d9d16e7/packages/base/contracts/isolation-mode/interfaces/IIsolationModeTokenVaultV1.sol#L213
    function transferFromPositionWithOtherToken(
        uint256 borrowAccountNumber,
        uint256 toAccountNumber,
        uint256 outputMarketId,
        uint256 amountWei,
        uint8 balanceCheckFlag
    ) external;

    // True iff Dolomite has a pending async op for the vault.
    // https://github.com/dolomite-exchange/dolomite-margin-modules/blob/d9d16e7/packages/base/contracts/isolation-mode/interfaces/IIsolationModeTokenVaultV1WithFreezable.sol#L43
    function isVaultFrozen() external view returns (bool);

    // Cancel pending async withdrawal by key (vault-owner only).
    // https://github.com/dolomite-exchange/dolomite-margin-modules/blob/d9d16e7/packages/gmx-v2/contracts/GmxV2IsolationModeTokenVaultV1.sol#L84-L94
    function cancelWithdrawal(bytes32 _key) external;

    // Cancel pending async deposit by key (vault-owner only).
    // https://github.com/dolomite-exchange/dolomite-margin-modules/blob/d9d16e7/packages/gmx-v2/contracts/GmxV2IsolationModeTokenVaultV1.sol#L96-L106
    function cancelDeposit(bytes32 _key) external;

    // Global async-unwrap kill switch on Dolomite side.
    function isExternalRedemptionPaused() external view returns (bool);
}

struct TraderParam {
    uint8 traderType;         // 3 = IsolationModeWrapper, 2 = IsolationModeUnwrapper
    uint256 makerAccountIndex;
    address trader;
    bytes tradeData;
}

struct Account {
    address owner;
    uint256 number;
}

struct UserConfig {
    uint256 deadline;
    uint8 balanceCheckFlag;   // 3 = None
    uint8 eventType;          // 1 = BorrowPosition
}
