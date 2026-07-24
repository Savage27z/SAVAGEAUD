// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "openzeppelin-contracts/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {ERC20Votes} from "openzeppelin-contracts/contracts/token/ERC20/extensions/ERC20Votes.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {Nonces} from "openzeppelin-contracts/contracts/utils/Nonces.sol";
import {
    IManagerContractOperationalLookup,
    NoPaymentDue,
    ZeroTokenAddress,
    TokenAlreadyTracked,
    MaxTrackedTokensReached,
    ZeroManagerContract,
    ManagerContractAlreadySet,
    NotManagerContract,
    NotAuthorisedToNotify,
    NotInitialOwner,
    NotAuthorisedToRelease,
    TokenIsSkipped
} from "./feeSplitterLibraries/FeeSplitterTypes.sol";

contract FeeSplitter is ERC20, ERC20Permit, ERC20Votes {
    using SafeERC20 for IERC20;

    // ════════════════════════════════════════════════════════════════════════
    //  CONSTANTS
    // ════════════════════════════════════════════════════════════════════════

    uint256 public constant TOTAL_SHARES = 1e18;
    uint256 public constant MAX_TRACKED_TOKENS = 20;
    uint256 private constant ACC_PRECISION = 1e30;

    // ════════════════════════════════════════════════════════════════════════
    //  ACCOUNTING STORAGE
    // ════════════════════════════════════════════════════════════════════════

    mapping(IERC20 => uint256) public totalReleasedByToken;
    mapping(IERC20 => mapping(address => uint256)) public releasedByTokenAndAccount;

    mapping(IERC20 => uint256) private _accPerShare;
    mapping(IERC20 => uint256) private _lastSeenReceived;
    mapping(IERC20 => mapping(address => uint256)) private _rewardDebt;
    mapping(IERC20 => mapping(address => uint256)) private _pending;

    // ════════════════════════════════════════════════════════════════════════
    //  TRACKED TOKEN STORAGE
    // ════════════════════════════════════════════════════════════════════════

    IERC20[] private _trackedTokens;
    mapping(IERC20 => bool) private _isTracked;
    mapping(IERC20 => bool) private _skipped;

    // ════════════════════════════════════════════════════════════════════════
    //  GOVERNANCE STORAGE
    // ════════════════════════════════════════════════════════════════════════

    address public managerContract;
    address public immutable initialOwner;

    // ════════════════════════════════════════════════════════════════════════
    //  EVENTS
    // ════════════════════════════════════════════════════════════════════════

    event PaymentReleased(IERC20 indexed token, address indexed account, uint256 amount);
    event RewardNotified(IERC20 indexed token, uint256 deltaReceived, uint256 accPerShare);
    event TrackedTokenAdded(IERC20 indexed token, address indexed addedBy);
    event ManagerContractSet(address indexed managerContract);
    event TokenSkippedSet(IERC20 indexed token, bool skipped, address indexed by);

    // ════════════════════════════════════════════════════════════════════════
    //  INIT
    // ════════════════════════════════════════════════════════════════════════

    constructor(address initialShareOwner, IERC20[] memory initialTrackedTokens)
        ERC20("Basalt Fee Share", "BFS")
        ERC20Permit("Basalt Fee Share")
    {
        initialOwner = msg.sender;
        _mint(initialShareOwner, TOTAL_SHARES);
        _delegate(initialShareOwner, initialShareOwner);

        uint256 len = initialTrackedTokens.length;
        if (len > MAX_TRACKED_TOKENS) revert MaxTrackedTokensReached(MAX_TRACKED_TOKENS);
        for (uint256 i = 0; i < len; i++) {
            IERC20 t = initialTrackedTokens[i];
            if (address(t) == address(0)) revert ZeroTokenAddress();
            if (_isTracked[t]) revert TokenAlreadyTracked(t);
            _isTracked[t] = true;
            _trackedTokens.push(t);
            emit TrackedTokenAdded(t, msg.sender);
        }
    }

    // ════════════════════════════════════════════════════════════════════════
    //  INITIAL OWNER GOVERNANCE
    // ════════════════════════════════════════════════════════════════════════

    function setManagerContract(address newManagerContract) external {
        if (msg.sender != initialOwner) revert NotInitialOwner(msg.sender);
        if (newManagerContract == address(0)) revert ZeroManagerContract();
        if (managerContract != address(0)) revert ManagerContractAlreadySet(managerContract);
        managerContract = newManagerContract;
        emit ManagerContractSet(newManagerContract);
    }

    // ════════════════════════════════════════════════════════════════════════
    //  MANAGER GOVERNANCE
    // ════════════════════════════════════════════════════════════════════════

    function addTrackedToken(IERC20 token) external {
        if (msg.sender != managerContract) revert NotManagerContract(msg.sender);
        if (address(token) == address(0)) revert ZeroTokenAddress();
        if (_isTracked[token]) revert TokenAlreadyTracked(token);
        if (_trackedTokens.length >= MAX_TRACKED_TOKENS) revert MaxTrackedTokensReached(MAX_TRACKED_TOKENS);
        _isTracked[token] = true;
        _trackedTokens.push(token);
        emit TrackedTokenAdded(token, msg.sender);
    }

    function setTokenSkipped(IERC20 token, bool v) external {
        if (msg.sender != managerContract) revert NotManagerContract(msg.sender);
        _skipped[token] = v;
        emit TokenSkippedSet(token, v, msg.sender);
    }

    // ════════════════════════════════════════════════════════════════════════
    //  VIEWS
    // ════════════════════════════════════════════════════════════════════════

    function isSkipped(IERC20 token) external view returns (bool) {
        return _skipped[token];
    }

    function nonces(address owner) public view virtual override(ERC20Permit, Nonces) returns (uint256) {
        return super.nonces(owner);
    }

    function trackedTokensLength() external view returns (uint256) {
        return _trackedTokens.length;
    }

    function trackedTokenAt(uint256 index) external view returns (IERC20) {
        return _trackedTokens[index];
    }

    function isTrackedToken(IERC20 token) external view returns (bool) {
        return _isTracked[token];
    }

    function releasable(IERC20 token, address account) public view returns (uint256) {
        uint256 ts = totalSupply();
        if (ts == 0) return _pending[token][account];
        if (!_isTracked[token]) return _pending[token][account];
        if (_skipped[token]) return _pending[token][account];

        uint256 accPreview = _accPerShare[token];
        uint256 received = token.balanceOf(address(this)) + totalReleasedByToken[token];
        uint256 last = _lastSeenReceived[token];
        if (received > last) {
            accPreview += ((received - last) * ACC_PRECISION) / ts;
        }

        uint256 accrued = (accPreview * balanceOf(account)) / ACC_PRECISION;
        uint256 debt = _rewardDebt[token][account];
        uint256 fresh = accrued > debt ? accrued - debt : 0;
        return _pending[token][account] + fresh;
    }

    // ════════════════════════════════════════════════════════════════════════
    //  REWARD SYNC
    // ════════════════════════════════════════════════════════════════════════

    function notifyReward(IERC20 token) external returns (uint256 accPerShare) {
        if (msg.sender != managerContract && balanceOf(msg.sender) == 0) {
            revert NotAuthorisedToNotify(msg.sender);
        }
        if (_skipped[token]) revert TokenIsSkipped(token);
        accPerShare = _syncAccumulator(token);
    }

    // ════════════════════════════════════════════════════════════════════════
    //  RELEASE
    // ════════════════════════════════════════════════════════════════════════

    function release(IERC20 token, address account) external {
        _requireHolderOrOperational();
        if (_skipped[token]) revert TokenIsSkipped(token);

        _syncAccumulator(token);
        _settle(token, account);

        uint256 payment = _pending[token][account];
        if (payment == 0) revert NoPaymentDue(account, token);

        _pending[token][account] = 0;
        totalReleasedByToken[token] += payment;
        releasedByTokenAndAccount[token][account] += payment;

        token.safeTransfer(account, payment);
        emit PaymentReleased(token, account, payment);
    }

    // ════════════════════════════════════════════════════════════════════════
    //  TRANSFER HOOK
    // ════════════════════════════════════════════════════════════════════════

    function _update(address from, address to, uint256 value) internal override(ERC20, ERC20Votes) {
        uint256 len = _trackedTokens.length;
        for (uint256 i = 0; i < len; i++) {
            IERC20 t = _trackedTokens[i];
            if (_skipped[t]) continue;
            _syncAccumulator(t);
            if (from != address(0)) _settle(t, from);
            if (to != address(0)) _settle(t, to);
        }

        super._update(from, to, value);

        for (uint256 i = 0; i < len; i++) {
            IERC20 t = _trackedTokens[i];
            if (_skipped[t]) continue;
            uint256 acc = _accPerShare[t];
            if (from != address(0)) _rewardDebt[t][from] = (acc * balanceOf(from)) / ACC_PRECISION;
            if (to != address(0)) _rewardDebt[t][to] = (acc * balanceOf(to)) / ACC_PRECISION;
        }

        if (to != address(0) && balanceOf(to) > 0 && delegates(to) == address(0)) {
            _delegate(to, to);
        }
    }

    // ════════════════════════════════════════════════════════════════════════
    //  INTERNAL ACCOUNTING
    // ════════════════════════════════════════════════════════════════════════

    function _syncAccumulator(IERC20 token) private returns (uint256) {
        if (!_isTracked[token]) {
            return _accPerShare[token];
        }

        uint256 ts = totalSupply();
        uint256 received = token.balanceOf(address(this)) + totalReleasedByToken[token];
        uint256 last = _lastSeenReceived[token];
        uint256 acc = _accPerShare[token];

        if (received > last) {
            if (ts == 0) {
                _lastSeenReceived[token] = received;
            } else {
                uint256 delta = received - last;
                acc += (delta * ACC_PRECISION) / ts;
                _accPerShare[token] = acc;
                _lastSeenReceived[token] = received;
                emit RewardNotified(token, delta, acc);
            }
        }
        return acc;
    }

    function _settle(IERC20 token, address account) private {
        uint256 accrued = (_accPerShare[token] * balanceOf(account)) / ACC_PRECISION;
        uint256 debt = _rewardDebt[token][account];
        if (accrued > debt) {
            _pending[token][account] += accrued - debt;
            _rewardDebt[token][account] = accrued;
        }
    }

    // ════════════════════════════════════════════════════════════════════════
    //  ACL HELPERS
    // ════════════════════════════════════════════════════════════════════════

    function _requireHolderOrOperational() private view {
        if (balanceOf(msg.sender) > 0) return;
        address mc = managerContract;
        if (mc != address(0) && msg.sender == IManagerContractOperationalLookup(mc).operational()) return;
        revert NotAuthorisedToRelease(msg.sender);
    }
}
