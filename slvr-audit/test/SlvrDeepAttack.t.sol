// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";

interface L {
    function GRID() external view returns (uint8);
    function currentRoundId() external view returns (uint256);
    function bettingEnd(uint256) external view returns (uint256);
    function roundEnd(uint256) external view returns (uint256);
    function roundStart(uint256) external view returns (uint256);
    function roundOpen(uint256) external view returns (bool);
    function getLatestResolvedRoundId() external view returns (uint256);
    function getRound(uint256) external view returns (uint64,bool,bytes32,uint256,uint8,bool,bool,address,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256);
    function getTotalOnSquare(uint256,uint8) external view returns (uint256);
    function getUserBet(uint256,uint8,address) external view returns (uint256);
    function bet(uint256, uint8[] calldata, uint256[] calldata) external payable;
    function betFor(uint256, address, uint8[] calldata, uint256[] calldata) external payable;
    function getHasAccount(address) external view returns (bool);
    function getHasClaimed(uint256,address) external view returns (bool);
    function claim(uint256) external;
}

/// Deep economic/game-theory attack tests for SLVR Grid Lottery
contract SlvrDeepAttack is Test {
    address constant C = 0x284Eb4016305Fa7FbC162Fb68F27227271001c7f;
    L l = L(C);

    address whale = makeAddr("whale");
    address griefer = makeAddr("griefer");
    address bot = makeAddr("bot");
    address user1 = makeAddr("user1");
    address user2 = makeAddr("user2");

    function setUp() public {
        vm.createSelectFork("https://rpc.mainnet.chain.robinhood.com");
        vm.deal(whale, 100000 ether);
        vm.deal(griefer, 10000 ether);
        vm.deal(bot, 10000 ether);
        vm.deal(user1, 100 ether);
        vm.deal(user2, 100 ether);
    }

    // ──────────────────────────────────────────────────────────────────
    //  TEST 1: WHALE DOMINATION — Buy the entire board
    // ──────────────────────────────────────────────────────────────────
    function test_whale_domination() public {
        uint256 r = l.currentRoundId();
        if (!l.roundOpen(r)) return;

        vm.startPrank(whale);
        uint8[] memory sq = new uint8[](25);
        uint256[] memory am = new uint256[](25);
        for (uint8 i = 0; i < 25; i++) {
            sq[i] = i;
            am[i] = 0.1 ether;
        }
        l.bet{value: 2.5 ether}(r, sq, am);
        vm.stopPrank();

        for (uint8 i = 0; i < 25; i++) {
            uint256 total = l.getTotalOnSquare(r, i);
            uint256 w = l.getUserBet(r, i, whale);
            assertEq(w, total, "whale = only bettor on each square");
        }
        // Whale covers 100% of board — guaranteed win, but paid full pot to themselves
        console.log("Board domination works. Cost: 2.5 ETH. Profit if others bet > 2.5 ETH.");
    }

    // ──────────────────────────────────────────────────────────────────
    //  TEST 2: DILUTION GRIEF — Dilute a player's share
    // ──────────────────────────────────────────────────────────────────
    function test_grief_dilution() public {
        uint256 r = l.currentRoundId();
        if (!l.roundOpen(r)) return;

        // User1 bets 0.5 ETH on first 5 squares
        vm.startPrank(user1);
        uint8[] memory u1sq = new uint8[](5);
        uint256[] memory u1am = new uint256[](5);
        for (uint8 i = 0; i < 5; i++) { u1sq[i] = i; u1am[i] = 0.5 ether; }
        l.bet{value: 2.5 ether}(r, u1sq, u1am);
        vm.stopPrank();

        // Griefer matches with 1 ETH on same squares — dilutes user1 to 33%
        vm.startPrank(griefer);
        uint8[] memory gsq = new uint8[](5);
        uint256[] memory gam = new uint256[](5);
        for (uint8 i = 0; i < 5; i++) { gsq[i] = i; gam[i] = 1 ether; }
        l.bet{value: 5 ether}(r, gsq, gam);
        vm.stopPrank();

        for (uint8 i = 0; i < 5; i++) {
            assertEq(l.getUserBet(r, i, user1), 0.5 ether, "user1 0.5");
            assertEq(l.getUserBet(r, i, griefer), 1 ether, "griefer 1.0");
        }
        // Grief cost: 5 ETH. But griefer also wins 67% if their square hits.
        // Net: grief is expensive unless you can predict the winning square.
    }

    // ──────────────────────────────────────────────────────────────────
    //  TEST 3: TIMING — Bet at last second
    // ──────────────────────────────────────────────────────────────────
    function test_last_second_bet() public {
        uint256 r = l.currentRoundId();
        if (!l.roundOpen(r)) return;
        uint256 end = l.bettingEnd(r);
        uint256 timeLeft = end > block.timestamp ? end - block.timestamp : 0;
        if (timeLeft < 10) return; // skip if round is about to close

        // User1 bets early
        vm.prank(user1);
        uint8[] memory sq = new uint8[](1); sq[0] = 0;
        uint256[] memory am = new uint256[](1); am[0] = 1 ether;
        l.bet{value: 1 ether}(r, sq, am);

        // Bot warps to 5s before close and matches
        vm.warp(end - 5);
        vm.prank(bot);
        l.bet{value: 1 ether}(r, sq, am);

        assertEq(l.getTotalOnSquare(r, 0), 2 ether, "both bets counted");
        console.log("Last-second bet works — no front-running protection");
    }

    // ──────────────────────────────────────────────────────────────────
    //  TEST 4: BET AFTER CLOSE — Should revert
    // ──────────────────────────────────────────────────────────────────
    function test_no_bet_after_close() public {
        uint256 r = l.currentRoundId();
        if (!l.roundOpen(r)) return;
        vm.warp(l.bettingEnd(r) + 1);

        uint8[] memory sq = new uint8[](1); sq[0] = 0;
        uint256[] memory am = new uint256[](1); am[0] = 0.001 ether;
        vm.prank(bot);
        vm.expectRevert();
        l.bet{value: 0.0011 ether}(r, sq, am);
        console.log("Round closes properly — no post-close betting");
    }

    // ──────────────────────────────────────────────────────────────────
    //  TEST 5: CONCENTRATED BET — Put everything on one square
    // ──────────────────────────────────────────────────────────────────
    function test_concentrated_bet() public {
        uint256 r = l.currentRoundId();
        if (!l.roundOpen(r)) return;

        // Whale puts 10 ETH on a single square
        vm.prank(whale);
        uint8[] memory sq = new uint8[](1); sq[0] = 7;
        uint256[] memory am = new uint256[](1); am[0] = 10 ether;
        l.bet{value: 10 ether}(r, sq, am);

        uint256 total = l.getTotalOnSquare(r, 7);
        assertEq(total, 10 ether, "10 ETH on square 7");
        // If square 7 wins, whale gets ~96% of the pot (minus fee)
        // But only 1/25 chance of winning. EV = (1/25)*0.96*Pot - 10
        // Profitable when other players bet > 250 ETH
        console.log("Concentrated bet: 10 ETH on one square. Needs 260+ ETH total pot to profit.");
    }

    // ──────────────────────────────────────────────────────────────────
    //  TEST 6: BET ACROSS ROUNDS — check rollover
    // ──────────────────────────────────────────────────────────────────
    function test_round_rollover() public {
        uint256 r = l.currentRoundId();
        uint256 resolved = l.getLatestResolvedRoundId();
        assertGe(r, resolved, "current >= latest resolved");

        uint256 gap = resolved != type(uint256).max && resolved < r ? r - resolved - 1 : 0;
        console.log("Round gap:", gap);
        assertLe(gap, 1, "max 1 unresolved round gap");
        console.log("Round rollover consistent");
    }

    // ──────────────────────────────────────────────────────────────────
    //  TEST 7: CLAIM AS NON-BETTOR — Should revert
    // ──────────────────────────────────────────────────────────────────
    function test_claim_no_bet() public {
        uint256 resolved = l.getLatestResolvedRoundId();
        if (resolved == type(uint256).max) return;
        vm.prank(bot);
        vm.expectRevert();
        l.claim(resolved);
        console.log("Non-bettor correctly cannot claim");
    }

    // ──────────────────────────────────────────────────────────────────
    //  TEST 8: GRID CONSTANT
    // ──────────────────────────────────────────────────────────────────
    function test_grid_constant() public view {
        assertEq(l.GRID(), 25, "5x5 grid = 25 squares");
    }

    // ──────────────────────────────────────────────────────────────────
    //  TEST 9: BET VIA BETFOR — Can you fund another account's bet?
    // ──────────────────────────────────────────────────────────────────
    function test_bet_for_other() public {
        uint256 r = l.currentRoundId();
        if (!l.roundOpen(r)) return;

        // Whale bets FOR user1 (beneficiary)
        uint8[] memory sq = new uint8[](1); sq[0] = 3;
        uint256[] memory am = new uint256[](1); am[0] = 0.1 ether;
        vm.prank(whale);
        l.betFor{value: 0.1 ether}(r, user1, sq, am);

        // User1 should have the bet recorded
        assertEq(l.getUserBet(r, 3, user1), 0.1 ether, "user1 credited");
        assertEq(l.getUserBet(r, 3, whale), 0, "whale not credited");
        console.log("betFor correctly attributes bet to beneficiary, not funder");
    }
}
