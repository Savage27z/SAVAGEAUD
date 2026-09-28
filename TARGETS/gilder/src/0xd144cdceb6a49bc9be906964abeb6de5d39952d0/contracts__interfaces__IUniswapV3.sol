// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/**
 * Minimal Uniswap V3 surface used by the GILDer protocol.
 *
 * Only the functions/structs the protocol actually calls are declared, kept
 * ABI-compatible with the canonical @uniswap/v3-periphery + v3-core so the
 * real Base (Sepolia/mainnet) deployments - or a Base-native Slipstream fork
 * with the same signatures - can be wired without changes.
 */

/** @dev Uniswap V3 canonical factory. */
interface IUniswapV3Factory {
    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address pool);
    function createPool(address tokenA, address tokenB, uint24 fee) external returns (address pool);
}

/** @dev A single Uniswap V3 pool (subset). */
interface IUniswapV3Pool {
    /// Sets the initial price for the pool (sqrtPriceX96, Q64.96).
    function initialize(uint160 sqrtPriceX96) external;

    /// The 0th storage slot - most notably the live `sqrtPriceX96` + tick.
    function slot0()
        external
        view
        returns (
            uint160 sqrtPriceX96,
            int24 tick,
            uint16 observationIndex,
            uint16 observationCardinality,
            uint16 observationCardinalityNext,
            uint8 feeProtocol,
            bool unlocked
        );

    function token0() external view returns (address);
    function token1() external view returns (address);
    function fee() external view returns (uint24);
    function tickSpacing() external view returns (int24);
    function liquidity() external view returns (uint128);

    /// V3 oracle - cumulative ticks at each `secondsAgo`, for TWAP derivation.
    function observe(uint32[] calldata secondsAgos)
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s);

    /// Grows the oracle ring buffer so a TWAP window is observable.
    function increaseObservationCardinalityNext(uint16 observationCardinalityNext) external;
}

/**
 * @dev Uniswap V3 SwapRouter02 (subset). The protocol's §F stream sells/buys
 * and the 10% token-buy leg execute single-hop exact-input swaps through this.
 * NB: this is the SwapRouter02 signature - `ExactInputSingleParams` has NO
 * `deadline` field (SwapRouter02 dropped it; deadlines are handled via its
 * multicall wrapper). Base only deploys SwapRouter02, so this is the one to use.
 */
interface ISwapRouter {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata params)
        external
        payable
        returns (uint256 amountOut);

    function factory() external view returns (address);
}

/**
 * @dev Uniswap V3 NonfungiblePositionManager (subset). LP positions are
 * ERC-721 NFTs; the protocol mints ONE full-range position, holds the NFT,
 * and later `increaseLiquidity`/`collect`s against it. `decreaseLiquidity` is
 * intentionally NOT declared - the protocol must never burn core liquidity.
 */
interface INonfungiblePositionManager {
    struct MintParams {
        address token0;
        address token1;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        address recipient;
        uint256 deadline;
    }

    function mint(MintParams calldata params)
        external
        payable
        returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1);

    struct IncreaseLiquidityParams {
        uint256 tokenId;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        uint256 deadline;
    }

    function increaseLiquidity(IncreaseLiquidityParams calldata params)
        external
        payable
        returns (uint128 liquidity, uint256 amount0, uint256 amount1);

    struct CollectParams {
        uint256 tokenId;
        address recipient;
        uint128 amount0Max;
        uint128 amount1Max;
    }

    /// Harvests owed tokens (accrued swap fees) to `recipient`. Owner-only.
    function collect(CollectParams calldata params) external payable returns (uint256 amount0, uint256 amount1);

    function positions(uint256 tokenId)
        external
        view
        returns (
            uint96 nonce,
            address operator,
            address token0,
            address token1,
            uint24 fee,
            int24 tickLower,
            int24 tickUpper,
            uint128 liquidity,
            uint256 feeGrowthInside0LastX128,
            uint256 feeGrowthInside1LastX128,
            uint128 tokensOwed0,
            uint128 tokensOwed1
        );

    function factory() external view returns (address);
    function ownerOf(uint256 tokenId) external view returns (address);
}
