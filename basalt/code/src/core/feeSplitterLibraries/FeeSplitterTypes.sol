// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

interface IManagerContractOperationalLookup {
    function operational() external view returns (address);
}

error NoPaymentDue(address account, IERC20 token);
error ZeroTokenAddress();
error TokenAlreadyTracked(IERC20 token);
error MaxTrackedTokensReached(uint256 cap);
error ZeroManagerContract();
error ManagerContractAlreadySet(address currentManagerContract);
error NotManagerContract(address caller);
error NotAuthorisedToNotify(address caller);
error NotInitialOwner(address caller);
error NotAuthorisedToRelease(address caller);
error TokenIsSkipped(IERC20 token);

library FeeSplitterTypes {}
