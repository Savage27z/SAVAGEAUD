// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// https://github.com/dolomite-exchange/dolomite-margin/blob/add64ba/contracts/protocol/interfaces/IDolomiteMargin.sol
interface IDolomiteMargin {
    struct MonetaryPrice {
        uint256 value;
    }

    // https://github.com/dolomite-exchange/dolomite-margin/blob/add64ba/contracts/protocol/lib/Types.sol#L209-L212
    struct Wei {
        bool sign; // true = positive (asset), false = negative (debt)
        uint256 value;
    }

    // https://github.com/dolomite-exchange/dolomite-margin/blob/add64ba/contracts/protocol/lib/Account.sol#L53-L56
    struct AccountInfo {
        address owner;
        uint256 number;
    }

    // https://github.com/dolomite-exchange/dolomite-margin/blob/add64ba/contracts/protocol/lib/Types.sol#L54-L59
    struct AssetAmount {
        bool sign;
        uint8 denomination;
        uint8 ref;
        uint256 value;
    }

    // https://github.com/dolomite-exchange/dolomite-margin/blob/add64ba/contracts/protocol/lib/Actions.sol#L71-L80
    struct ActionArgs {
        uint8 actionType;
        uint256 accountId;
        AssetAmount amount;
        uint256 primaryMarketId;
        uint256 secondaryMarketId;
        address otherAddress;
        uint256 otherAccountId;
        bytes data;
    }

    // https://github.com/dolomite-exchange/dolomite-margin/blob/add64ba/contracts/protocol/lib/Types.sol#L178-L181
    struct Par {
        bool sign;       // true = positive (asset), false = negative (debt)
        uint128 value;   // par units (index-independent accounting)
    }

    // Layout must match dolomite-protocol-v2 Interest.sol exactly.
    struct Index {
        uint96 borrow;
        uint96 supply;
        uint32 lastUpdate;
    }

    // https://github.com/dolomite-exchange/dolomite-margin/blob/add64ba/contracts/protocol/Getters.sol#L268
    function getMarketPrice(
        uint256 marketId
    ) external view returns (MonetaryPrice memory);

    // https://github.com/dolomite-exchange/dolomite-margin/blob/add64ba/contracts/protocol/Getters.sol#L338
    function getMarketMarginPremium(
        uint256 marketId
    ) external view returns (uint256);

    // https://github.com/dolomite-exchange/dolomite-margin/blob/add64ba/contracts/protocol/Getters.sol#L496
    function getAccountWei(
        AccountInfo memory account,
        uint256 marketId
    ) external view returns (Wei memory);

    // https://github.com/dolomite-exchange/dolomite-margin/blob/add64ba/contracts/protocol/Getters.sol#L486
    function getAccountPar(
        AccountInfo memory account,
        uint256 marketId
    ) external view returns (Par memory);

    function getMarketCurrentIndex(
        uint256 marketId
    ) external view returns (Index memory);

    // https://github.com/dolomite-exchange/dolomite-margin/blob/add64ba/contracts/protocol/interfaces/IDolomiteMargin.sol#L657-L660
    function operate(
        AccountInfo[] memory accounts,
        ActionArgs[] memory actions
    ) external;
}
