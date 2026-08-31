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
error TokenNotSet();
error TokenAlreadySet();
error ZeroAddress();
error RenounceDisabled();

/**
 * @title  RaiseController
 * @notice Runs a fixed-price raise gated by AllocationNFT ownership, then settles by
 *         burning down a token supply it never minted. Price is $1 USDC =
 *         `tokensPerUsdcUnit` tokens, immutable per deployment (1 for the standard $1=1
 *         token ratio).
 *
 *         Deploy order is controller-first: this contract deploys with no `token` at
 *         all, then RaiseToken deploys second, minting its ENTIRE fixed supply straight
 *         to this contract's already-known address in RaiseToken's own constructor -
 *         RaiseToken has no mint() function, ever, by design (see RaiseToken.sol). That
 *         supply is computed off-chain by the deploy script as the maximum this raise
 *         could ever sell (every AllocationNFT pass redeemed) plus the team's 15% on top.
 *         `setToken()` (owner-only, callable exactly once) then wires this contract to
 *         the real token address. Between RaiseToken's deploy and that call, a wrong or
 *         malicious setToken() cannot steal anything - the real supply already sits at
 *         this contract's own address regardless of what `token` points to - it can only
 *         misdirect claim()/finalize() until corrected, a materially smaller risk than a
 *         live mint-assignment window.
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
 *         never reopen, only proceed to `finalize()`. `owner` also gates `finalize()`
 *         itself - the claim phase only opens when `owner` deliberately triggers it, not
 *         automatically the moment the raise closes - but has no power over funds
 *         directly and no role at all in `claim()` or the token itself.
 *
 *         USDC never touches this contract - contribute() forwards it straight to
 *         `treasury`. That means there is no minimum-raise concept and no refund path:
 *         once a contribution is sent, it's gone to treasury regardless of how the raise
 *         turns out. This is a deliberate, accepted tradeoff.
 *
 *         Flow: contribute() while Open records entitlement and forwards USDC to
 *         treasury. finalize() (owner-only, once, after closeRaise()) computes the
 *         actual tokens sold plus the team's 15% of that, burns everything above that
 *         total out of this contract's pre-funded balance, and sends the team's cut
 *         straight to treasury - what's left is exactly what claim() disburses.
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

    uint256 public constant TEAM_BPS = 1500; // 15% of tokens sold
    uint256 public constant BPS_DENOMINATOR = 10_000;
    uint256 public constant ALLOCATION_USD = 50; // $50 worth of USDC per AllocationNFT pass
    uint256 internal constant ALLOCATION_ID = 0; // AllocationNFT.ALLOCATION_ID
    uint8 public constant TOKEN_DECIMALS = 18; // RaiseToken always uses the ERC20 default

    RaiseToken public token;
    IERC20 public immutable usdc;
    IERC1155 public immutable allocationNFT;
    address public immutable treasury;
    uint256 public immutable allocationPerNFT;
    uint256 public immutable tokensPerUsdcUnit;

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
    event TokenSet(RaiseToken token);

    constructor(IERC20 usdc_, IERC1155 allocationNFT_, address treasury_, address owner_, uint256 tokensPerUsdcUnit_)
        Ownable(owner_)
    {
        if (tokensPerUsdcUnit_ == 0) revert InvalidAllocationAmount();
        usdc = usdc_;
        allocationNFT = allocationNFT_;
        treasury = treasury_;
        tokensPerUsdcUnit = tokensPerUsdcUnit_;

        uint8 usdcDecimals_ = IERC20Metadata(address(usdc_)).decimals();
        usdcDecimals = usdcDecimals_;
        allocationPerNFT = ALLOCATION_USD * (10 ** usdcDecimals_);
    }

    /// @notice One-time wiring call: points this contract at the RaiseToken deployed
    /// after it, which minted its entire fixed supply straight to this contract's
    /// address at construction. Owner-only, callable exactly once. A wrong or malicious
    /// call here cannot steal the real supply - it already sits at this contract's own
    /// address regardless - it can only misdirect claim()/finalize() until corrected.
    function setToken(RaiseToken token_) external onlyOwner {
        if (address(token) != address(0)) revert TokenAlreadySet();
        if (address(token_) == address(0)) revert ZeroAddress();
        token = token_;
        emit TokenSet(token_);
    }

    /// @notice Opens the raise for contributions. Callable once, by owner only. Verifies
    /// setToken() has already been called - catching a misconfigured deploy before any
    /// contribution is accepted, rather than after funds have already moved and
    /// finalize() can never succeed.
    function openRaise() external onlyOwner {
        if (state != RaiseState.Pending) revert InvalidRaiseState();
        if (address(token) == address(0)) revert TokenNotSet();
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

    /// @notice Owner-only, callable once after closeRaise(). Computes tokens actually
    /// sold plus the team's 15% of that, burns everything above that total out of this
    /// contract's pre-funded balance (the gap between the max-sellable supply RaiseToken
    /// minted here at deploy and what was actually raised), and sends the team's cut
    /// straight to treasury - what remains is exactly what claim() disburses. Gated by
    /// `owner` deliberately - this is what opens the claim phase, so it shouldn't be
    /// triggerable by just anyone the instant the raise closes.
    function finalize() external onlyOwner {
        if (state != RaiseState.Closed) revert RaiseNotClosed();
        if (finalized) revert AlreadySettled();
        finalized = true;

        uint256 tokensSold = _toTokenUnits(totalRaised);
        uint256 teamTokens = (tokensSold * TEAM_BPS) / BPS_DENOMINATOR;

        uint256 balance = IERC20(address(token)).balanceOf(address(this));
        uint256 keep = tokensSold + teamTokens;
        if (balance > keep) {
            token.burn(balance - keep);
        }
        IERC20(address(token)).safeTransfer(treasury, teamTokens);

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

    /// @dev Disabled. `owner` is the only address that can ever move the raise from
    /// Pending -> Open -> Closed; renouncing mid-raise would strand it in whatever state
    /// it was in forever, with no recovery path.
    function renounceOwnership() public override onlyOwner {
        revert RenounceDisabled();
    }

    function _toTokenUnits(uint256 usdcAmount) internal view returns (uint256) {
        uint256 base;
        if (TOKEN_DECIMALS >= usdcDecimals) {
            base = usdcAmount * (10 ** (TOKEN_DECIMALS - usdcDecimals));
        } else {
            base = usdcAmount / (10 ** (usdcDecimals - TOKEN_DECIMALS));
        }
        return base * tokensPerUsdcUnit;
    }
}
