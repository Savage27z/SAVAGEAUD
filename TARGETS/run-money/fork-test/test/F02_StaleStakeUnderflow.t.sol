// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console2} from "forge-std/Test.sol";
import {IClubPoolMin, IERC20Min} from "../src/IClubPoolMin.sol";

/// @title F02 - recordActivity's non-compliant branch subtracts the athlete's CURRENT stake,
///         not the originally-frozen epochAthleteStake amount. If the athlete's stake changed
///         since being marked compliant, this corrupts totalDepositByCompliant for the WHOLE
///         epoch - no attacker required, fires from ordinary usage.
contract F02_StaleStakeUnderflow is Test {
    IClubPoolMin constant pool = IClubPoolMin(0x1089Db83561d4c9B68350E1c292279817AC6c8DA);
    IERC20Min constant usdc = IERC20Min(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913);

    address owner;
    address athleteA = address(0x00000000000000000000000000000000BEEF03); // increases stake mid-epoch
    address athleteB = address(0x00000000000000000000000000000000BEEF04); // ordinary, never touches stake again

    uint256 epoch;

    function setUp() public {
        vm.createSelectFork(vm.envOr("BASE_RPC_URL", string("https://mainnet.base.org")));
        owner = pool.owner();
        epoch = pool.currentEpoch();

        uint256 fee = pool.membershipFee();
        vm.deal(athleteA, fee);
        vm.deal(athleteB, fee);
        vm.prank(athleteA);
        pool.mint{value: fee}();
        vm.prank(athleteB);
        pool.mint{value: fee}();

        deal(address(usdc), athleteA, 2_000e6);
        deal(address(usdc), athleteB, 1_000e6);

        vm.startPrank(athleteA);
        usdc.approve(address(pool), 2_000e6);
        pool.stake(1_000e6); // starts at 1,000 like athleteB
        vm.stopPrank();

        vm.startPrank(athleteB);
        usdc.approve(address(pool), 1_000e6);
        pool.stake(1_000e6);
        vm.stopPrank();
    }

    /// Variant 1: total ends up UNDER-subtracted -> totalDepositByCompliant goes to 0 even
    /// though athleteB is still legitimately compliant -> athleteB's claimBonus is bricked.
    function test_F02_HonestAthleteBBonusBricked() public {
        // Both marked compliant honestly, both stakes frozen at 1,000 each -> total = 2,000
        vm.prank(owner);
        pool.recordActivity(athleteA, true, epoch);
        vm.prank(owner);
        pool.recordActivity(athleteB, true, epoch);
        assertEq(pool.epochAthleteStake(epoch, athleteA), 1_000e6);
        assertEq(pool.epochAthleteStake(epoch, athleteB), 1_000e6);

        // athleteA does something completely ordinary: stakes MORE mid-epoch
        // (no malicious intent needed - just a runner adding to their savings)
        vm.prank(athleteA);
        pool.stake(1_000e6); // real stake now 2,000e6

        // Later, athleteA has a bad week and reporter marks them non-compliant.
        // The bug: this subtracts athleteA's CURRENT stake (2,000e6), not the
        // 1,000e6 that was actually added to totalDepositByCompliant earlier.
        vm.prank(owner);
        pool.recordActivity(athleteA, false, epoch);

        // totalDepositByCompliant was 2,000e6 (both athletes' frozen 1,000 each).
        // Subtracting athleteA's CURRENT 2,000e6 drives it to exactly 0 -
        // wiping out athleteB's legitimate contribution too, even though athleteB
        // never did anything and is still marked compliant.
        assertTrue(pool.epochAthleteCompliance(epoch, athleteB), "athleteB is still marked compliant");

        vm.warp(pool.currentEpochStartTime() + pool.epochDuration());
        pool.endEpoch();

        // athleteB is honest, compliant, did nothing wrong - and cannot claim at all.
        vm.prank(athleteB);
        vm.expectRevert(bytes("Total deposits by compliant athletes is zero"));
        pool.claimBonus(epoch);

        console2.log("CONFIRMED: an honest, still-compliant athlete's claimBonus is bricked");
        console2.log("solely because a DIFFERENT athlete increased their own stake mid-epoch.");
    }

    /// Variant 2: total ends up so under-subtracted it UNDERFLOWS -> recordActivity(false)
    /// itself reverts, meaning the reporter can no longer ever mark that athlete
    /// non-compliant for the rest of the epoch, regardless of their real activity.
    function test_F02_RecordActivityRevertsLockingComplianceOn() public {
        vm.prank(owner);
        pool.recordActivity(athleteA, true, epoch); // frozen at 1,000e6, total = 1,000e6

        // athleteA stakes a lot more - current stake now exceeds total totalDepositByCompliant
        vm.prank(athleteA);
        pool.stake(1_000e6); // current = 2,000e6, but total is only 1,000e6

        // Reporter tries to correct: mark athleteA non-compliant after a bad week.
        // total(1,000e6) -= current(2,000e6) underflows -> reverts.
        vm.prank(owner);
        vm.expectRevert(); // arithmetic underflow/overflow panic
        pool.recordActivity(athleteA, false, epoch);

        console2.log("CONFIRMED: recordActivity(athleteA, false, epoch) reverts.");
        console2.log("The reporter can NEVER mark athleteA non-compliant again this epoch -");
        console2.log("athleteA is permanently 'compliant' regardless of real behavior, just");
        console2.log("by having staked more than their originally-frozen amount.");
    }
}
