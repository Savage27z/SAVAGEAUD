// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC1155} from "openzeppelin-contracts/token/ERC1155/ERC1155.sol";
import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "openzeppelin-contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable2Step, Ownable} from "openzeppelin-contracts/access/Ownable2Step.sol";
import {Pausable} from "openzeppelin-contracts/utils/Pausable.sol";

error SaleNotPending();
error SaleNotOpen();
error SaleNotClosed();
error InvalidTierId();
error ZeroQuantity();
error ZeroAddress();
error InvalidTierPricing();
error InvalidMaxUnits();
error MaxUnitsExceeded();
error InsufficientReserve();
error NoExcessReserve();
error ClaimWindowNotOpen();
error ClaimWindowNotClosed();
error RenounceDisabled();
error PauseOnlyDuringSale();
error CannotCloseWhilePaused();

/**
 * @title  MonkeyBet
 * @notice Fixed-strike, protocol-written put options on `backedToken`, sold as an
 *         ERC-1155 across 3 fixed tiers (ids 0/1/2), priced and settled entirely in
 *         `usdg`. Buying tier `i` costs `costs[i]` USDG and grants the right - not the
 *         obligation - to later hand back 1 unit of `backedToken` plus 1 tier-`i` NFT in
 *         exchange for `buybackPrices[i]` USDG, regardless of `backedToken`'s market
 *         price at that time.
 *
 *         Lifecycle is Pending -> Open -> Closed, owner-controlled via
 *         openSale()/closeSale() (same pattern as RaiseController), with no reopen path.
 *         closeSale() is what starts the fixed WAIT_PERIOD (90 days); once that elapses,
 *         a fixed CLAIM_WINDOW (48 hours, hardcoded, not owner-adjustable) opens during
 *         which holders can redeem. After the window closes, owner sweeps whatever's
 *         left.
 *
 *         Premium (the `cost` paid to buy) is forwarded straight to `treasury` on every
 *         purchase - this contract never treats it as part of the payout reserve. The
 *         reserve backing buybacks is funded separately via depositReserve() and is
 *         tracked against `totalLiability`, a running total of `buybackPrices[i] *
 *         (units of tier i sold and not yet redeemed)`. Every buy() checks the reserve
 *         actually covers the new liability before minting - so even if every buyer picks
 *         the priciest tier, a sale can never mint more than the reserve can pay out.
 *         `totalUnitsSold` is a separate, monotonic cap (never decremented) enforcing the
 *         hard aggregate unit ceiling across all 3 tiers combined, independent of price
 *         mix.
 *
 *         withdrawExcessReserve() lets owner pull out anything above current
 *         `totalLiability` at any time - as units get redeemed (burning the liability
 *         they represented) or simply never get sold, that headroom opens up without
 *         waiting for the sale to close.
 *
 *         Deploys paused - buy() and redeem() both revert until owner calls unpause(),
 *         so a deployment can go out (and a frontend can be pointed at it) before it's
 *         actually live for anyone to call directly. pause()/unpause() only work during
 *         Pending or Open (the buy period) - once the sale is Closed, neither can be
 *         called again, ever. closeSale() itself reverts if the contract is currently
 *         paused, so the sale can never actually close into a paused state - this
 *         guarantees redeem() can never be blocked by the owner once holders are relying
 *         on the claim window being open. Every other admin function is owner-gated
 *         already and was never subject to pause.
 */
contract MonkeyBet is ERC1155, Ownable2Step, Pausable {
    using SafeERC20 for IERC20;

    enum State {
        Pending,
        Open,
        Closed
    }

    uint256 public constant TIER_COUNT = 3;
    uint256 public constant WAIT_PERIOD = 90 days;
    uint256 public constant CLAIM_WINDOW = 48 hours;

    string public name;
    string public symbol;

    IERC20 public immutable usdg;
    IERC20 public immutable backedToken;
    uint256 internal immutable backedTokenUnit;
    address public immutable treasury;
    uint256 public immutable maxUnits;

    uint256[TIER_COUNT] public costs;
    uint256[TIER_COUNT] public buybackPrices;

    State public state;
    uint256 public closedAt;

    uint256 public totalUnitsSold;
    uint256 public totalLiability;

    event SaleOpened();
    event SaleClosed(uint256 closedAt);
    event Bought(address indexed buyer, uint256 indexed tierId, uint256 quantity, uint256 cost);
    event Redeemed(address indexed holder, uint256 indexed tierId, uint256 quantity, uint256 payout);
    event ReserveDeposited(uint256 amount);
    event ExcessWithdrawn(uint256 amount);
    event UnclaimedSwept(uint256 usdgAmount, uint256 backedTokenAmount);

    constructor(
        string memory name_,
        string memory symbol_,
        string memory uri_,
        IERC20 usdg_,
        IERC20 backedToken_,
        uint256[TIER_COUNT] memory costs_,
        uint256[TIER_COUNT] memory buybackPrices_,
        uint256 maxUnits_,
        address treasury_,
        address owner_
    ) ERC1155(uri_) Ownable(owner_) {
        if (address(usdg_) == address(0) || address(backedToken_) == address(0) || treasury_ == address(0)) {
            revert ZeroAddress();
        }
        if (maxUnits_ == 0) revert InvalidMaxUnits();

        name = name_;
        symbol = symbol_;
        usdg = usdg_;
        backedToken = backedToken_;
        backedTokenUnit = 10 ** IERC20Metadata(address(backedToken_)).decimals();
        treasury = treasury_;
        maxUnits = maxUnits_;

        for (uint256 i = 0; i < TIER_COUNT; i++) {
            if (buybackPrices_[i] <= costs_[i]) revert InvalidTierPricing();
            costs[i] = costs_[i];
            buybackPrices[i] = buybackPrices_[i];
        }

        _pause();
    }

    /// @notice Owner-only pause of buy(). Only callable during Pending or Open - reverts
    /// once the sale is Closed, since redeem() must never be blockable after that point.
    function pause() external onlyOwner {
        if (state == State.Closed) revert PauseOnlyDuringSale();
        _pause();
    }

    /// @notice Owner-only unpause of buy(). Only callable during Pending or Open - see
    /// pause() above.
    function unpause() external onlyOwner {
        if (state == State.Closed) revert PauseOnlyDuringSale();
        _unpause();
    }

    /// @notice Opens the sale for buy()s. Callable once, by owner only.
    function openSale() external onlyOwner {
        if (state != State.Pending) revert SaleNotPending();
        state = State.Open;
        emit SaleOpened();
    }

    /// @notice Closes the sale to further buy()s and starts the WAIT_PERIOD countdown to
    /// the claim window. Callable once, by owner only, irreversible. Reverts if currently
    /// paused - since pause()/unpause() can no longer be called once Closed, this
    /// guarantees the contract can never close into a state where redeem() is stuck
    /// blocked by pause for the entire claim window.
    function closeSale() external onlyOwner {
        if (state != State.Open) revert SaleNotOpen();
        if (paused()) revert CannotCloseWhilePaused();
        state = State.Closed;
        closedAt = block.timestamp;
        emit SaleClosed(block.timestamp);
    }

    /// @notice Buy `quantity` tier-`tierId` passes for `costs[tierId] * quantity` USDG,
    /// forwarded straight to `treasury`. Reverts if this would push total units sold past
    /// `maxUnits`, or push `totalLiability` past what the contract's own USDG balance can
    /// cover.
    function buy(uint256 tierId, uint256 quantity) external whenNotPaused {
        if (state != State.Open) revert SaleNotOpen();
        if (tierId >= TIER_COUNT) revert InvalidTierId();
        if (quantity == 0) revert ZeroQuantity();

        uint256 newTotalUnits = totalUnitsSold + quantity;
        if (newTotalUnits > maxUnits) revert MaxUnitsExceeded();
        totalUnitsSold = newTotalUnits;

        uint256 newLiability = totalLiability + buybackPrices[tierId] * quantity;
        if (usdg.balanceOf(address(this)) < newLiability) revert InsufficientReserve();
        totalLiability = newLiability;

        uint256 cost = costs[tierId] * quantity;
        usdg.safeTransferFrom(msg.sender, treasury, cost);

        _mint(msg.sender, tierId, quantity, "");
        emit Bought(msg.sender, tierId, quantity, cost);
    }

    /// @notice Redeem `quantity` tier-`tierId` passes during the claim window: burns the
    /// passes, pulls `quantity` whole units of `backedToken` from the caller, pays out
    /// `buybackPrices[tierId] * quantity` USDG. Deliberately not `whenNotPaused` - pause()
    /// can never be called once the sale is Closed (see pause()/closeSale()), so this can
    /// never be blocked by the owner.
    function redeem(uint256 tierId, uint256 quantity) external {
        if (state != State.Closed) revert SaleNotClosed();
        if (tierId >= TIER_COUNT) revert InvalidTierId();
        if (quantity == 0) revert ZeroQuantity();

        uint256 start = claimWindowStart();
        uint256 end = claimWindowEnd();
        if (block.timestamp < start || block.timestamp >= end) revert ClaimWindowNotOpen();

        _burn(msg.sender, tierId, quantity);

        uint256 payout = buybackPrices[tierId] * quantity;
        totalLiability -= payout;

        backedToken.safeTransferFrom(msg.sender, address(this), quantity * backedTokenUnit);
        usdg.safeTransfer(msg.sender, payout);

        emit Redeemed(msg.sender, tierId, quantity, payout);
    }

    /// @notice Owner-only top-up of the USDG reserve backing buybacks.
    function depositReserve(uint256 amount) external onlyOwner {
        usdg.safeTransferFrom(msg.sender, address(this), amount);
        emit ReserveDeposited(amount);
    }

    /// @notice Pulls out any USDG held above current `totalLiability`, straight to
    /// `treasury`. Safe at any time - `totalLiability` always reflects exactly what's
    /// still owed against outstanding, unredeemed passes.
    function withdrawExcessReserve() external onlyOwner {
        uint256 balance = usdg.balanceOf(address(this));
        if (balance <= totalLiability) revert NoExcessReserve();
        uint256 excess = balance - totalLiability;
        usdg.safeTransfer(treasury, excess);
        emit ExcessWithdrawn(excess);
    }

    /// @notice After the claim window has fully closed, sweeps whatever USDG and
    /// `backedToken` remain in the contract to `treasury`.
    function sweepUnclaimed() external onlyOwner {
        if (state != State.Closed) revert SaleNotClosed();
        if (block.timestamp < claimWindowEnd()) revert ClaimWindowNotClosed();

        uint256 usdgBalance = usdg.balanceOf(address(this));
        if (usdgBalance > 0) usdg.safeTransfer(treasury, usdgBalance);

        uint256 backedBalance = backedToken.balanceOf(address(this));
        if (backedBalance > 0) backedToken.safeTransfer(treasury, backedBalance);

        emit UnclaimedSwept(usdgBalance, backedBalance);
    }

    function setURI(string calldata uri_) external onlyOwner {
        _setURI(uri_);
    }

    /// @notice Timestamp the claim window opens. Meaningless (returns WAIT_PERIOD) until
    /// closeSale() has been called.
    function claimWindowStart() public view returns (uint256) {
        return closedAt + WAIT_PERIOD;
    }

    /// @notice Timestamp the claim window closes: CLAIM_WINDOW (48h), fixed.
    function claimWindowEnd() public view returns (uint256) {
        return claimWindowStart() + CLAIM_WINDOW;
    }

    /// @notice How many more units (across all tiers) can still be sold under `maxUnits`.
    function remainingCapacity() external view returns (uint256) {
        return maxUnits - totalUnitsSold;
    }

    /// @notice How much USDG could be withdrawn via withdrawExcessReserve() right now.
    function excessReserve() external view returns (uint256) {
        uint256 balance = usdg.balanceOf(address(this));
        return balance > totalLiability ? balance - totalLiability : 0;
    }

    /// @dev Disabled - owner is the only address that can move the sale through its
    /// states and is required for every settlement function; renouncing would strand
    /// reserve funds and outstanding passes with no recovery path.
    function renounceOwnership() public override onlyOwner {
        revert RenounceDisabled();
    }
}
