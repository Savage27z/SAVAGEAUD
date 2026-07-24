// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IDolomiteMargin} from "../../interfaces/IDolomiteMargin.sol";
import {BasaltMath} from "../../pure/BasaltMath.sol";

// ────────────────────────────────────────────────────────────────────────────
//  ERRORS
// ────────────────────────────────────────────────────────────────────────────

error NotIdle();
error CooldownNotPassed(uint256 blocksRemaining);
error DepositTooSmall(uint256 value, uint256 min);
error VaultStillFrozen();
error InvalidSlippage();
error PostDepositLtvTooHigh(uint256 ltvBps);
error NotVaultNftOwner();
error NotManagerOrNftOwner();
error DepositNotPending();
error NeedToAbsorbSurplus();
error NoSurplusToAbsorb();
error InvalidWbtcAsDepositValue(uint256 valueUsdE18, uint256 minUsdE18, uint256 maxUsdE18);
error ZeroAbsorbAmount();
error InvalidDepositBranch(uint256 gmCollateral, uint256 wbtcDebt, uint256 surplusGm);

// ────────────────────────────────────────────────────────────────────────────
//  BRANCH TYPES
// ────────────────────────────────────────────────────────────────────────────

enum DepositBranch {
    CreateIsolationVault,
    EmptyIsolationVault,
    CollateralOnly,
    DebtFreeSurplus,
    Standard
}

// ────────────────────────────────────────────────────────────────────────────
//  DEPOSIT CONTEXT
// ────────────────────────────────────────────────────────────────────────────

struct DepositContext {
    DepositBranch branch;
    IDolomiteMargin dolomiteMargin;
    BasaltMath basaltMath;
    uint256 gmPriceE18;
    uint256 wbtcPriceE18;
    uint256 wbtcPriceE8;
    uint256 gmCollateral;
    uint256 wbtcDebt;
    uint256 surplusGm;
    uint256 amountGmE18;
    uint256 userSlippageBps;
    uint256 targetLtvBps;
    uint256 depositValueE18;
    uint256 borrowValueE18;
    uint256 borrowWbtcE8;
    uint256 gmReceivedMinE18;
    bool isolationVaultCreated;
}

library DepositHandlerTypes {}
