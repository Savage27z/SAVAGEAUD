// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IInitialCoreAddressBook} from "../interfaces/IInitialCoreAddressBook.sol";

contract InitialCoreAddressBook is IInitialCoreAddressBook {
    struct InitialCoreAddresses {
        address vaultCore;
        address depositHandler;
        address withdrawHandler;
        address managerHandler;
        address asyncRecoveryHandler;
        address feeAccountingHandler;
        address extensionHandler1;
        address extensionHandler2;
        address extensionHandler3;
        address basaltState;
        address basaltMath;
        address dolomiteVault;
    }

    address public immutable vaultCore;
    address public immutable depositHandler;
    address public immutable withdrawHandler;
    address public immutable managerHandler;
    address public immutable asyncRecoveryHandler;
    address public immutable feeAccountingHandler;
    address public immutable extensionHandler1;
    address public immutable extensionHandler2;
    address public immutable extensionHandler3;
    address public immutable basaltState;
    address public immutable basaltMath;
    address public immutable dolomiteVault;

    constructor(InitialCoreAddresses memory initialAddresses) {
        vaultCore            = initialAddresses.vaultCore;
        depositHandler       = initialAddresses.depositHandler;
        withdrawHandler      = initialAddresses.withdrawHandler;
        managerHandler       = initialAddresses.managerHandler;
        asyncRecoveryHandler = initialAddresses.asyncRecoveryHandler;
        feeAccountingHandler = initialAddresses.feeAccountingHandler;
        extensionHandler1    = initialAddresses.extensionHandler1;
        extensionHandler2    = initialAddresses.extensionHandler2;
        extensionHandler3    = initialAddresses.extensionHandler3;
        basaltState          = initialAddresses.basaltState;
        basaltMath           = initialAddresses.basaltMath;
        dolomiteVault        = initialAddresses.dolomiteVault;
    }

    function initialCoreAddresses() external view returns (InitialCoreAddresses memory) {
        return InitialCoreAddresses({
            vaultCore:            vaultCore,
            depositHandler:       depositHandler,
            withdrawHandler:      withdrawHandler,
            managerHandler:       managerHandler,
            asyncRecoveryHandler: asyncRecoveryHandler,
            feeAccountingHandler: feeAccountingHandler,
            extensionHandler1:    extensionHandler1,
            extensionHandler2:    extensionHandler2,
            extensionHandler3:    extensionHandler3,
            basaltState:          basaltState,
            basaltMath:           basaltMath,
            dolomiteVault:        dolomiteVault
        });
    }
}
