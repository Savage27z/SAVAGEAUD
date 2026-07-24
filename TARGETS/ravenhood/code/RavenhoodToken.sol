// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {Owned} from "solmate/src/auth/Owned.sol";

contract Ravenhood is ERC20, Owned {
    constructor(address deployer, uint256 supply) ERC20("Ravenhood", "RVH", 18) Owned(msg.sender) {
        _mint(deployer, supply);
    }

    function renounceOwnership() external onlyOwner {
        transferOwnership(address(0));
    }
}
