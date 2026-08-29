// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "./Verifier2.sol";
import "./MultiAssetMerkleTree.sol";
import "./dex/ISwapLogic.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface IHasher4 {
  function poseidon(bytes32[4] calldata inputs) external pure returns (bytes32);
}

interface IWETH is IERC20 {
  function deposit() external payable;
  function withdraw(uint256) external;
}

/**
 * @title SherwoodVault
 * @notice IMMUTABLE, NON-UPGRADABLE sole custodian of all funds (ETH + ERC20) for
 *         the Robinhood privacy mixer + private DEX. There is NO proxy and NO UUPS
 *         here: this contract's code can never change, so deposited TVL can only ever
 *         move via a valid user withdrawal ZK proof.
 *
 *         Responsibilities held IMMUTABLY in this layer:
 *           - the per-asset Merkle trees, nullifiers, Verifier2 and Poseidon-4 hasher;
 *           - deposit/withdraw via ZK proof (`transact`);
 *           - `executeSwap`: the ONLY swap fund path. The vault verifies the input-note
 *             withdrawal proof, pulls EXACTLY the authorized amountIn, asks the
 *             (upgradable) SwapLogic to BUILD the router calldata, re-checks the router
 *             against the VAULT-HELD allowlist, performs the external call itself, and
 *             mints the output note from the REAL measured balance delta;
 *           - the router allowlist (2-step timelocked), so a malicious SwapLogic upgrade
 *             cannot redirect amountIn to an attacker router;
 *           - the SwapLogic address pointer (2-step timelocked).
 *
 *         The vault NEVER delegatecalls SwapLogic — only external calls / staticcalls —
 *         so no upgradable code ever gains write access to vault storage or funds.
 *
 */
contract SherwoodVault is MultiAssetMerkleTree, ReentrancyGuard {
  using SafeERC20 for IERC20;

  int256 public constant MAX_EXT_AMOUNT = 2**248;
  uint256 public constant MAX_FEE = 2**248;
  uint256 public constant MAX_ENCRYPTED_OUTPUT_SIZE = 256;

  // Native ETH sentinel: assetId = 1, token address = address(0).
  uint256 public constant NATIVE_ASSET_ID = 1;

  // Delay (in seconds) between proposing and enabling a router / SwapLogic change.
  // Set to 0: config is still 2-step (a proposal must exist before it can be
  // enabled), but takes effect immediately with no waiting period.
  uint256 public constant CONFIG_TIMELOCK = 0;

  // ---- Protocol fees ----
  // Two independent rates in basis points, both admin-set and changeable at any time,
  // both HARD-CAPPED so a fee change can never become a rug vector (anti-FUD).
  uint256 public constant BPS_DENOMINATOR = 10_000;
  uint256 public constant MAX_PROTOCOL_FEE_BPS = 1_000; // 10% ceiling, immutable
  uint256 public withdrawFeeBps; // charged by transact on withdrawals
  uint256 public swapFeeBps; // charged by executeSwap
  address public protocolFeeRecipient; // where protocol fees accrue

  // ---- Quote assets ----
  // The only currencies that may enter or leave the vault, and the denomination of every
  // fee. Native ETH is permanently a quote; the admin manages the rest via setQuoteAsset.
  //
  // Gating deposits and withdrawals here is what prevents fee evasion: a directly
  // depositable memecoin would let anyone route value through a token and pool they
  // control, paying nothing, and leave the protocol holding a worthless fee.
  //
  // Internal transfers (extAmount == 0) are intentionally exempt. They move no funds, so
  // they cannot evade anything, and consolidation and epoch migration depend on them.
  mapping(address => bool) public quoteAsset;

  // ---- Swap allowlist ----
  // Quote assets are always swappable; every other token needs an explicit admin entry.
  // `permissionlessSwaps` reopens the vault to any token and pool without a redeploy.
  mapping(address => bool) public swapAllowed;
  bool public permissionlessSwaps;

  Verifier2 public immutable verifier2;
  IHasher4 public immutable hasher4;
  IWETH public immutable weth;

  address public admin;
  address public pendingAdmin;

  // The UUPS proxy address of SwapLogic. Stable across logic upgrades. 2-step + timelock.
  address public swapLogic;
  address public pendingSwapLogic;
  uint256 public swapLogicETA;

  // assetId => token address (address(0) for native ETH)
  mapping(uint256 => address) public assetToken;
  mapping(uint256 => bool) public assetRegistered;

  // assetId => live epoch. Each (asset, epoch) pair owns an independent tree addressed by
  // treeIdOf(). A full tree rotates to a fresh one automatically, making per-asset
  // capacity unbounded. This is a safety requirement, not an optimisation: a full tree
  // makes _insert revert, and transact inserts output commitments even on a withdrawal,
  // so the asset's notes would all become unspendable.
  //
  // Notes never move. A spend proves membership in the tree it lives in (the caller
  // passes that epoch) and its outputs are written to the LIVE tree, so value migrates
  // forward on its own and sealed trees only drain. Sealed trees stay spendable because
  // root history is unbounded.
  mapping(uint256 => uint32) public currentEpoch;

  mapping(bytes32 => bool) public nullifierHashes;

  // ---- Router allowlist, held IMMUTABLY IN THE VAULT (source of truth) ----
  // version => router => allowed
  mapping(ISwapLogic.Version => mapping(address => bool)) public routerAllowed;
  // version => canonical router used for execution (last one enabled)
  mapping(ISwapLogic.Version => address) public canonicalRouter;
  // proposal key (version, router) => ETA at which it may be enabled
  mapping(bytes32 => uint256) public routerProposalETA;

  struct ExtData {
    address recipient;
    int256 extAmount;
    address feeRecipient;
    uint256 fee;
    bytes encryptedOutput1;
    bytes encryptedOutput2;
    // keccak256(abi.encode(SwapParams)) for `executeSwap`, or bytes32(0) for `transact`.
    // ExtData is what `extDataHash` (a proof public input) commits to, so putting the
    // swap params' digest here is what makes the SWAP DESTINATION part of the signed
    // statement. Without it the proof authorizes "withdraw amountIn to the vault" and
    // says nothing about who receives the proceeds, letting anyone replay the proof
    // with their own outPubkey / minOut / routeData. See _requireSwapParams.
    bytes32 swapParamsHash;
  }

  struct Proof {
    uint[2] pA;
    uint[2][2] pB;
    uint[2] pC;
    bytes32 root;
    bytes32[2] inputNullifiers;
    bytes32[2] outputCommitments;
    uint256 publicAmount;
    bytes32 extDataHash;
  }

  // Swap parameters: the input note is spent via `proof`/`extData` (recipient = this),
  // and only the OUTPUT note's ownership fields (pubkey P, blinding r) are supplied.
  struct SwapParams {
    uint256 assetIn; // asset being spent (must match extData/proof tree)
    address tokenOut; // ERC20 out, or address(0) for native ETH
    ISwapLogic.Version version;
    bytes routeData;
    uint256 minOut; // slippage floor; tx reverts if Y < minOut
    uint256 deadline;
    bytes32 outPubkey; // P: one-time stealth key of the output note
    bytes32 outBlinding; // r: blinding of the output note
    // Relayer fee taken from the proceeds, in tokenOut. Used only when tokenIn is not a
    // quote, where debiting the input would pay the relayer in a memecoin. It lives here
    // rather than in ExtData so swapParamsHash covers it and the relayer cannot inflate
    // it after the proof is built. Must be 0 when tokenIn is a quote.
    uint256 relayerFeeOut;
    bytes encryptedOutput; // encrypted output note for wallet recovery
  }

  event NewCommitment(uint256 indexed assetId, bytes32 commitment, uint256 index, bytes encryptedOutput);
  event NewNullifier(bytes32 nullifier);
  event TokenRegistered(uint256 indexed assetId, address indexed token);
  event AdminChanged(address indexed oldAdmin, address indexed newAdmin);
  event Swap(uint256 indexed assetIn, uint256 indexed assetOut, uint256 amountIn, uint256 amountOut, bytes32 commitment);

  event RouterProposed(ISwapLogic.Version indexed version, address indexed router, uint256 eta);
  event RouterConfigured(ISwapLogic.Version indexed version, address indexed router, bool allowed);
  event SwapLogicProposed(address indexed newLogic, uint256 eta);
  event SwapLogicSet(address indexed oldLogic, address indexed newLogic);
  event WithdrawFeeSet(uint256 bps);
  event SwapFeeSet(uint256 bps);
  event ProtocolFeeRecipientSet(address indexed recipient);
  event ProtocolFeeCharged(uint256 indexed assetId, address token, uint256 amount);
  event QuoteAssetSet(address indexed token, bool enabled);
  event EpochRotated(uint256 indexed assetId, uint32 epoch, uint256 treeId);
  event SwapAllowedSet(address indexed token, bool allowed);
  event PermissionlessSwapsSet(bool enabled);

  modifier onlyAdmin() {
    require(msg.sender == admin, "only admin");
    _;
  }

  constructor(
    Verifier2 _verifier2,
    uint32 _levels,
    address _hasher,
    address _hasher4,
    address _weth,
    address _admin
  ) MultiAssetMerkleTree(_levels, _hasher) {
    require(_admin != address(0), "admin is zero address");
    require(_hasher4 != address(0), "hasher4 is zero address");
    require(_weth != address(0), "weth is zero address");
    verifier2 = _verifier2;
    hasher4 = IHasher4(_hasher4);
    weth = IWETH(_weth);
    admin = _admin;

    // Native ETH tree is always available.
    _registerAsset(NATIVE_ASSET_ID, address(0));
  }

  // ------------------------------------------------------------- registration

  /// @notice Register an ERC20 token, initializing its Merkle tree. assetId = uint160(token).
  function registerToken(address token) external onlyAdmin returns (uint256 assetId) {
    require(token != address(0), "token is zero address");
    assetId = uint256(uint160(token));
    require(assetId != NATIVE_ASSET_ID, "reserved asset id");
    _registerAsset(assetId, token);
  }

  function _registerAsset(uint256 assetId, address token) internal {
    require(!assetRegistered[assetId], "already registered");
    assetRegistered[assetId] = true;
    assetToken[assetId] = token;
    _initTree(treeIdOf(assetId, 0));
    emit TokenRegistered(assetId, token);
  }

  function assetIdOf(address token) public pure returns (uint256) {
    return token == address(0) ? NATIVE_ASSET_ID : uint256(uint160(token));
  }

  // ------------------------------------------------------------- epochs

  /// @notice The tree that holds asset `assetId`'s notes for `epoch`.
  function treeIdOf(uint256 assetId, uint32 epoch) public pure returns (uint256) {
    return uint256(keccak256(abi.encode(assetId, epoch)));
  }

  /// @notice The tree new notes of `assetId` are currently written to.
  function liveTreeId(uint256 assetId) public view returns (uint256) {
    return treeIdOf(assetId, currentEpoch[assetId]);
  }

  /// @dev Global (cross-epoch) leaf index emitted in NewCommitment. The wallet stores
  ///      this one number and derives both coordinates from it:
  ///        epoch      = index / capacity()
  ///        localIndex = index % capacity()
  ///      Only localIndex may be fed to the circuit — merkleProof.circom does
  ///      Num2Bits(levels) on pathIndices, so anything >= capacity() is unprovable.
  function _globalIndex(uint32 epoch, uint32 localIndex) internal view returns (uint256) {
    return uint256(epoch) * capacity() + uint256(localIndex);
  }

  /// @notice Seal `assetId`'s current tree and open the next epoch immediately, without
  ///         waiting for it to fill. Rotation never touches funds and never strands a
  ///         note — sealed trees keep every root they ever had, so their notes stay
  ///         spendable forever. The only cost of rotating early is splitting the
  ///         anonymity set across two trees.
  function forceRotate(uint256 assetId) external onlyAdmin {
    require(assetRegistered[assetId], "asset not registered");
    uint32 epoch = currentEpoch[assetId] + 1;
    currentEpoch[assetId] = epoch;
    uint256 treeId = treeIdOf(assetId, epoch);
    _initTree(treeId);
    emit EpochRotated(assetId, epoch, treeId);
  }

  /// @dev The live tree for `assetId`, rotating to a fresh epoch first if it is full.
  function _liveTree(uint256 assetId) internal returns (uint256 treeId, uint32 epoch) {
    epoch = currentEpoch[assetId];
    treeId = treeIdOf(assetId, epoch);
    if (isTreeFull(treeId)) {
      epoch += 1;
      currentEpoch[assetId] = epoch;
      treeId = treeIdOf(assetId, epoch);
      _initTree(treeId);
      emit EpochRotated(assetId, epoch, treeId);
    }
  }

  /// @dev Insert a pair of output commitments into `assetId`'s live tree and announce
  ///      them with global indices.
  function _insertOutputs(
    uint256 assetId,
    bytes32 c0,
    bytes32 c1,
    bytes memory enc0,
    bytes memory enc1
  ) internal {
    (uint256 treeId, uint32 epoch) = _liveTree(assetId);
    _insert(treeId, c0, c1);
    uint32 idx = nextIndex(treeId);
    emit NewCommitment(assetId, c0, _globalIndex(epoch, idx - 2), enc0);
    emit NewCommitment(assetId, c1, _globalIndex(epoch, idx - 1), enc1);
  }

  // ------------------------------------------------------------- config (2-step + timelock)

  /// @notice Step 1: propose enabling a router for `version`. Starts the timelock.
  function proposeRouter(ISwapLogic.Version version, address router) external onlyAdmin {
    require(router != address(0), "router is zero address");
    uint256 eta = block.timestamp + CONFIG_TIMELOCK;
    routerProposalETA[_routerKey(version, router)] = eta;
    emit RouterProposed(version, router, eta);
  }

  /// @notice Step 2: enable a router after its timelock elapses.
  function enableRouter(ISwapLogic.Version version, address router) external onlyAdmin {
    require(router != address(0), "router is zero address");
    bytes32 key = _routerKey(version, router);
    uint256 eta = routerProposalETA[key];
    require(eta != 0 && block.timestamp >= eta, "router timelock");
    routerProposalETA[key] = 0;
    routerAllowed[version][router] = true;
    canonicalRouter[version] = router;
    emit RouterConfigured(version, router, true);
  }

  /// @notice Disabling a router is immediate (safety action, never adds trust).
  function disableRouter(ISwapLogic.Version version, address router) external onlyAdmin {
    require(router != address(0), "router is zero address");
    routerAllowed[version][router] = false;
    if (canonicalRouter[version] == router) {
      canonicalRouter[version] = address(0);
    }
    emit RouterConfigured(version, router, false);
  }

  function isRouterAllowed(ISwapLogic.Version version, address router) external view returns (bool) {
    return routerAllowed[version][router];
  }

  /// @notice Step 1: propose a new SwapLogic proxy address. Starts the timelock.
  function proposeSwapLogic(address newLogic) external onlyAdmin {
    require(newLogic != address(0), "logic is zero address");
    pendingSwapLogic = newLogic;
    swapLogicETA = block.timestamp + CONFIG_TIMELOCK;
    emit SwapLogicProposed(newLogic, swapLogicETA);
  }

  /// @notice Step 2: adopt the proposed SwapLogic after its timelock elapses.
  function setSwapLogic() external onlyAdmin {
    require(pendingSwapLogic != address(0), "no pending logic");
    require(swapLogicETA != 0 && block.timestamp >= swapLogicETA, "logic timelock");
    emit SwapLogicSet(swapLogic, pendingSwapLogic);
    swapLogic = pendingSwapLogic;
    pendingSwapLogic = address(0);
    swapLogicETA = 0;
  }

  function transferAdmin(address _newAdmin) external onlyAdmin {
    require(_newAdmin != address(0), "new admin is zero address");
    pendingAdmin = _newAdmin;
  }

  function claimAdmin() external {
    require(msg.sender == pendingAdmin, "not pending admin");
    emit AdminChanged(admin, pendingAdmin);
    admin = pendingAdmin;
    pendingAdmin = address(0);
  }

  function _routerKey(ISwapLogic.Version version, address router) internal pure returns (bytes32) {
    return keccak256(abi.encode(version, router));
  }

  // ------------------------------------------------------------- protocol fee (admin)

  /// @notice Set the withdrawal fee rate in bps (charged by transact on exits).
  function setWithdrawFee(uint256 bps) external onlyAdmin {
    require(bps <= MAX_PROTOCOL_FEE_BPS, "fee too high");
    require(bps == 0 || protocolFeeRecipient != address(0), "recipient unset");
    withdrawFeeBps = bps;
    emit WithdrawFeeSet(bps);
  }

  /// @notice Set the swap fee rate in bps (charged by executeSwap). Independent of the
  ///         withdrawal rate, both bounded by the same immutable ceiling.
  function setSwapFee(uint256 bps) external onlyAdmin {
    require(bps <= MAX_PROTOCOL_FEE_BPS, "fee too high");
    require(bps == 0 || protocolFeeRecipient != address(0), "recipient unset");
    swapFeeBps = bps;
    emit SwapFeeSet(bps);
  }

  /// @notice Set where protocol fees accrue.
  function setProtocolFeeRecipient(address recipient) external onlyAdmin {
    require(recipient != address(0), "recipient is zero address");
    protocolFeeRecipient = recipient;
    emit ProtocolFeeRecipientSet(recipient);
  }

  /// @notice Add or remove a quote asset (e.g. USDG). Quotes are the only currencies
  ///         that may be deposited or withdrawn, and every fee is denominated in one.
  ///         Native ETH is permanently a quote and cannot be set here.
  ///
  ///         Removing a quote stops new deposits of it and blocks direct withdrawals,
  ///         so its holders must swap back to another quote to exit. Do not remove a
  ///         quote unless another liquid one is reachable from it.
  function setQuoteAsset(address token, bool enabled) external onlyAdmin {
    require(token != address(0), "native is always a quote");
    quoteAsset[token] = enabled;
    if (enabled) {
      uint256 assetId = assetIdOf(token);
      if (!assetRegistered[assetId]) {
        _registerAsset(assetId, token);
      }
    }
    emit QuoteAssetSet(token, enabled);
  }

  /// @dev Whether `token` is a quote asset (native ETH always is).
  function _isQuote(address token) internal view returns (bool) {
    return token == address(0) || quoteAsset[token];
  }

  function isQuote(address token) external view returns (bool) {
    return _isQuote(token);
  }

  // ------------------------------------------------------------- swap allowlist (admin)

  /// @notice Allow a token to be swapped. Also registers its tree, so `executeSwap` never
  ///         has to create one on the fly outside permissionless mode.
  ///
  /// @dev ONE-WAY, on purpose: `allowed` must be true, and a token can never be removed.
  ///
  ///      A non-quote note has exactly one exit — being sold into a quote — because
  ///      `transact` only lets quotes leave. Revoking the allowlist entry would therefore
  ///      not merely stop trading, it would CONFISCATE every note of that token: unsellable
  ///      and unwithdrawable, forever. That is not a lever an admin should hold, so it is
  ///      removed from the contract rather than left to policy.
  ///
  ///      The admin keeps the only decision that matters — whether to add a token at all —
  ///      and `setPermissionlessSwaps` still shuts off unlisted tokens wholesale. What it
  ///      gives up is de-listing a token that later turns out to be junk: it stays tradable,
  ///      so buyers can still walk into it. Refusing to add is the moment to be careful.
  function setSwapAllowed(address token, bool allowed) external onlyAdmin {
    require(token != address(0), "native always swappable");
    require(allowed, "swap allowlist is one-way");
    swapAllowed[token] = true;
    uint256 assetId = assetIdOf(token);
    if (!assetRegistered[assetId]) {
      _registerAsset(assetId, token);
    }
    emit SwapAllowedSet(token, true);
  }

  /// @notice Open swapping to every token / every pool, as the vault originally behaved.
  ///         Kept as a one-flag switch so we can go permissionless without a redeploy.
  function setPermissionlessSwaps(bool enabled) external onlyAdmin {
    permissionlessSwaps = enabled;
    emit PermissionlessSwapsSet(enabled);
  }

  /// @dev Base assets (ETH, and whatever the admin marked as a fee asset such as USDG)
  ///      are always swappable; everything else needs an explicit allowlist entry.
  function _isSwappable(address token) internal view returns (bool) {
    return permissionlessSwaps || _isQuote(token) || swapAllowed[token];
  }

  function isSwappable(address token) external view returns (bool) {
    return _isSwappable(token);
  }

  /// @dev The protocol fee owed on `amount` at `bps` (0 if disabled or no recipient).
  function _feeOn(uint256 amount, uint256 bps) internal view returns (uint256) {
    if (bps == 0 || protocolFeeRecipient == address(0)) return 0;
    return (amount * bps) / BPS_DENOMINATOR;
  }

  /// @dev Pay `fee` of `token` (address(0)=native ETH) to the protocol fee recipient.
  function _payProtocolFee(uint256 assetId, address token, uint256 fee) internal {
    if (fee == 0) return;
    if (token == address(0)) {
      (bool ok, ) = protocolFeeRecipient.call{value: fee}("");
      require(ok, "fee transfer failed");
    } else {
      IERC20(token).safeTransfer(protocolFeeRecipient, fee);
    }
    emit ProtocolFeeCharged(assetId, token, fee);
  }

  // ------------------------------------------------------------- transact

  /// @notice Deposit/withdraw of a single asset, or an internal transfer when
  ///         extAmount == 0 (consolidating notes, or pulling notes out of a sealed
  ///         epoch into the live one). Binds the transferred asset to its tree via
  ///         isKnownRoot(treeIdOf(assetId, inEpoch), root): a proof only releases the
  ///         asset whose tree it proves membership in. Fund release is ONLY against a
  ///         valid proof.
  /// @param inEpoch The epoch of the tree the spent notes live in. Unbound by the proof
  ///        on purpose — it is self-validating, since a root only ever exists in the
  ///        epoch that produced it, so a wrong value simply fails the root check.
  function transact(
    uint256 assetId,
    uint32 inEpoch,
    Proof memory _args,
    ExtData memory _extData
  ) public payable nonReentrant {
    // Domain separation: a `transact` proof must never be replayable as a swap. Pinning
    // the field to zero here means the two paths can never produce the same extDataHash
    // for the same funds movement.
    require(_extData.swapParamsHash == bytes32(0), "swapParamsHash must be zero");
    _verifyAndConsume(assetId, inEpoch, _args, _extData);

    address token = assetToken[assetId];
    bool isNative = token == address(0);

    if (_extData.extAmount > 0) {
      // Only quotes may enter: see the quoteAsset notice.
      // Only quotes may enter; see the quoteAsset notice above.
      require(_isQuote(token), "deposit must be a quote asset");
      uint256 amt = uint256(_extData.extAmount);
      if (isNative) {
        require(msg.value == amt, "Incorrect ETH value");
      } else {
        require(msg.value == 0, "Unexpected ETH value");
        IERC20(token).safeTransferFrom(msg.sender, address(this), amt);
      }
    } else if (_extData.extAmount < 0) {
      // Only quotes may leave. This is the other half of the fee-evasion seal, and it
      // guarantees the protocol and relayer fees below are paid in a valuable asset.
      // A non-quote note still always has an exit — it is sold into a quote, which the
      // one-way allowlist guarantees stays possible forever. See setSwapAllowed.
      require(_isQuote(token), "withdraw must be a quote asset");
      require(_extData.recipient != address(0), "Can't withdraw to zero address");
      uint256 amt = uint256(-_extData.extAmount);
      // Protocol fee is charged on withdrawals, in the withdrawn (quote) asset.
      uint256 pFee = _feeOn(amt, withdrawFeeBps);
      uint256 net = amt - pFee;
      if (isNative) {
        require(msg.value == 0, "Cannot send ETH during withdrawal");
        (bool ok, ) = _extData.recipient.call{value: net}("");
        require(ok, "ETH transfer failed");
      } else {
        require(msg.value == 0, "Unexpected ETH value");
        IERC20(token).safeTransfer(_extData.recipient, net);
      }
      _payProtocolFee(assetId, token, pFee);
    } else {
      // extAmount == 0: an INTERNAL TRANSFER. The spent notes are burned and reissued,
      // consolidating fragments or moving a note into the live epoch after a rotation.
      // Nothing enters or leaves the vault, so this branch is deliberately NOT gated on
      // _isQuote: memecoin notes must stay migratable or a rotation would strand them.
      // With no funds moving there is nothing to evade, which is why the gate is safe to
      // omit here but required on both branches above.
      //
      // Neither transfer branch runs, so msg.value needs its own guard or stray ETH
      // would be absorbed with no note backing it and stuck forever.
      require(msg.value == 0, "Unexpected ETH value");
    }

    if (_extData.fee > 0) {
      // The relayer fee leaves the vault in the asset's own token, so it is a funds exit
      // and must obey the same rule as a withdrawal. Internal transfers skip the quote
      // gate above so consolidation and epoch migration keep working for every asset —
      // without this check, one could pay out an entire memecoin note as a "fee" to an
      // arbitrary address, bypassing the quote restriction and paying no protocol fee.
      // Consolidating a non-quote note is therefore self-submitted, with fee == 0.
      require(_isQuote(token), "fee must be a quote asset");
      if (isNative) {
        (bool ok, ) = _extData.feeRecipient.call{value: _extData.fee}("");
        require(ok, "Fee transfer failed");
      } else {
        IERC20(token).safeTransfer(_extData.feeRecipient, _extData.fee);
      }
    }

    // Output notes always land in the LIVE tree, never in the tree they were spent from.
    _insertOutputs(
      assetId,
      _args.outputCommitments[0],
      _args.outputCommitments[1],
      _extData.encryptedOutput1,
      _extData.encryptedOutput2
    );
    emit NewNullifier(_args.inputNullifiers[0]);
    emit NewNullifier(_args.inputNullifiers[1]);
  }

  /// @dev Shared proof verification + nullifier consumption for transact and executeSwap.
  function _verifyAndConsume(
    uint256 assetId,
    uint32 inEpoch,
    Proof memory _args,
    ExtData memory _extData
  ) internal {
    require(assetRegistered[assetId], "asset not registered");
    require(
      _extData.encryptedOutput1.length <= MAX_ENCRYPTED_OUTPUT_SIZE &&
        _extData.encryptedOutput2.length <= MAX_ENCRYPTED_OUTPUT_SIZE,
      "Encrypted output too large"
    );
    require(isKnownRoot(treeIdOf(assetId, inEpoch), _args.root), "Invalid merkle root");
    require(!isSpent(_args.inputNullifiers[0]) && !isSpent(_args.inputNullifiers[1]), "Input is already spent");
    require(
      uint256(_args.extDataHash) == uint256(keccak256(abi.encode(_extData))) % FIELD_SIZE,
      "Incorrect external data hash"
    );
    require(_args.publicAmount == calculatePublicAmount(_extData.extAmount, _extData.fee), "Invalid public amount");
    require(verifyProof(_args), "Invalid transaction proof");

    nullifierHashes[_args.inputNullifiers[0]] = true;
    nullifierHashes[_args.inputNullifiers[1]] = true;
  }

  /// @dev Enforce that the supplied SwapParams are exactly the ones the prover committed
  ///      to. `_extData.swapParamsHash` is inside ExtData, ExtData is keccak'd into
  ///      `_args.extDataHash` (checked in _verifyAndConsume), and extDataHash is a public
  ///      input of the SNARK — so a tampered p makes the whole tx unprovable, not just
  ///      mismatched. The full struct is hashed, encryptedOutput included, so a relayer
  ///      cannot even garble the recovery blob into an unspendable note.
  function _requireSwapParams(ExtData memory _extData, SwapParams memory p) internal pure {
    require(_extData.swapParamsHash == keccak256(abi.encode(p)), "swap params tampered");
  }

  // ------------------------------------------------------------- executeSwap

  /**
   * @notice The ONLY swap fund path. Spends an input-asset note (withdrawal proof,
   *         recipient = this vault), routes the withdrawn amountIn through a
   *         VAULT-ALLOWLISTED router (calldata built by SwapLogic), and mints the
   *         output note from the REAL measured balance delta of tokenOut.
   *
   * @dev Fund safety comes from THIS contract (immutable):
   *      - amountIn is exactly the user-authorized withdrawn amount (from the proof);
   *      - the SwapParams (destination pubkey, route, minOut, deadline) are committed to
   *        by that same proof via extData.swapParamsHash, so the submitter — relayer or
   *        front-running searcher — cannot redirect the proceeds to a note they own;
   *      - the router is re-checked against the vault-held allowlist AFTER SwapLogic
   *        builds the route, so no logic upgrade can redirect to an attacker router;
   *      - SwapLogic is only STATICCALLED (buildRoute is view) — never delegatecalled —
   *        so it can never touch vault storage or idle TVL;
   *      - the external swap call is performed BY THE VAULT; output is measured here;
   *      - if measured Y < minOut the whole tx reverts atomically (input note unspent).
   */
  function executeSwap(
    uint32 inEpoch,
    Proof memory _args,
    ExtData memory _extData,
    SwapParams memory p
  ) external nonReentrant returns (uint256 amountOut) {
    require(swapLogic != address(0), "swapLogic unset");
    // Bind p to the proof BEFORE anything is derived from it (assetIdOf/_isSwappable
    // below already read p.tokenOut). Past this line every field of p is covered by
    // extDataHash, hence by the ZK proof: tokenOut, routeData, minOut, deadline and —
    // critically — outPubkey/outBlinding, which decide who owns the swap proceeds.
    _requireSwapParams(_extData, p);
    require(_extData.recipient == address(this), "recipient must be vault");
    require(_extData.extAmount < 0, "must be a withdrawal");
    require(p.encryptedOutput.length <= MAX_ENCRYPTED_OUTPUT_SIZE, "Encrypted output too large");

    // ---- verify + consume the input note (identical checks to transact) ----
    _verifyAndConsume(p.assetIn, inEpoch, _args, _extData);

    uint256 amountIn = uint256(-_extData.extAmount);
    address tokenIn = assetToken[p.assetIn];

    // ---- swap allowlist ----
    // Only the OUT leg is gated. The allowlist governs what may be ACQUIRED; it has no
    // business governing what may be got rid of.
    //
    // Gating the IN leg protected nothing and trapped people. A quote always passes it, and
    // a non-quote only reaches it when the caller already HOLDS a note of that token —
    // which they could only have obtained back when acquiring it was permitted. So the
    // check never fired on anyone except someone trying to leave: turning off
    // permissionless mode, or de-listing, confiscated every note of that token, since a
    // non-quote cannot leave through `transact` either.
    //
    // Nothing loosens by dropping it. The pair rule below still forces the OUT leg to be a
    // quote whenever the IN leg is not, so a token nobody may buy any more can still only
    // ever be sold INTO a quote, and every fee still lands in a quote.
    require(_isSwappable(p.tokenOut), "tokenOut not swappable");

    // At least one leg must be a quote. Quote-to-quote stays allowed; only
    // memecoin-to-memecoin is refused. This is what makes the fee logic below total:
    // neither the protocol nor the relayer can ever be paid in a memecoin.
    require(_isQuote(tokenIn) || _isQuote(p.tokenOut), "one leg must be a quote");

    uint256 assetOut = assetIdOf(p.tokenOut);
    if (!assetRegistered[assetOut]) {
      // Only reachable in permissionless mode: `setSwapAllowed` registers an allowlisted
      // token's tree up front, and base assets are registered at construction time.
      // Registration only inits an empty Merkle namespace (+ records tokenOut for a later
      // withdraw); it grants no funds and rolls back atomically on a later revert.
      _registerAsset(assetOut, p.tokenOut);
    }

    // Mint the change note back into the INPUT asset's LIVE tree (2-in/2-out invariant).
    _insertOutputs(
      p.assetIn,
      _args.outputCommitments[0],
      _args.outputCommitments[1],
      _extData.encryptedOutput1,
      _extData.encryptedOutput2
    );
    emit NewNullifier(_args.inputNullifiers[0]);
    emit NewNullifier(_args.inputNullifiers[1]);

    // ---- fees ----
    // Both fees are always paid in a quote, so they are taken on whichever leg is one.
    // The check above guarantees at least one leg qualifies.
    //
    //   tokenIn is a quote      -> both come off the INPUT, before the swap, in tokenIn.
    //                              ExtData.fee pays the relayer; relayerFeeOut must be 0.
    //   tokenIn is not a quote  -> both come off the PROCEEDS, after the swap, in
    //                              tokenOut. relayerFeeOut pays the relayer;
    //                              ExtData.fee must be 0.
    //
    // ExtData.fee cannot simply move to the output side: the circuit enforces
    // publicAmount = extAmount - fee, which debits the user's notes in the INPUT asset
    // whenever the transfer happens. Paying out tokenOut against that debit would leave
    // the vault holding unbacked tokenIn. Hence the separate relayerFeeOut field.
    bool inIsQuote = _isQuote(tokenIn);
    uint256 swapAmountIn = amountIn;

    if (inIsQuote) {
      require(p.relayerFeeOut == 0, "relayerFeeOut must be zero");
      // Relayer fee, in tokenIn, out of the withdrawn amount.
      if (_extData.fee > 0) {
        if (tokenIn == address(0)) {
          (bool ok, ) = _extData.feeRecipient.call{value: _extData.fee}("");
          require(ok, "Fee transfer failed");
        } else {
          IERC20(tokenIn).safeTransfer(_extData.feeRecipient, _extData.fee);
        }
      }
      uint256 feeIn = _feeOn(amountIn, swapFeeBps);
      if (feeIn > 0) {
        swapAmountIn = amountIn - feeIn;
        _payProtocolFee(p.assetIn, tokenIn, feeIn);
      }
    } else {
      // Nothing may be debited on the input side, or the user would be charged in the
      // memecoin while we pay out in the quote.
      require(_extData.fee == 0, "extData.fee must be zero");
    }

    // ---- route + execute the swap, measuring the REAL balance delta ----
    amountOut = _routeAndSwap(p, tokenIn, swapAmountIn);

    if (!inIsQuote) {
      uint256 feeOut = _feeOn(amountOut, swapFeeBps);
      if (feeOut > 0) {
        amountOut -= feeOut;
        _payProtocolFee(assetOut, p.tokenOut, feeOut);
      }
      if (p.relayerFeeOut > 0) {
        require(p.relayerFeeOut <= amountOut, "relayerFeeOut exceeds proceeds");
        amountOut -= p.relayerFeeOut;
        if (p.tokenOut == address(0)) {
          (bool ok, ) = _extData.feeRecipient.call{value: p.relayerFeeOut}("");
          require(ok, "Fee transfer failed");
        } else {
          IERC20(p.tokenOut).safeTransfer(_extData.feeRecipient, p.relayerFeeOut);
        }
      }
    }

    // Slippage protection covers the NET the user actually receives, so both fees are
    // inside what minOut guards. Checked after every deduction, on purpose.
    require(amountOut >= p.minOut, "insufficient output");
    require(amountOut > 0, "zero output");

    // ---- mint the output note: C_out = Poseidon4(Y, P, r, assetId(tokenOut)) ----
    bytes32 commitment = _poseidon4(bytes32(amountOut), p.outPubkey, p.outBlinding, bytes32(assetOut));
    bytes32 emptyLeaf = _poseidon4(bytes32(0), p.outPubkey, bytes32(0), bytes32(assetOut));
    _insertOutputs(assetOut, commitment, emptyLeaf, p.encryptedOutput, "");

    emit Swap(p.assetIn, assetOut, amountIn, amountOut, commitment);
  }

  /**
   * @dev The vault operates in pure ERC20 terms with routers: it wraps native ETH to
   *      WETH before the call and unwraps WETH after. It asks SwapLogic to BUILD the
   *      router calldata, RE-CHECKS the router against its own allowlist, performs the
   *      call itself, and measures the tokenOut balance delta.
   */
  function _routeAndSwap(SwapParams memory p, address tokenIn, uint256 amountIn) internal returns (uint256) {
    address canonical = canonicalRouter[p.version];
    require(canonical != address(0) && routerAllowed[p.version][canonical], "router not whitelisted");

    address effectiveIn = tokenIn == address(0) ? address(weth) : tokenIn;
    address effectiveOut = p.tokenOut == address(0) ? address(weth) : p.tokenOut;

    // Wrap native ETH input to WETH so the vault deals only in ERC20 with the router.
    if (tokenIn == address(0)) {
      weth.deposit{value: amountIn}();
    }

    // Build the route via the upgradable logic (STATICCALL — buildRoute is view).
    ISwapLogic.SwapRequest memory req = ISwapLogic.SwapRequest({
      version: p.version,
      routeData: p.routeData,
      tokenIn: tokenIn,
      tokenOut: p.tokenOut,
      weth: address(weth),
      router: canonical,
      amountIn: amountIn,
      minOut: p.minOut,
      deadline: p.deadline,
      recipient: address(this)
    });
    ISwapLogic.RouteInstruction memory ins = ISwapLogic(swapLogic).buildRoute(req);

    // CRITICAL: re-validate the router the logic returned against the VAULT allowlist.
    // This is what makes a malicious logic upgrade unable to redirect amountIn.
    require(ins.router == canonical, "router mismatch");
    require(routerAllowed[p.version][ins.router], "router not whitelisted");
    // The vault never forwards raw ETH to routers; it always uses WETH via approval.
    require(ins.callValue == 0, "no eth to router");
    require(ins.approveToken == effectiveIn, "bad approve token");
    require(ins.approveAmount == amountIn, "bad approve amount");

    uint256 balBefore = IERC20(effectiveOut).balanceOf(address(this));

    // Approve exactly amountIn, perform the swap, then reset approval.
    IERC20(effectiveIn).forceApprove(ins.router, amountIn);
    (bool ok, bytes memory ret) = ins.router.call(ins.callData);
    if (!ok) {
      // bubble up the revert reason
      if (ret.length > 0) {
        assembly {
          revert(add(ret, 0x20), mload(ret))
        }
      }
      revert("router call failed");
    }
    IERC20(effectiveIn).forceApprove(ins.router, 0);

    uint256 balAfter = IERC20(effectiveOut).balanceOf(address(this));
    uint256 measured = balAfter - balBefore;

    // Unwrap WETH back to native ETH if the user wanted ETH out.
    if (p.tokenOut == address(0) && measured > 0) {
      weth.withdraw(measured);
    }
    return measured;
  }

  function _poseidon4(bytes32 a, bytes32 b, bytes32 c, bytes32 d) internal view returns (bytes32) {
    bytes32[4] memory inp;
    inp[0] = a;
    inp[1] = b;
    inp[2] = c;
    inp[3] = d;
    return hasher4.poseidon(inp);
  }

  /// @notice Exposed for tests: on-chain Poseidon-4 over [amount, pubkey, blinding, mintAddress].
  function poseidon4(bytes32 a, bytes32 b, bytes32 c, bytes32 d) external view returns (bytes32) {
    return _poseidon4(a, b, c, d);
  }

  // ------------------------------------------------------------- views / helpers

  function calculatePublicAmount(int256 _extAmount, uint256 _fee) public pure returns (uint256) {
    require(_fee < MAX_FEE, "Invalid fee");
    require(_extAmount > -MAX_EXT_AMOUNT && _extAmount < MAX_EXT_AMOUNT, "Invalid ext amount");
    // extAmount == 0 is an INTERNAL transfer: no funds enter or leave the vault, the
    // spent notes are simply reissued as new ones (consolidating fragmented notes, or
    // moving a note into the live tree). It needs no `> _fee` guard: the circuit's
    // `sumIns + publicAmount === sumOuts` with publicAmount == -fee forces
    // sumOuts == sumIns - fee, and outAmount is range-checked to 248 bits, so a fee
    // exceeding the input notes makes the proof unsatisfiable rather than underflowing.
    require(
      _extAmount == 0 ||
        (_extAmount > 0 && uint256(_extAmount) > _fee) ||
        (_extAmount < 0 && uint256(-_extAmount) > _fee),
      "ext amount must exceed fee"
    );
    int256 publicAmount = _extAmount - int256(_fee);
    return (publicAmount >= 0) ? uint256(publicAmount) : FIELD_SIZE - uint256(-publicAmount);
  }

  function isSpent(bytes32 _nullifierHash) public view returns (bool) {
    return nullifierHashes[_nullifierHash];
  }

  function verifyProof(Proof memory _args) public view returns (bool) {
    return
      verifier2.verifyProof(
        _args.pA,
        _args.pB,
        _args.pC,
        [
          uint256(_args.root),
          _args.publicAmount,
          uint256(_args.extDataHash),
          uint256(_args.inputNullifiers[0]),
          uint256(_args.inputNullifiers[1]),
          uint256(_args.outputCommitments[0]),
          uint256(_args.outputCommitments[1])
        ]
      );
  }

  receive() external payable {}
}
