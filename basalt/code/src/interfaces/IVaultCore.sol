// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IDolomiteIsolationVault} from "./IDolomiteVault.sol";


interface IVaultCore {
    function execDelegateCall(address target, bytes calldata data) external returns (bytes memory result);
}
