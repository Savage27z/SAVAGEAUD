// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {VaultBaseV2} from "./flap/VaultBaseV2.sol";
import {VaultUISchema, VaultMethodSchema, FieldDescriptor, ApproveAction} from "./flap/IVaultSchemasV1.sol";
import {IFlapTaxTokenV3} from "./flap/IFlapTaxTokenV3.sol";
import {
    ISlvrVoteEscrow, ISlvrStaking, IUniswapV2Pair, IUniswapV2Factory,
    IWETH, IERC20, IERC721Receiver
} from "./interfaces/External.sol";
import {SafeERC20} from "@openzeppelin/token/ERC20/utils/SafeERC20.sol";
import {IERC20 as IERC20OZ} from "@openzeppelin/token/ERC20/IERC20.sol";

/// @title SlvrSnowballVault
/// @notice Flap tax-token beneficiary vault (Robinhood Chain):
///   tax ETH -> buy SLVR (přímo přes UniV2 pár) -> PERMANENT lock ve voteEscrow
///   (SLVR se pálí, konstantní 4x staking weight) -> staking ETH rewards
///   -> buyback taxTokenu (jeho V2 pár po graduaci) -> burn
///
/// Design: žádné uživatelské vklady, žádný admin, žádný upgrade. crank() je
/// permissionless s bounty. Permanent lock je nevratný by design (SLVR burned).
contract SlvrSnowballVault is VaultBaseV2, IERC721Receiver {
    using SafeERC20 for IERC20OZ;

    // ---------- config (set once via initialize) ----------
    address public factoryAddr;
    address public taxToken;
    address public feeRecipient;
    uint16  public crankBountyBps;
    uint16  public maxImpactBps;
    uint256 public minCrankEth;

    ISlvrVoteEscrow public voteEscrow;
    ISlvrStaking    public staking;
    address public slvr;
    IUniswapV2Pair public slvrEthPair;
    IWETH public weth;

    // ---------- state ----------
    uint256 public veTokenId;
    uint256 public totalSlvrLocked;
    uint256 public totalTaxTokenBurned;
    uint256 public totalEthProcessed;
    uint256 public totalRewardsEth;
    /// @notice Naakumulovane fee cekajici na withdrawFees() (pull pattern —
    /// revertujici feeRecipient nemuze zablokovat crank).
    uint256 public accruedFees;
    /// @notice Tax rate tax tokenu v bps, cachovana pri prvnim uspesnem cteni
    /// (Flap Rule 002 — fee se pocita z tax rate).
    uint16 public taxRateBps;

    address private constant DEAD = 0x000000000000000000000000000000000000dEaD;
    bool private _entered;

    event Cranked(address indexed caller, uint256 ethIn, uint256 slvrLocked, uint256 rewardsEth, uint256 burned);
    event LockCreated(uint256 indexed tokenId);
    event FeesWithdrawn(address indexed to, uint256 amount);
    event ClaimFailed(bytes reason);
    event EmergencyWithdrawNative(address indexed to, uint256 amount);
    event EmergencyWithdrawToken(address indexed token, address indexed to, uint256 amount);

    // Rule UI-01: reverty jen jako require s literalem (UI neumi dekodovat custom errors)
    modifier nonReentrant() { require(!_entered, "reentrancy"); _entered = true; _; _entered = false; }
    modifier onlyGuardian() { require(msg.sender == _getGuardian(), "only guardian"); _; }

    function initialize(
        address _taxToken, address _feeRecipient,
        uint16 _crankBountyBps, uint16 _maxImpactBps, uint256 _minCrankEth,
        address _voteEscrow, address _staking, address _slvr, address _slvrEthPair
    ) external {
        require(factoryAddr == address(0), "already initialized");
        require(_crankBountyBps <= 100, "bounty cap");
        factoryAddr = msg.sender;
        taxToken = _taxToken;
        feeRecipient = _feeRecipient;
        crankBountyBps = _crankBountyBps;
        maxImpactBps = _maxImpactBps;
        minCrankEth = _minCrankEth;
        voteEscrow = ISlvrVoteEscrow(_voteEscrow);
        staking = ISlvrStaking(_staking);
        slvr = _slvr;
        slvrEthPair = IUniswapV2Pair(_slvrEthPair);
        address t0 = slvrEthPair.token0();
        weth = IWETH(t0 == _slvr ? slvrEthPair.token1() : t0);
    }

    /// @notice Tax settlement sem posílá nativní ETH — držet gas-light (jen přijmout).
    receive() external payable {}

    /// @notice Kolik ETH čeká na zpracování (bez naakumulovaných fee).
    function pendingEth() public view returns (uint256) {
        uint256 bal = address(this).balance;
        return bal > accruedFees ? bal - accruedFees : 0;
    }

    /// @notice Permissionless zpracování: tax -> SLVR permanent lock; rewards -> buyback&burn.
    /// Pre-graduation rewards (taxToken ještě nemá V2 pár) ZÁMĚRNĚ kompoundují do SLVR
    /// v příštím kole Phase A — viz SPEC.
    function crank() external nonReentrant {
        uint256 pending = pendingEth();
        uint256 lockedNow; uint256 rewards; uint256 burned;

        // Phase A: tax ETH -> SLVR -> permanent lock (auto-stake)
        if (pending >= minCrankEth) {
            uint256 fee = _computeFee(pending);
            uint256 bounty = (pending * crankBountyBps) / 10_000;
            uint256 buyEth = pending - fee - bounty;
            accruedFees += fee;

            _swapEthOnPair(slvrEthPair, slvr, buyEth, address(this));
            // SLVR je sam tax token (2% buy tax z poolu) — lockujeme skutecne
            // prijaty balance, ne vystup ze vzorce.
            uint256 slvrOut = IERC20(slvr).balanceOf(address(this));
            _lockAndStake(slvrOut);

            lockedNow = slvrOut;
            totalSlvrLocked += slvrOut;
            totalEthProcessed += pending;

            // fee zustava ve vaultu (pull pattern, withdrawFees); bounty jde volajicimu hned
            (bool s2,) = msg.sender.call{value: bounty}(""); require(s2, "bounty xfer");
        }

        // Phase B: staking rewards -> buyback taxToken -> burn (až po graduaci na V2)
        if (veTokenId != 0) {
            uint256 balBefore = address(this).balance;
            // claimStakerRewards platí nativní ETH; revertuje "no rewards" při nule
            try staking.claimStakerRewards(veTokenId) {} catch (bytes memory reason) {
                emit ClaimFailed(reason);
            }
            rewards = address(this).balance > balBefore ? address(this).balance - balBefore : 0;
            if (rewards > 0) {
                address pair = IUniswapV2Factory(slvrEthPair.factory()).getPair(taxToken, address(weth));
                if (pair != address(0)) {
                    uint256 db = IERC20(taxToken).balanceOf(DEAD);
                    _swapEthOnPair(IUniswapV2Pair(pair), taxToken, rewards, DEAD);
                    burned = IERC20(taxToken).balanceOf(DEAD) - db;
                    totalTaxTokenBurned += burned;
                    totalRewardsEth += rewards;
                }
                // pair == 0: token před graduací — rewards zůstávají a zpracují se příště
            }
        }

        require(lockedNow != 0 || burned != 0, "nothing to do");
        emit Cranked(msg.sender, pending, lockedNow, rewards, burned);
    }

    /// @notice Pošle naakumulované fee na feeRecipient. Permissionless (pull pattern) —
    /// revertující feeRecipient tak nemůže zablokovat crank(), jen svoje fee.
    function withdrawFees() external nonReentrant {
        uint256 amt = accruedFees;
        require(amt > 0, "no fees");
        accruedFees = 0;
        (bool ok,) = feeRecipient.call{value: amt}("");
        require(ok, "fee xfer");
        emit FeesWithdrawn(feeRecipient, amt);
    }

    // ---------- Flap Rule 009: emergency risk controls (guardian-only) ----------
    // Mandatorni pro neupgradovatelne vaulty; signatury presne dle referencni
    // implementace v pravidle 009. Guardian = Flap protocol multisig (VaultBase).

    function emergencyWithdrawNative(address to) external onlyGuardian nonReentrant {
        require(to != address(0), "Zero address");
        uint256 bal = address(this).balance;
        if (bal > 0) {
            accruedFees = 0; // drain je plny balance vc. fee — vynulovat ucetnictvi
            (bool ok,) = to.call{value: bal}("");
            require(ok, "Native transfer failed");
            emit EmergencyWithdrawNative(to, bal);
        }
    }

    function emergencyWithdrawToken(address token, address to) external onlyGuardian nonReentrant {
        require(token != address(0) && to != address(0), "Zero address");
        uint256 bal = IERC20OZ(token).balanceOf(address(this));
        if (bal > 0) {
            IERC20OZ(token).safeTransfer(to, bal);
            emit EmergencyWithdrawToken(token, to, bal);
        }
    }

    // ---------- internals ----------

    /// @dev Flap Rule 002 — doporučený fee vzorec z tax rate:
    ///   taxRate <= 1 % (100 bps)  -> fee = 6 % z částky
    ///   taxRate  > 1 %            -> fee = částka * 6 / taxRateBps
    ///   (2 % dan -> 3 %, 3 % -> 2 %, 10 % -> 0.6 %)
    /// Tax rate se cachuje pri prvnim uspesnem cteni z tax tokenu.
    function _computeFee(uint256 amount) internal returns (uint256 fee) {
        uint16 taxBps = taxRateBps;
        // code.length guard: try/catch nechyta decode fail pri volani adresy bez kodu
        if (taxBps == 0 && taxToken.code.length > 0) {
            try IFlapTaxTokenV3(taxToken).taxRate() returns (uint16 tr) {
                if (tr > 0) { taxRateBps = tr; taxBps = tr; }
            } catch {}
        }
        fee = taxBps <= 100 ? (amount * 600) / 10_000 : (amount * 6) / taxBps;
    }

    /// @dev Swap nativního ETH za `tokenOut` přímo přes UniV2 pár, s impact guardem.
    /// VERIFY #6: fee 997/1000.
    function _swapEthOnPair(IUniswapV2Pair pair, address tokenOut, uint256 ethIn, address to)
        internal returns (uint256 out)
    {
        (uint112 r0, uint112 r1,) = pair.getReserves();
        (uint256 rIn, uint256 rOut) = pair.token0() == address(weth)
            ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));
        require(ethIn * 10_000 <= rIn * maxImpactBps, "impact too high");

        uint256 inWithFee = ethIn * 997;
        out = (inWithFee * rOut) / (rIn * 1000 + inWithFee);

        weth.deposit{value: ethIn}();
        require(weth.transfer(address(pair), ethIn), "weth xfer");
        (uint256 out0, uint256 out1) = pair.token0() == tokenOut ? (out, uint256(0)) : (uint256(0), out);
        pair.swap(out0, out1, to, "");
    }

    function _lockAndStake(uint256 slvrAmount) internal {
        require(IERC20(slvr).approve(address(voteEscrow), slvrAmount), "approve");
        if (veTokenId == 0) {
            // Pali SLVR, mintuje permanentni veNFT (zustava vaultu) a sam ho auto-stakuje.
            veTokenId = voteEscrow.createPermanentLock(slvrAmount);
            // Pojistka pro pripad, ze best-effort auto-stake ve voteEscrow selhal.
            try staking.stake(veTokenId) {} catch {}
            emit LockCreated(veTokenId);
        } else {
            // Pali SLVR a navysi permanentni lock; staking weight se checkpointne sam.
            voteEscrow.increasePermanentLock(veTokenId, slvrAmount);
        }
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }

    // ---------- Flap UI surface ----------

    function description() public view override returns (string memory) {
        if (veTokenId == 0) {
            return "SlvrSnowballVault: tax ETH buys SLVR and burns it into a permanent 4x-weight voteEscrow lock; staking rewards buy back & burn this token. Waiting for first crank().";
        }
        return "SlvrSnowballVault: SLVR permanently locked (burned), staking rewards burning this token. Call crank() to process pending ETH (caller earns a bounty).";
    }

    function vaultUISchema() public pure override returns (VaultUISchema memory schema) {
        schema.vaultType = "SlvrSnowballVault";
        schema.description =
            "Tax ETH auto-buys SLVR and burns it into a permanent voteEscrow lock (constant 4x staking weight, irreversible). ETH staking rewards buy back & burn the tax token once it has graduated to a V2 pair; before graduation, rewards intentionally compound into more locked SLVR. Permissionless crank() with caller bounty.";
        schema.methods = new VaultMethodSchema[](9);

        schema.methods[0].name = "crank";
        schema.methods[0].description = "Process pending tax ETH (buy+lock SLVR) and staking rewards (buyback & burn). Caller earns a bounty.";
        schema.methods[0].approvals = new ApproveAction[](0);
        schema.methods[0].isWriteMethod = true;

        schema.methods[1].name = "withdrawFees";
        schema.methods[1].description = "Send accrued protocol fees to the fee recipient. Callable by anyone.";
        schema.methods[1].approvals = new ApproveAction[](0);
        schema.methods[1].isWriteMethod = true;

        schema.methods[2].name = "pendingEth";
        schema.methods[2].description = "ETH waiting to be processed by crank().";
        schema.methods[2].outputs = new FieldDescriptor[](1);
        schema.methods[2].outputs[0] = FieldDescriptor("amount", "uint256", "Pending ETH", 18);

        schema.methods[3].name = "totalSlvrLocked";
        schema.methods[3].description = "Total SLVR bought and permanently locked (burned) by this vault.";
        schema.methods[3].outputs = new FieldDescriptor[](1);
        schema.methods[3].outputs[0] = FieldDescriptor("amount", "uint256", "SLVR locked", 18);

        schema.methods[4].name = "totalTaxTokenBurned";
        schema.methods[4].description = "Total tax tokens bought back and burned from SLVR staking rewards.";
        schema.methods[4].outputs = new FieldDescriptor[](1);
        schema.methods[4].outputs[0] = FieldDescriptor("amount", "uint256", "Tokens burned", 18);

        schema.methods[5].name = "veTokenId";
        schema.methods[5].description = "The vault's veNFT id (0 until first crank).";
        schema.methods[5].outputs = new FieldDescriptor[](1);
        schema.methods[5].outputs[0] = FieldDescriptor("id", "uint256", "veNFT tokenId", 0);

        schema.methods[6].name = "totalEthProcessed";
        schema.methods[6].description = "Total tax ETH processed by Phase A of crank().";
        schema.methods[6].outputs = new FieldDescriptor[](1);
        schema.methods[6].outputs[0] = FieldDescriptor("amount", "uint256", "ETH processed", 18);

        schema.methods[7].name = "totalRewardsEth";
        schema.methods[7].description = "Total staking rewards ETH used for buyback & burn.";
        schema.methods[7].outputs = new FieldDescriptor[](1);
        schema.methods[7].outputs[0] = FieldDescriptor("amount", "uint256", "Rewards ETH", 18);

        schema.methods[8].name = "accruedFees";
        schema.methods[8].description = "Protocol fees accrued and waiting for withdrawFees().";
        schema.methods[8].outputs = new FieldDescriptor[](1);
        schema.methods[8].outputs[0] = FieldDescriptor("amount", "uint256", "Accrued fees", 18);
    }
}
