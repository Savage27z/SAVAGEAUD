// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

/// @notice Foundry PoC template using mainnet fork (from cholakovvv/foundry-poc-mainnet-fork)
/// @dev Run with: forge test --fork-url <RPC> --match-test testExploit -vvv
contract PoCTemplate is Test {
    // --- CONFIG ---
    // Replace these with real addresses
    address constant VAULT = address(0);
    address constant ATTACKER = address(0xBad);
    address constant TOKEN = address(0);

    function setUp() public {
        // Fork the chain at a specific block
        // vm.createSelectFork(vm.envString("RPC_URL"), BLOCK_NUMBER);

        // Label addresses for trace readability
        vm.label(VAULT, "Vault");
        vm.label(ATTACKER, "Attacker");

        // Deal tokens to attacker
        // deal(TOKEN, ATTACKER, AMOUNT);
    }

    function testExploit() public {
        // --- SETUP ---
        // Impersonate accounts as needed
        vm.startPrank(ATTACKER);

        // --- EXPLOIT ---
        // Call the vulnerable function(s)

        // --- ASSERT ---
        // Prove the exploit worked — show the money moved
        // assertGt(token.balanceOf(ATTACKER), initialBalance);

        vm.stopPrank();
    }
}
