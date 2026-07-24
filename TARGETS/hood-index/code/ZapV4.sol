// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IndexVault} from "./IndexVault.sol";

/// @dev Minimal Uniswap V4 interface. We deliberately don't pull in the whole
///      v4-core lib: we only need unlock/swap/settle/take.
interface IPoolManager {
    function unlock(bytes calldata data) external returns (bytes memory);
    function swap(PoolKey memory key, SwapParams memory params, bytes calldata hookData) external returns (int256 delta);
    function sync(address currency) external;
    function settle() external payable returns (uint256);
    function take(address currency, address to, uint256 amount) external;
}

struct PoolKey {
    address currency0;
    address currency1;
    uint24 fee;
    int24 tickSpacing;
    address hooks;
}

struct SwapParams {
    bool zeroForOne;
    int256 amountSpecified; // <0 = exact input, >0 = exact output
    uint160 sqrtPriceLimitX96;
}

/// @title ZapV4 — one transaction: ETH in, hMAG7 out.
/// @notice The MAG7 stock tokens have no usable V3 liquidity and 0x refuses
///         them ("not authorized for trade due to legal restrictions"). All depth
///         sits in Uniswap V4. This contract buys the seven components in a single
///         `unlock` (ETH → USDG → stock) and mints them in-kind against the vault.
///
/// @dev    Routing: each component may come directly from an ETH pool, or
///         via USDG as an intermediate hop. That is not cosmetic — for AAPL, GOOGL,
///         NVDA, META and TSLA the ETH pools are far deeper, while MSFT has
///         none at all and AMZN only an empty one. Picking one fixed hub therefore
///         always costs someone money; the caller quotes both and supplies the
///         cheapest pool per component.
///
///         Within a single unlock the deltas net out: stock swaps create ETH and/or
///         USDG debt, one ETH→USDG exact-output swap covers exactly the USDG debt,
///         and at the end we only settle ETH.
///
/// Safety:
///  - No owner, no upgrade, no whitelist: the pool keys come from the caller
///    and the worst a bad key can do is make the tx fail.
///  - maxEthIn = msg.value is the hard upper bound; minSharesOut protects against
///    slippage. Everything left over goes back to the caller.
///  - The contract holds nothing between transactions.
contract ZapV4 is ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint160 internal constant MIN_SQRT_PRICE = 4295128739;
    uint160 internal constant MAX_SQRT_PRICE = 1461446703485210103287273052203988822378723970342;

    IPoolManager public immutable poolManager;
    IndexVault public immutable vault;
    address public immutable usdg;

    event ZapMinted(address indexed sender, address indexed to, uint256 ethSpent, uint256 sharesOut);
    event ZapRedeemed(address indexed sender, address indexed to, uint256 sharesIn, uint256 ethOut);

    enum Action {
        MINT,
        REDEEM
    }

    error NotPoolManager();
    error NoValue();
    error ZeroShares();
    error RouteMismatch();
    error BadRoute(address component);
    error InsufficientShares(uint256 got, uint256 want);
    error EthRefundFailed();
    error UsdgNotSettled(int256 delta);
    error RouteTooThin(address component);
    error InsufficientEth(uint256 got, uint256 want);

    struct CallbackData {
        uint256 shares;
        PoolKey ethUsdg;
        PoolKey[] stockPools;
        address[] comps;
        uint256[] amounts;
    }

    constructor(IPoolManager poolManager_, IndexVault vault_, address usdg_) {
        poolManager = poolManager_;
        vault = vault_;
        usdg = usdg_;
    }

    receive() external payable {}

    /// @notice Buy the basket with ETH and mint `shares` hMAG7 in one transaction.
    /// @param ethUsdg     the ETH/USDG V4 pool (currency0 must be native ETH)
    /// @param stockPools  one USDG/<component> pool per component, in the same
    ///                    order as vault.allComponents()
    /// @param shares      how many shares get minted (before the mint fee)
    /// @param minSharesOut lower bound on what you receive (mint fee + slippage)
    function zapMint(
        PoolKey calldata ethUsdg,
        PoolKey[] calldata stockPools,
        uint256 shares,
        uint256 minSharesOut,
        address to
    ) external payable nonReentrant returns (uint256 sharesOut) {
        if (msg.value == 0) revert NoValue();
        if (shares == 0) revert ZeroShares();

        address[] memory comps = vault.allComponents();
        if (stockPools.length != comps.length) revert RouteMismatch();
        uint256[] memory amounts = vault.amountsForMint(shares);

        poolManager.unlock(
            abi.encode(
                Action.MINT,
                abi.encode(
                    CallbackData({
                        shares: shares, ethUsdg: ethUsdg, stockPools: stockPools, comps: comps, amounts: amounts
                    })
                )
            )
        );

        // The components are now on this contract; mint in-kind to the user.
        for (uint256 i = 0; i < comps.length; i++) {
            IERC20(comps[i]).forceApprove(address(vault), amounts[i]);
        }
        sharesOut = vault.mint(shares, to);
        if (sharesOut < minSharesOut) revert InsufficientShares(sharesOut, minSharesOut);

        // Return leftovers: component dust and unspent ETH.
        for (uint256 i = 0; i < comps.length; i++) {
            uint256 dust = IERC20(comps[i]).balanceOf(address(this));
            if (dust > 0) IERC20(comps[i]).safeTransfer(msg.sender, dust);
        }
        uint256 left = address(this).balance;
        if (left > 0) {
            (bool ok,) = msg.sender.call{value: left}("");
            if (!ok) revert EthRefundFailed();
        }
        // `left` is the whole balance, which may include ETH donated via the open
        // receive(). Clamp so a donation can't underflow the reported spend and
        // revert the mint (griefing DoS). See SECURITY.md.
        emit ZapMinted(msg.sender, to, msg.value > left ? msg.value - left : 0, sharesOut);
    }

    /// @notice The reverse path: hMAG7 in, ETH out — also in one transaction.
    ///         Without this, a redeem hands you seven stock tokens you have to
    ///         sell yourself; whoever enters with ETH wants to exit with ETH.
    /// @param shares      how much hMAG7 you hand in (approve this contract first)
    /// @param minEthOut   lower bound on the ETH you get back
    function zapRedeem(
        PoolKey calldata ethUsdg,
        PoolKey[] calldata stockPools,
        uint256 shares,
        uint256 minEthOut,
        address to
    ) external nonReentrant returns (uint256 ethOut) {
        if (shares == 0) revert ZeroShares();

        address[] memory comps = vault.allComponents();
        if (stockPools.length != comps.length) revert RouteMismatch();

        IERC20(address(vault)).safeTransferFrom(msg.sender, address(this), shares);
        vault.redeem(shares, address(this)); // yields the components pro-rata

        uint256[] memory amounts = new uint256[](comps.length);
        for (uint256 i = 0; i < comps.length; i++) {
            amounts[i] = IERC20(comps[i]).balanceOf(address(this));
        }

        poolManager.unlock(
            abi.encode(
                Action.REDEEM,
                abi.encode(
                    CallbackData({
                        shares: shares, ethUsdg: ethUsdg, stockPools: stockPools, comps: comps, amounts: amounts
                    })
                )
            )
        );

        ethOut = address(this).balance;
        if (ethOut < minEthOut) revert InsufficientEth(ethOut, minEthOut);
        (bool ok,) = to.call{value: ethOut}("");
        if (!ok) revert EthRefundFailed();
        emit ZapRedeemed(msg.sender, to, shares, ethOut);
    }

    /// @dev All swaps happen inside this; the PoolManager only settles up at the end.
    function unlockCallback(bytes calldata raw) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        (Action action, bytes memory payload) = abi.decode(raw, (Action, bytes));
        CallbackData memory d = abi.decode(payload, (CallbackData));
        if (action == Action.REDEEM) {
            _redeemToEth(d);
            return "";
        }

        // 1. Buy each component exactly (exact-output), paid in ETH or in USDG —
        //    whichever pool the caller supplied as the cheapest.
        int256 usdgDelta = 0;
        int256 ethDelta = 0;
        for (uint256 i = 0; i < d.comps.length; i++) {
            PoolKey memory k = d.stockPools[i];
            address comp = d.comps[i];

            bool compIsCurrency1;
            address payWith;
            if (k.currency1 == comp) {
                compIsCurrency1 = true;
                payWith = k.currency0;
            } else if (k.currency0 == comp) {
                compIsCurrency1 = false;
                payWith = k.currency1;
            } else {
                revert BadRoute(comp);
            }
            // we only pay in ETH or USDG; anything else we cannot settle
            if (payWith != address(0) && payWith != usdg) revert BadRoute(comp);

            (int256 a0, int256 a1) = _swap(k, compIsCurrency1, int256(d.amounts[i]));
            int256 paid = compIsCurrency1 ? a0 : a1; // negative: this is what we owe
            int256 got = compIsCurrency1 ? a1 : a0; // positive: this is what we bought

            // An exact-output swap on a too-thin pool only partially fills: you get
            // less than requested. Without this check we would still take the full
            // amount and the unlock blows up on CurrencyNotSettled — an unreadable revert.
            if (got < int256(d.amounts[i])) revert RouteTooThin(comp);

            if (payWith == usdg) usdgDelta += paid;
            else ethDelta += paid;
        }

        // 2. Buy exactly the USDG debt with ETH (exact-output), so USDG nets to 0.
        //    If everything already routes directly through ETH pools, we skip this swap.
        if (usdgDelta < 0) {
            PoolKey memory k = d.ethUsdg;
            // by V4 convention currency0 is the lower address → native ETH (0x0) is always currency0
            if (k.currency0 != address(0) || k.currency1 != usdg) revert BadRoute(usdg);
            (int256 a0, int256 a1) = _swap(k, true, -usdgDelta);
            ethDelta += a0;
            usdgDelta += a1;
        }
        if (usdgDelta != 0) revert UsdgNotSettled(usdgDelta);

        // 3. Settle exactly the ETH debt — sending more leaves a positive delta
        //    behind and then the PoolManager refuses to close the unlock.
        if (ethDelta < 0) poolManager.settle{value: uint256(-ethDelta)}();

        // 4. Collect the purchased components.
        for (uint256 i = 0; i < d.comps.length; i++) {
            poolManager.take(d.comps[i], address(this), d.amounts[i]);
        }
        return "";
    }

    /// @dev Sell the components the redeem yielded into ETH. Mirror image
    ///      of the mint: there we buy exact-output, here we sell exact-input
    ///      (we want to offload everything, and the market decides how much ETH that yields).
    function _redeemToEth(CallbackData memory d) internal {
        int256 usdgDelta = 0;
        int256 ethDelta = 0;

        for (uint256 i = 0; i < d.comps.length; i++) {
            if (d.amounts[i] == 0) continue;
            PoolKey memory k = d.stockPools[i];
            address comp = d.comps[i];

            bool compIsCurrency0;
            address proceeds;
            if (k.currency0 == comp) {
                compIsCurrency0 = true;
                proceeds = k.currency1;
            } else if (k.currency1 == comp) {
                compIsCurrency0 = false;
                proceeds = k.currency0;
            } else {
                revert BadRoute(comp);
            }
            if (proceeds != address(0) && proceeds != usdg) revert BadRoute(comp);

            (int256 a0, int256 a1) = _swap(k, compIsCurrency0, -int256(d.amounts[i])); // exact input
            int256 gained = compIsCurrency0 ? a1 : a0;
            if (proceeds == usdg) usdgDelta += gained;
            else ethDelta += gained;

            // we owe the component to the pool
            poolManager.sync(comp);
            IERC20(comp).safeTransfer(address(poolManager), d.amounts[i]);
            poolManager.settle();
        }

        // all USDG proceeds to ETH in one go; that USDG debt cancels within
        // the same unlock against the credit from the swaps above
        if (usdgDelta > 0) {
            if (d.ethUsdg.currency0 != address(0) || d.ethUsdg.currency1 != usdg) revert BadRoute(usdg);
            (int256 b0,) = _swap(d.ethUsdg, false, -usdgDelta);
            ethDelta += b0;
        }

        if (ethDelta > 0) poolManager.take(address(0), address(this), uint256(ethDelta));
    }

    /// @dev exact-output swap; returns the two deltas of this pool.
    ///      V4 packs two int128s into one int256 (amount0 high, amount1 low) —
    ///      unpack exactly like BalanceDeltaLibrary: sar for the high half,
    ///      signextend for the low one, otherwise the sign is wrong.
    function _swap(PoolKey memory key, bool buyCurrency1, int256 exactOut)
        internal
        returns (int256 amount0, int256 amount1)
    {
        bool zeroForOne = buyCurrency1; // buying currency1 = selling currency0
        int256 packed = poolManager.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: exactOut, // > 0 = exact output
                sqrtPriceLimitX96: zeroForOne ? MIN_SQRT_PRICE + 1 : MAX_SQRT_PRICE - 1
            }),
            ""
        );
        int128 a0;
        int128 a1;
        assembly ("memory-safe") {
            a0 := sar(128, packed)
            a1 := signextend(15, packed)
        }
        amount0 = int256(a0);
        amount1 = int256(a1);
    }
}