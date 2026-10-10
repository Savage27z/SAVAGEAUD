// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC721} from "openzeppelin-contracts/contracts/token/ERC721/IERC721.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IERC1271} from "openzeppelin-contracts/contracts/interfaces/IERC1271.sol";
import {ECDSA} from "openzeppelin-contracts/contracts/utils/cryptography/ECDSA.sol";
import {IERC165} from "openzeppelin-contracts/contracts/utils/introspection/IERC165.sol";

interface IERC6551Account {
    receive() external payable;
    function token() external view returns (uint256 chainId, address tokenContract, uint256 tokenId);
    function state() external view returns (uint256);
    function isValidSigner(address signer, bytes calldata context) external view returns (bytes4 magicValue);
}

interface IERC6551Executable {
    function execute(address to, uint256 value, bytes calldata data, uint8 operation) external payable returns (bytes memory);
}

interface IEIP3009Domain {
    function DOMAIN_SEPARATOR() external view returns (bytes32);
}

/// @title DaemonAccount — the wallet of one Daemon NFT (ERC-6551 token-bound account) and its constitution.
/// @notice Whoever holds the NFT is the owner and can do anything. The daemon's agent key can only act inside limits the
///         owner set — and those limits are bound to the owner who set them: after the NFT changes hands they are inert
///         until the new holder confirms (otherwise a seller could set a payee to themselves, sell, and keep draining).
///
///   Agent rules, all enforced here:
///   - calls only to allowlisted targets (routers, the OTC settlement contract);
///   - every agent call is measured: the account's outflow of the tracked dollar (USDG) and of ETH must stay inside the
///     per-call and per-day caps — whatever the target did, the balance delta is what counts;
///   - tokens may be sent by the agent only to the current holder (a withdrawal); `approve` only to an allowlisted
///     spender (the dollar's capped per call); `transferFrom` never;
///   - x402 payments: the agent never gets raw ERC-1271 power. It asks the account to pre-approve ONE EIP-3009 transfer
///     (payee on the owner's payee list, amount inside the caps); the account computes the exact digest USDG will check
///     and marks it approved. isValidSignature answers yes for approved digests and for the owner's own signatures only.
contract DaemonAccount is IERC165, IERC1271, IERC6551Account, IERC6551Executable {
    bytes32 internal constant TRANSFER_WITH_AUTHORIZATION_TYPEHASH =
        0x7c7c6cdb67a18743f49ec6fa9b35f50d52ed05cbed4cc592e13b44501c1a2267; // EIP-3009, as read off USDG on RHC

    address public immutable dollar; // USDG on Robinhood Chain

    struct Constitution {
        address configuredBy; // the holder who set it; inert for anyone else
        address agent;
        uint128 maxPerCall; // in dollar units (6 decimals); ETH outflow is capped separately below
        uint128 maxPerDay;
        uint128 maxEthPerCall;
    }

    Constitution public constitution;
    mapping(address => mapping(address => bool)) public targetAllowed; // configuredBy => target => allowed
    mapping(address => mapping(address => bool)) public payeeAllowed; //  configuredBy => payee  => allowed
    mapping(bytes32 => bool) public approvedDigest;
    uint256 public spentToday;
    uint256 public spentDay;
    uint256 public state;

    event Constituted(address indexed holder, address agent, uint256 maxPerCall, uint256 maxPerDay);
    event PaymentApproved(bytes32 indexed digest, address indexed to, uint256 value, bytes32 nonce);

    error NotOwner();
    error NotAgent();
    error InertAfterTransfer();
    error TargetNotAllowed(address to);
    error PayeeNotAllowed(address to);
    error OverCap(uint256 amount, uint256 cap);
    error OnlyToHolder();
    error OperationNotSupported();
    error EthOverCap(uint256 amount, uint256 cap);

    constructor(address dollar_) {
        dollar = dollar_;
    }

    receive() external payable {}

    // ── ERC-6551 ───────────────────────────────────────────────────────────────────────────────────────────────────
    function token() public view returns (uint256, address, uint256) {
        bytes memory footer = new bytes(0x60);
        assembly {
            extcodecopy(address(), add(footer, 0x20), 0x4d, 0x60)
        }
        return abi.decode(footer, (uint256, address, uint256));
    }

    function owner() public view returns (address) {
        (uint256 chainId, address tokenContract, uint256 tokenId) = token();
        if (chainId != block.chainid) return address(0);
        return IERC721(tokenContract).ownerOf(tokenId);
    }

    function isValidSigner(address signer, bytes calldata) external view returns (bytes4) {
        return signer == owner() ? IERC6551Account.isValidSigner.selector : bytes4(0);
    }

    // ── The holder's constitution ──────────────────────────────────────────────────────────────────────────────────
    function constitute(address agent, uint128 maxPerCall, uint128 maxPerDay, uint128 maxEthPerCall, address[] calldata targets, address[] calldata payees)
        external
    {
        address o = owner();
        if (msg.sender != o) revert NotOwner();
        ++state;
        constitution = Constitution(o, agent, maxPerCall, maxPerDay, maxEthPerCall);
        for (uint256 i; i < targets.length; ++i) targetAllowed[o][targets[i]] = true;
        for (uint256 i; i < payees.length; ++i) payeeAllowed[o][payees[i]] = true;
        emit Constituted(o, agent, maxPerCall, maxPerDay);
    }

    function _activeAgent() internal view returns (Constitution memory c) {
        c = constitution;
        if (msg.sender != c.agent || c.agent == address(0)) revert NotAgent();
        if (c.configuredBy != owner()) revert InertAfterTransfer();
    }

    function _spend(uint256 amount, Constitution memory c) internal {
        if (amount > c.maxPerCall) revert OverCap(amount, c.maxPerCall);
        uint256 day = block.timestamp / 1 days;
        if (day != spentDay) (spentDay, spentToday) = (day, 0);
        spentToday += amount;
        if (spentToday > c.maxPerDay) revert OverCap(spentToday, c.maxPerDay);
    }

    // ── Execute ────────────────────────────────────────────────────────────────────────────────────────────────────
    function execute(address to, uint256 value, bytes calldata data, uint8 operation) external payable returns (bytes memory result) {
        if (operation != 0) revert OperationNotSupported();
        if (msg.sender == owner()) {
            ++state;
            return _call(to, value, data);
        }
        Constitution memory c = _activeAgent();
        bytes4 sel = data.length >= 4 ? bytes4(data[:4]) : bytes4(0);
        if (sel == IERC20.transfer.selector && data.length >= 68) {
            // any token, agent-sent: only back to the holder (a withdrawal)
            (address rcpt,) = abi.decode(data[4:], (address, uint256));
            if (rcpt != c.configuredBy) revert OnlyToHolder();
            ++state;
            return _call(to, value, data);
        }
        if (sel == IERC20.approve.selector && data.length >= 68) {
            // any token: only an allowlisted spender (a router, the settlement contract); the dollar also capped per call
            (address spender, uint256 amt) = abi.decode(data[4:], (address, uint256));
            if (!targetAllowed[c.configuredBy][spender]) revert TargetNotAllowed(spender);
            if (to == dollar && amt > c.maxPerCall) revert OverCap(amt, c.maxPerCall);
            ++state;
            return _call(to, value, data);
        }
        if (sel == IERC20.transferFrom.selector) revert TargetNotAllowed(to);
        if (!targetAllowed[c.configuredBy][to]) revert TargetNotAllowed(to);
        if (value > c.maxEthPerCall) revert EthOverCap(value, c.maxEthPerCall);
        uint256 before = IERC20(dollar).balanceOf(address(this));
        ++state;
        result = _call(to, value, data);
        uint256 afterBal = IERC20(dollar).balanceOf(address(this));
        if (afterBal < before) _spend(before - afterBal, c); // whatever the target did, the measured outflow is what counts
    }

    function _call(address to, uint256 value, bytes calldata data) internal returns (bytes memory result) {
        bool ok;
        (ok, result) = to.call{value: value}(data);
        if (!ok) {
            assembly {
                revert(add(result, 32), mload(result))
            }
        }
    }

    // ── x402: pre-approved EIP-3009 payments ───────────────────────────────────────────────────────────────────────
    function paymentDigest(address to, uint256 value, uint256 validAfter, uint256 validBefore, bytes32 nonce) public view returns (bytes32) {
        bytes32 structHash = keccak256(abi.encode(TRANSFER_WITH_AUTHORIZATION_TYPEHASH, address(this), to, value, validAfter, validBefore, nonce));
        return keccak256(abi.encodePacked("\x19\x01", IEIP3009Domain(dollar).DOMAIN_SEPARATOR(), structHash));
    }

    function approvePayment(address to, uint256 value, uint256 validAfter, uint256 validBefore, bytes32 nonce) external returns (bytes32 digest) {
        Constitution memory c = _activeAgent();
        if (!payeeAllowed[c.configuredBy][to]) revert PayeeNotAllowed(to);
        _spend(value, c);
        digest = paymentDigest(to, value, validAfter, validBefore, nonce);
        approvedDigest[digest] = true;
        ++state;
        emit PaymentApproved(digest, to, value, nonce);
    }

    function isValidSignature(bytes32 hash, bytes calldata signature) external view returns (bytes4) {
        if (approvedDigest[hash]) return IERC1271.isValidSignature.selector;
        (address rec, ECDSA.RecoverError err,) = ECDSA.tryRecover(hash, signature);
        if (err == ECDSA.RecoverError.NoError && rec == owner() && rec != address(0)) return IERC1271.isValidSignature.selector;
        return bytes4(0xffffffff);
    }

    function supportsInterface(bytes4 id) external pure returns (bool) {
        return id == type(IERC165).interfaceId || id == type(IERC6551Account).interfaceId || id == type(IERC6551Executable).interfaceId
            || id == type(IERC1271).interfaceId;
    }
}
