// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

library BasaltConstants {
    // ════════════════════════════════════════════════════════════════════
    //  BASIS POINTS
    // ════════════════════════════════════════════════════════════════════

    uint256 internal constant BPS = 10_000;

    // ════════════════════════════════════════════════════════════════════
    //  STATE MACHINE
    // ════════════════════════════════════════════════════════════════════

    uint8 internal constant STATE_IDLE = 0;
    uint8 internal constant STATE_PENDING = 1;

    // ════════════════════════════════════════════════════════════════════
    //  GLOBAL COOLDOWN
    // ════════════════════════════════════════════════════════════════════

    uint256 internal constant GLOBAL_ACTION_COOLDOWN_BLOCKS = 1;

    // ════════════════════════════════════════════════════════════════════
    //  LTV CAPS
    // ════════════════════════════════════════════════════════════════════

    uint256 internal constant MAX_SAFE_LTV_BPS = 7_000; // 70%

    // ════════════════════════════════════════════════════════════════════
    //  VAULTCORE — SHARES / FEE
    // ════════════════════════════════════════════════════════════════════

    // ERC4626 virtual offset 6 — initial share price $1.
    uint256 internal constant VIRTUAL_SHARES = 1e6;
    uint256 internal constant VIRTUAL_ASSETS = 1;

    uint256 internal constant SHARE_UNIT = 1e18;

    // Performance fee (Enzyme-style HWM).
    uint256 internal constant MANAGER_FEE_BPS = 2_000; // 20%

    uint256 internal constant MAX_DEPOSIT_FEE = 0.1 ether;

    // ════════════════════════════════════════════════════════════════════
    //  VAULTCORE — CONFIG RANGES (manager-tunable bounds)
    // ════════════════════════════════════════════════════════════════════

    uint256 internal constant MIN_TARGET_LTV_BPS = 4_800; // 48%
    uint256 internal constant MAX_TARGET_LTV_BPS = 5_200; // 52%
    uint256 internal constant MIN_REBALANCE_THRESHOLD_BPS = 500; // 5%
    uint256 internal constant MAX_REBALANCE_THRESHOLD_BPS = 2_000; // 20%

    uint256 internal constant MIN_REBALANCE_SLIPPAGE_CAP_BPS = 100; // 1%
    uint256 internal constant MAX_REBALANCE_SLIPPAGE_CAP_BPS = 1_000; // 10%

    uint256 internal constant MIN_UNWRAP_LONG_SHARE_BPS = 4_000; // 40%
    uint256 internal constant MAX_UNWRAP_LONG_SHARE_BPS = 5_000; // 50%

    // ════════════════════════════════════════════════════════════════════
    //  VAULTCORE — REBALANCE CONFIG DEFAULTS (manager-mutable state inits)
    // ════════════════════════════════════════════════════════════════════

    uint256 internal constant DEFAULT_TARGET_LTV_BPS = 5_000; // 50%
    uint256 internal constant DEFAULT_REBALANCE_THRESHOLD_UP_BPS = 2_000; // 20%
    uint256 internal constant DEFAULT_REBALANCE_THRESHOLD_DOWN_BPS = 2_000; // 20%
    uint256 internal constant DEFAULT_REBALANCE_SLIPPAGE_CAP_BPS = 500; // 5%
    uint256 internal constant DEFAULT_UNWRAP_LONG_SHARE_BPS = 5_000; // 50%

    // ════════════════════════════════════════════════════════════════════
    //  VAULTCORE — PERMISSIONLESS / KEEPER
    // ════════════════════════════════════════════════════════════════════

    uint256 internal constant MIN_KEEPER_DEADLINE = 60 seconds;
    uint256 internal constant MAX_KEEPER_DEADLINE = 60 minutes;

    uint256 internal constant DEFAULT_KEEPER_DEADLINE = 60 seconds;

    // ════════════════════════════════════════════════════════════════════
    //  DOLOMITE
    // ════════════════════════════════════════════════════════════════════

    uint256 internal constant DOLOMITE_ACCOUNT_DEFAULT = 0;
    uint256 internal constant DOLOMITE_ISOLATION_ACCOUNT = 100;

    uint256 internal constant DOLOMITE_MARKET_WBTC = 4;
    uint256 internal constant DOLOMITE_MARKET_USDC = 17;
    uint256 internal constant DOLOMITE_MARKET_GM = 32;

    uint256 internal constant DOLOMITE_PRECISION = 1e18;

    // ════════════════════════════════════════════════════════════════════
    //  EMERGENCY — slippage curve (EmergencyHandler, EmergencyGmUnwrap)
    // ════════════════════════════════════════════════════════════════════

    uint256 internal constant EMERGENCY_INITIAL_SLIPPAGE_BPS = 500; // 5%
    uint256 internal constant EMERGENCY_DAILY_SLIPPAGE_REDUCTION_BPS = 100; // 1%/day
    uint256 internal constant EMERGENCY_MIN_SLIPPAGE_BPS = 100; // 1% floor

    // ════════════════════════════════════════════════════════════════════
    //  EMERGENCY — unwind parameters
    // ════════════════════════════════════════════════════════════════════

    // Chunked-unwind threshold as fraction of GM supply.
    uint256 internal constant EMERGENCY_CHUNKED_UNWIND_THRESHOLD_BPS = 100; // 1%
    uint256 internal constant EMERGENCY_CHUNK_DIVISOR = 10;
    uint256 internal constant REDEEM_TOKEN_COUNT = 4;

    // ════════════════════════════════════════════════════════════════════
    //  EMERGENCY SWAP (Uniswap V3 path)
    // ════════════════════════════════════════════════════════════════════

    // Emergency WBTC→USDC swap slippage cap (vs TWAP).
    uint256 internal constant EMERGENCY_SWAP_SLIPPAGE_BPS = 100; // 1%

    // 30-min TWAP — flash-loan resistant.
    uint32 internal constant EMERGENCY_TWAP_WINDOW = 1800;

    // Uniswap V3 0.05% fee tier (USDC pools).
    uint24 internal constant UNI_V3_FEE_WBTC_USDC = 500;
    uint24 internal constant UNI_V3_FEE_WETH_USDC = 500;

    // ════════════════════════════════════════════════════════════════════
    //  DEPOSIT HANDLER
    // ════════════════════════════════════════════════════════════════════

    uint256 internal constant MAX_DEPOSIT_SLIPPAGE_BPS = 500; // 5%
    uint256 internal constant MIN_DEPOSIT_SLIPPAGE_BPS = 50; // 0.5%
    // Post-deposit LTV ceiling.
    uint256 internal constant MAX_POST_DEPOSIT_LTV_BPS = 7_000; // 70%
    uint256 internal constant MAX_WBTC_SURPLUS_AS_DEPOSIT_USD_E18 = 10e18;

    // ════════════════════════════════════════════════════════════════════
    //  WITHDRAW HANDLER
    // ════════════════════════════════════════════════════════════════════

    uint256 internal constant MIN_WITHDRAW_SHARES = 1e18;
    uint256 internal constant RAW_RATIO_SCALE = 1e18;

    // ════════════════════════════════════════════════════════════════════
    //  MANAGER HANDLER
    // ════════════════════════════════════════════════════════════════════

    uint256 internal constant MANAGER_MIN_SLIPPAGE_BPS = 50; // 0.5%
    uint256 internal constant MANAGER_MAX_SLIPPAGE_BPS = 1_000; // 10%

    // ════════════════════════════════════════════════════════════════════
    //  ASYNC RECOVERY HANDLER
    // ════════════════════════════════════════════════════════════════════

    // Async-unstuck grace after VaultState async deadline.
    uint256 internal constant UNSTUCK_GRACE_AFTER_DEADLINE = 10 minutes;

    uint256 internal constant MANAGER_DEADMAN_BLOCKS = 2_628_000;

    // ════════════════════════════════════════════════════════════════════
    //  ZAP (shared — BasaltZapIn / BasaltZapOut)
    // ════════════════════════════════════════════════════════════════════

    uint24 internal constant STABLE_POOL_FEE = 100; // 0.01%
    uint24 internal constant WBTC_POOL_FEE = 500; // 0.05%

    // User swap slippage bounds (ZapIn=cap, ZapOut=both).
    uint256 internal constant ZAP_MAX_SWAP_SLIPPAGE_BPS = 1_000; // 10%
    uint256 internal constant ZAP_MIN_SWAP_SLIPPAGE_BPS = 10; // 0.1%

    uint256 internal constant ZAP_MIN_RETRY_WINDOW = 60 seconds;
    uint256 internal constant ZAP_MAX_RETRY_WINDOW = 20 minutes;
    uint256 internal constant ZAP_DEFAULT_RETRY_WINDOW = 60 seconds;

    // ────────────── ZapIn specific ──────────────

    // Pool imbalance guard for tight-zap path.
    uint256 internal constant ZAPIN_MIN_POOL_IMBALANCE_BPS = 10; // 0.1%
    uint256 internal constant ZAPIN_MAX_POOL_IMBALANCE_BPS = 200; // 2%

    // Extra GM buffer above minOut before tight-zap forwards.
    uint256 internal constant ZAPIN_MIN_DEPOSIT_GM_BUFFER_BPS = 500; // 5%

    // GMX→ZapIn callback gas (first hop only).
    uint256 internal constant ZAPIN_CALLBACK_GAS_LIMIT = 1_600_000;

    // ════════════════════════════════════════════════════════════════════
    //  GM UNWRAPPER (standalone BasaltGmUnwrapper)
    // ════════════════════════════════════════════════════════════════════

    uint16 internal constant GM_UNWRAPPER_MAX_SLIPPAGE_BPS = 5_000; // 50%
    uint16 internal constant GM_UNWRAPPER_MAX_PERMISSIONLESS_SLIPPAGE_BPS = 200; // 2%
    uint256 internal constant GM_UNWRAPPER_CALLBACK_GAS_LIMIT = 2_000_000;

    // ════════════════════════════════════════════════════════════════════
    //  ORACLE GUARD (Chainlink staleness + spread + sequencer)
    // ════════════════════════════════════════════════════════════════════

    // Heartbeat + 1h buffer for Arbitrum feeds.
    uint256 internal constant ORACLE_WBTC_MAX_AGE = 90_000;
    uint256 internal constant ORACLE_USDC_MAX_AGE = 90_000;

    // Sequencer-uptime grace period (Arbitrum).
    // https://github.com/aave/aave-v3-core/blob/master/contracts/protocol/configuration/PriceOracleSentinel.sol#L71
    uint256 internal constant ORACLE_SEQUENCER_GRACE_PERIOD = 3600;

    // Chainlink (1e8) → GMX FLOAT_PRECISION (1e30) scaler.
    // https://github.com/gmx-io/gmx-synthetics/blob/10cfbce/contracts/utils/Precision.sol#L23
    uint256 internal constant ORACLE_CL_TO_GMX = 1e22;

    // Chainlink-vs-Dolomite price-spread guard.
    uint256 internal constant ORACLE_PRICE_SPREAD_BPS = 25; // 0.25%

    // Absolute price sanity ceilings (fail-closed).
    uint256 internal constant ORACLE_WBTC_MAX_PRICE_E8 = 1e15;
    uint256 internal constant ORACLE_USDC_MAX_PRICE_E8 = 1e9;

    // ════════════════════════════════════════════════════════════════════
    //  GMX DATASTORE KEYS (shared across modules)
    // ════════════════════════════════════════════════════════════════════
    // https://github.com/gmx-io/gmx-synthetics/blob/10cfbce/contracts/data/Keys.sol

    // (market, token) pool-amount slot.
    bytes32 internal constant GMX_KEY_POOL_AMOUNT = keccak256(abi.encode("POOL_AMOUNT"));
}
