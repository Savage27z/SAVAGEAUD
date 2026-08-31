// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "openzeppelin-contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC1155} from "openzeppelin-contracts/token/ERC1155/IERC1155.sol";
import {ERC1155Holder} from "openzeppelin-contracts/token/ERC1155/utils/ERC1155Holder.sol";
import {Ownable2Step, Ownable} from "openzeppelin-contracts/access/Ownable2Step.sol";

import {RaiseToken} from "./RaiseToken.sol";

error RaiseNotOpen();
error RaiseNotClosed();
error InvalidRaiseState();
error AlreadySettled();
error InvalidAllocationAmount();
error InsufficientAllocation();
error NotFinalized();
error NothingToClaim();

/**
 * @title  RaiseController
 * @notice Runs a fixed-price ($1 USDC = 1 token) raise gated by AllocationNFT
 *         ownership, then permanently burns its own mint access on the token.
 *
 *         No whitelist, no per-wallet caps: every AllocationNFT pass is identical and
 *         worth a fixed `allocationPerNFT` claim. contribute() takes a plain USDC
 *         amount - no tokenIds, no off-chain lookups - and pulls exactly as many passes
 *         as needed (rounded up) straight out of the caller's balance in one
 *         `safeTransferFrom`, permanently retiring them. Using less than a whole pass's
 *         worth on the last one forfeits the remainder, same as using less than a
 *         card's full value did before - just computed automatically now instead of
 *         the caller choosing which specific card absorbs the partial use.
 *
 *         The raise window is manually controlled by `owner` (the same multisig that
 *         controls TaxHook's treasury timelock) via `openRaise()`/`closeRaise()` rather
 *         than fixed timestamps - deliberately, to avoid getting a raise window wrong
 *         and being stuck with it. `closeRaise()` is one-way: once closed, the raise can
 *         never reopen, only proceed to `finalize()`. This is the one privileged role in
 *         the contract; it can only ever move the raise forward (Pending -> Open ->
 *         Closed), never touch funds, and has no role at all in `finalize()`, `claim()`,
 *         or the token itself.
 *
 *         USDC never touches this contract - contribute() forwards it straight to
 *         `treasury`. That means there is no minimum-raise concept and no refund path:
 *         once a contribution is sent, it's gone to treasury regardless of how the raise
 *         turns out. This is a deliberate, accepted tradeoff.
 *
 *         Flow: contribute() while Open records entitlement and forwards USDC to
 *         treasury, but mints nothing. finalize() (permissionless, once, after
 *         closeRaise()) mints the sold supply to this contract for claim() plus the
 *         team's 15% straight to treasury, then permanently revokes minting.
 *
 *         Pool creation and liquidity seeding are handled entirely outside this
 *         contract - see the deploy script.
 */
contract RaiseController is Ownable2Step, ERC1155Holder {
    using SafeERC20 for IERC20;

    enum RaiseState {
        Pending,
        Open,
        Closed
    }

    uint256 internal constant TEAM_BPS = 1500; // 15% of tokens sold
    uint256 internal constant BPS_DENOMINATOR = 10_000;
    uint256 internal constant ALLOCATION_USD = 50; // $50 worth of USDC per AllocationNFT pass
    uint256 internal constant ALLOCATION_ID = 0; // AllocationNFT.ALLOCATION_ID

    RaiseToken public immutable token;
    IERC20 public immutable usdc;
    IERC1155 public immutable allocationNFT;
    address public immutable treasury;
    uint256 public immutable allocationPerNFT;

    uint8 internal immutable tokenDecimals;
    uint8 internal immutable usdcDecimals;

    RaiseState public state;
    mapping(address => uint256) public contributed;
    uint256 public totalRaised;
    bool public finalized;

    event RaiseOpened();
    event RaiseClosed();
    event Contributed(address indexed wallet, uint256 passesUsed, uint256 usdcAmount);
    event Finalized(uint256 tokensSold, uint256 teamTokens);
    event Claimed(address indexed wallet, uint256 amount);

    constructor(RaiseToken token_, IERC20 usdc_, IERC1155 allocationNFT_, address treasury_, address owner_)
        Ownable(owner_)
    {
        token = token_;
        usdc = usdc_;
        allocationNFT = allocationNFT_;
        treasury = treasury_;

        tokenDecimals = token_.decimals();
        uint8 usdcDecimals_ = IERC20Metadata(address(usdc_)).decimals();
        usdcDecimals = usdcDecimals_;
        allocationPerNFT = ALLOCATION_USD * (10 ** usdcDecimals_);
    }

    /// @notice Opens the raise for contributions. Callable once, by owner only.
    function openRaise() external onlyOwner {
        if (state != RaiseState.Pending) revert InvalidRaiseState();
        state = RaiseState.Open;
        emit RaiseOpened();
    }

    /// @notice Closes the raise to further contributions. Callable once, by owner only,
    /// and irreversible - there is no reopen path.
    function closeRaise() external onlyOwner {
        if (state != RaiseState.Open) revert InvalidRaiseState();
        state = RaiseState.Closed;
        emit RaiseClosed();
    }

    /// @notice Contribute `usdcAmount` toward the raise. Pulls
    /// ceil(usdcAmount / allocationPerNFT) AllocationNFT passes from the caller's own
    /// balance in one transfer and permanently retires them - reverts if the caller
    /// doesn't hold enough. USDC is forwarded straight to `treasury` - this contract
    /// never holds it.
    function contribute(uint256 usdcAmount) external {
        if (state != RaiseState.Open) revert RaiseNotOpen();
        if (usdcAmount == 0) revert InvalidAllocationAmount();

        uint256 passesNeeded = (usdcAmount + allocationPerNFT - 1) / allocationPerNFT;
        if (allocationNFT.balanceOf(msg.sender, ALLOCATION_ID) < passesNeeded) revert InsufficientAllocation();

        allocationNFT.safeTransferFrom(msg.sender, address(this), ALLOCATION_ID, passesNeeded, "");

        contributed[msg.sender] += usdcAmount;
        totalRaised += usdcAmount;

        usdc.safeTransferFrom(msg.sender, treasury, usdcAmount);

        emit Contributed(msg.sender, passesNeeded, usdcAmount);
    }

    /// @notice Permissionless, callable once after closeRaise(). Mints the sold supply
    /// to this contract for claim(), mints the team's 15% straight to treasury, and
    /// permanently revokes minting. `owner` has no role in this function.
    function finalize() external {
        if (state != RaiseState.Closed) revert RaiseNotClosed();
        if (finalized) revert AlreadySettled();
        finalized = true;

        uint256 tokensSold = _toTokenUnits(totalRaised);
        uint256 teamTokens = (tokensSold * TEAM_BPS) / BPS_DENOMINATOR;

        token.mint(address(this), tokensSold);
        token.mint(treasury, teamTokens);
        token.revokeMintingForever();

        emit Finalized(tokensSold, teamTokens);
    }

    /// @notice Claim tokens owed from a successful raise. Opens exactly when finalize()
    /// runs, since that's what sets `finalized`.
    function claim() external {
        if (!finalized) revert NotFinalized();

        uint256 owed = contributed[msg.sender];
        if (owed == 0) revert NothingToClaim();
        contributed[msg.sender] = 0;

        uint256 amount = _toTokenUnits(owed);
        IERC20(address(token)).safeTransfer(msg.sender, amount);

        emit Claimed(msg.sender, amount);
    }

    function _toTokenUnits(uint256 usdcAmount) internal view returns (uint256) {
        if (tokenDecimals >= usdcDecimals) {
            return usdcAmount * (10 ** (tokenDecimals - usdcDecimals));
        }
        return usdcAmount / (10 ** (usdcDecimals - tokenDecimals));
    }
}
