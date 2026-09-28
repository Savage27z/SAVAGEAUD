// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

interface IGilderTypes {
    enum DepositState {
        None,
        Active,
        Matured,
        Dormant,
        Abandoned,
        Exited,
        Closed
    }

    struct Deposit {
        address owner;
        uint256 principal;
        uint256 safeVaultAmount;
        uint256 tokenBuyAmount;
        uint256 treasuryAmount;
        uint256 liquidityAmount;
        uint256 annualRateBps;
        uint256 accruedInterest;
        uint256 loanBalance;
        uint256 loanAccruedInterest;
        uint64 startTime;
        uint64 maturityTime;
        uint64 dormantTime;
        DepositState state;
        uint8 compoundMode;
        // Running total of accrued interest ever realized out of this
        // deposit - incremented by `consumeAccruedInterest` (auto-compound)
        // and by every settlement path (settleMatured, earlyExit,
        // rollover, recovery). The §4.2 yield formula is a CUMULATIVE
        // time-based total from startTime; without this counter the
        // contract would re-pay the same interest on every fresh
        // `accrueInterest` call. Pending = totalTimeBased - realizedInterest.
        // Appended at end of struct so upgrades preserve storage layout.
        uint256 realizedInterest;
        // §V6.2-Turbo - product flag set at `_openDepositCore` time and
        // immutable for the life of the deposit (auto-compound mode can
        // still flip, but the product economics - APR, capital routing,
        // early-exit penalty - are locked at creation). 0 = Standard
        // (20% APR, 80/10/9/1 routing, 20% early-exit penalty); 1 = Turbo
        // (20% APR - UI shows 27.5% - 80/10/9/1 routing, 50% penalty).
        uint8 productMode;
        // Snapshot of the early-exit penalty BPS at creation. Stored on
        // the deposit so a future governance tweak to the protocol-wide
        // default cannot retroactively change the penalty owed by an
        // existing position. Read by `earlyExit`.
        uint256 earlyExitPenaltyBps;
    }
}
