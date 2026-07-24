// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// ABI mirror of gmx-synthetics IDepositCallbackReceiver / EventUtils.
// msg.sender at receiver = GMX v2 DepositHandler / WithdrawalHandler.
// callback gas = deposit.callbackGasLimit, capped by MAX_CALLBACK_GAS_LIMIT.

library GmxEventUtils {
    struct EventLogData {
        AddressItems addressItems;
        UintItems uintItems;
        IntItems intItems;
        BoolItems boolItems;
        Bytes32Items bytes32Items;
        BytesItems bytesItems;
        StringItems stringItems;
    }

    struct AddressItems {
        AddressKeyValue[] items;
        AddressArrayKeyValue[] arrayItems;
    }

    struct UintItems {
        UintKeyValue[] items;
        UintArrayKeyValue[] arrayItems;
    }

    struct IntItems {
        IntKeyValue[] items;
        IntArrayKeyValue[] arrayItems;
    }

    struct BoolItems {
        BoolKeyValue[] items;
        BoolArrayKeyValue[] arrayItems;
    }

    struct Bytes32Items {
        Bytes32KeyValue[] items;
        Bytes32ArrayKeyValue[] arrayItems;
    }

    struct BytesItems {
        BytesKeyValue[] items;
        BytesArrayKeyValue[] arrayItems;
    }

    struct StringItems {
        StringKeyValue[] items;
        StringArrayKeyValue[] arrayItems;
    }

    struct AddressKeyValue {
        string key;
        address value;
    }

    struct AddressArrayKeyValue {
        string key;
        address[] value;
    }

    struct UintKeyValue {
        string key;
        uint256 value;
    }

    struct UintArrayKeyValue {
        string key;
        uint256[] value;
    }

    struct IntKeyValue {
        string key;
        int256 value;
    }

    struct IntArrayKeyValue {
        string key;
        int256[] value;
    }

    struct BoolKeyValue {
        string key;
        bool value;
    }

    struct BoolArrayKeyValue {
        string key;
        bool[] value;
    }

    struct Bytes32KeyValue {
        string key;
        bytes32 value;
    }

    struct Bytes32ArrayKeyValue {
        string key;
        bytes32[] value;
    }

    struct BytesKeyValue {
        string key;
        bytes value;
    }

    struct BytesArrayKeyValue {
        string key;
        bytes[] value;
    }

    struct StringKeyValue {
        string key;
        string value;
    }

    struct StringArrayKeyValue {
        string key;
        string[] value;
    }
}

interface IDepositCallbackReceiver {
    function afterDepositExecution(
        bytes32 key,
        GmxEventUtils.EventLogData memory depositData,
        GmxEventUtils.EventLogData memory eventData
    ) external;

    function afterDepositCancellation(
        bytes32 key,
        GmxEventUtils.EventLogData memory depositData,
        GmxEventUtils.EventLogData memory eventData
    ) external;
}

// GMX v2 withdrawal callback. msg.sender at receiver = WithdrawalHandler.
// eventData: outputToken/longTokenAmount, secondaryOutputToken/shortTokenAmount.
interface IWithdrawalCallbackReceiver {
    function afterWithdrawalExecution(
        bytes32 key,
        GmxEventUtils.EventLogData memory withdrawalData,
        GmxEventUtils.EventLogData memory eventData
    ) external;

    function afterWithdrawalCancellation(
        bytes32 key,
        GmxEventUtils.EventLogData memory withdrawalData,
        GmxEventUtils.EventLogData memory eventData
    ) external;
}
