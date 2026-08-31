// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {
    SafeERC20
} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {
    MessageHashUtils
} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {
    UUPSUpgradeable
} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {
    ReentrancyGuard
} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {
    PausableUpgradeable
} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {
    AccessControlUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";

struct TokenInfo {
    address token;
    // When a withdrawal would make usedWithdrawHotAmount exceed
    // hardCap (= totalLockedTokenAmount * hardCapRatioBps / 10000),
    // pending mode will be activated.
    uint256 hardCapRatioBps;
    // Every second, the usedWithdrawHotAmount will be decreased by refillRateMps / 1000000 * hardCap
    uint256 refillRateMps;
    // The timestamp of the last refill
    uint256 lastRefillTimestamp;
    // Every time user withdraw in fast mode, this amount will be deducted
    uint256 usedWithdrawHotAmount;
}

struct ValidatorInfo {
    address signer;
    uint256 power;
}

struct WithdrawAction {
    address token;
    uint256 amount;
    uint256 fee;
    address receiver;
}

struct Withdrawal {
    bool paused;
    bool pending;
    bool executed;
    uint256 amount;
    address token;
    uint256 fee;
    address receiver;
    uint256 timestamp;
}

contract AssetVault is
    PausableUpgradeable,
    AccessControlUpgradeable,
    UUPSUpgradeable,
    ReentrancyGuard
{
    error ValidatorsAlreadySet();
    error ValidatorsNotOrdered();
    error ValidatorsNotSet();
    error TokensAndAmountsLengthMismatch();
    error TokenAlreadyExists();
    error ZeroAmount();
    error EmptyIds();
    error ChallengePeriodNotExpired();
    error ChallengePeriodExpired();
    error WithdrawAlreadyInDesiredState();
    error WithdrawalPaused();
    error WithdrawalMustBePending();
    error EmptyTokens();
    error InvalidParameters();
    error InvalidValidators();
    error NotEnoughValidatorPower();
    error TokenInvalid();
    error WithdrawalExistenceCheckFailed();
    error WithdrawalAlreadyExecuted();
    error NonceAlreadyUsed();
    error InsufficientVaultBalance();
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 public constant VALIDATOR_ROLE = keccak256("VALIDATOR_ROLE");
    bytes32 public constant TOKEN_ROLE = keccak256("TOKEN_ROLE");
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant DEPOSIT_ROLE = keccak256("DEPOSIT_ROLE");
    bytes32 public constant PAUSE_ROLE = keccak256("PAUSE_ROLE");
    bytes32 public constant UPGRADE_ROLE = keccak256("UPGRADE_ROLE");

    mapping(address => TokenInfo) public supportedTokens;

    mapping(uint256 => Withdrawal) public withdrawals;
    // After challenge period, the pending withdraw can be withdrawn unconditionally
    uint256 public pendingWithdrawChallengePeriod;

    mapping(bytes32 => uint256) public availableValidators;
    mapping(bytes32 => uint256) public validatorRequiredPowers;

    mapping(address => uint256) public fees;

    mapping(uint256 => bool) public nonceUsed;
    address public rebalanceReceiver;

    event DepositETH(address account, uint256 amount);
    event DepositOnBehalf(
        address caller,
        address indexed forAccount,
        address indexed token,
        uint256 amount,
        bytes data
    );

    event TokenAdded(
        address token,
        uint256 hardCapRatioBps,
        uint256 refillRateMps
    );
    event TokenUpdated(
        address token,
        uint256 hardCapRatioBps,
        uint256 refillRateMps
    );

    event WithdrawHotAmountRefilled(
        address token,
        uint256 refillAmount,
        uint256 usedWithdrawHotAmount
    );
    event WithdrawHotAmountUsed(
        address token,
        uint256 amount,
        uint256 updateUsedWithdrawHotAmount,
        bool forcePending
    );
    event WithdrawalAdded(
        uint256 withdrawalId,
        address token,
        uint256 amount,
        uint256 fee,
        address receiver,
        bool isPending,
        bool isForcePending,
        uint256 nonce
    );
    event WithdrawExecuted(
        uint256 withdrawalId,
        address to,
        address token,
        uint256 amount,
        uint256 fee,
        // Whether the withdrawal is pending when executed
        bool isPending,
        // Whether the withdrawal is flushed
        bool isFlushed,
        // Whether the withdrawal is paused when executed
        bool isPaused,
        uint256 nonce
    );
    event PendingWithdrawalToggled(
        uint256 withdrawalId, 
        bool paused,
        uint256 nonce
    );

    event ValidatorsAdded(
        bytes32 hash,
        address[] validatorAddresses,
        uint256 count,
        uint256 totalPower,
        uint256 requiredPower
    );
    event ValidatorsRemoved(
        bytes32 hash,
        address[] validatorAddresses,
        uint256 count
    );
    event ValidatorRequiredPowerUpdated(
        bytes32 hash,
        address[] validatorAddresses,
        uint256 oldRequiredPower,
        uint256 newRequiredPower
    );

    event PendingWithdrawChallengePeriodUpdated(
        uint256 oldValue,
        uint256 newValue
    );
    event RebalanceReceiverUpdated(address oldReceiver, address newReceiver);
    event RebalanceWithdrawExecuted(
        address receiver,
        address token,
        uint256 amount,
        uint256 nonce
    );

    // Fee events
    event FeesWithdrawn(address to);

    constructor() {
        _disableInitializers();
    }

    function initialize(
        uint256 _pendingWithdrawChallengePeriod
    ) public initializer {
        __Pausable_init();
        __AccessControl_init();
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        pendingWithdrawChallengePeriod = _pendingWithdrawChallengePeriod;
    }

    function _authorizeUpgrade(
        address newImplementation
    ) internal override(UUPSUpgradeable) onlyRole(UPGRADE_ROLE) {}

    function toggle(bool pause) external onlyRole(PAUSE_ROLE) {
        pause ? _pause() : _unpause();
    }

    function updatePendingWithdrawChallengePeriod(
        uint256 newValue
    ) external onlyRole(ADMIN_ROLE) {
        uint256 oldValue = pendingWithdrawChallengePeriod;
        pendingWithdrawChallengePeriod = newValue;
        emit PendingWithdrawChallengePeriodUpdated(oldValue, newValue);
    }

    function setRebalanceReceiver(
        address newReceiver
    ) external onlyRole(ADMIN_ROLE) {
        if (newReceiver == address(0)) {
            revert InvalidParameters();
        }
        address oldReceiver = rebalanceReceiver;
        rebalanceReceiver = newReceiver;
        emit RebalanceReceiverUpdated(oldReceiver, newReceiver);
    }

    function addValidators(
        ValidatorInfo[] calldata validators,
        uint256 requiredPower
    ) external onlyRole(VALIDATOR_ROLE) {
        bytes32 validatorHash = keccak256(abi.encode(validators));
        if (availableValidators[validatorHash] != 0) {
            revert ValidatorsAlreadySet();
        }
        uint256 totalPower = 0;
        address lastValidator = address(0);
        for (uint256 i = 0; i < validators.length; i++) {
            if (validators[i].signer <= lastValidator) {
                revert ValidatorsNotOrdered();
            }
            if (validators[i].power == 0) {
                revert InvalidParameters();
            }
            totalPower += validators[i].power;
            lastValidator = validators[i].signer;
        }
        _validateValidatorRequiredPower(requiredPower, totalPower);
        availableValidators[validatorHash] = totalPower;
        validatorRequiredPowers[validatorHash] = requiredPower;
        address[] memory validatorAddresses = _validatorAddresses(validators);
        emit ValidatorsAdded(
            validatorHash,
            validatorAddresses,
            validators.length,
            totalPower,
            requiredPower
        );
    }

    function updateValidatorRequiredPower(
        ValidatorInfo[] calldata validators,
        uint256 newRequiredPower
    ) external onlyRole(VALIDATOR_ROLE) {
        bytes32 validatorHash = keccak256(abi.encode(validators));
        uint256 totalPower = availableValidators[validatorHash];
        if (totalPower == 0) {
            revert ValidatorsNotSet();
        }
        _validateValidatorRequiredPower(newRequiredPower, totalPower);
        uint256 oldRequiredPower = validatorRequiredPowers[validatorHash];
        validatorRequiredPowers[validatorHash] = newRequiredPower;
        address[] memory validatorAddresses = _validatorAddresses(validators);
        emit ValidatorRequiredPowerUpdated(
            validatorHash,
            validatorAddresses,
            oldRequiredPower,
            newRequiredPower
        );
    }

    function removeValidators(
        ValidatorInfo[] calldata validators
    ) external onlyRole(VALIDATOR_ROLE) {
        bytes32 validatorHash = keccak256(abi.encode(validators));
        if (availableValidators[validatorHash] == 0) {
            revert ValidatorsNotSet();
        }
        delete availableValidators[validatorHash];
        delete validatorRequiredPowers[validatorHash];
        emit ValidatorsRemoved(
            validatorHash,
            _validatorAddresses(validators),
            validators.length
        );
    }

    function withdrawFees(
        address[] calldata tokens,
        address to
    ) external whenNotPaused onlyRole(ADMIN_ROLE) nonReentrant {
        for (uint256 i = 0; i < tokens.length; i++) {
            address token = tokens[i];
            uint256 fee = fees[token];
            if (fee == 0) { 
                continue;
            }
            fees[token] = 0;
            _transfer(payable(to), token, fee, 0);
        }
        emit FeesWithdrawn(to);
    }

    function addToken(
        address token,
        uint256 hardCapRatioBps,
        uint256 refillRateMps
    ) external onlyRole(TOKEN_ROLE) {
        TokenInfo storage tokenInfo = supportedTokens[token];
        if (_isTokenSupported(token)) {
            revert TokenAlreadyExists();
        }
        _validateTokenConfig(hardCapRatioBps, refillRateMps);
        tokenInfo.token = token;
        tokenInfo.hardCapRatioBps = hardCapRatioBps;
        tokenInfo.refillRateMps = refillRateMps;
        emit TokenAdded(token, hardCapRatioBps, refillRateMps);
    }

    function updateToken(
        address token,
        uint256 hardCapRatioBps,
        uint256 refillRateMps
    ) external onlyRole(TOKEN_ROLE) {
        _ensureTokenValid(token);
        _validateTokenConfig(hardCapRatioBps, refillRateMps);
        _refillWithdrawHotAmount(token);
        TokenInfo storage tokenInfo = supportedTokens[token];
        tokenInfo.hardCapRatioBps = hardCapRatioBps;
        tokenInfo.refillRateMps = refillRateMps;
        emit TokenUpdated(token, hardCapRatioBps, refillRateMps);
    }

    receive() external payable {
        if (msg.value == 0) {
            revert ZeroAmount();
        }
        _ensureTokenValid(address(0));
        emit DepositETH(msg.sender, msg.value);
    }

    function depositOnBehalf(
        address token,
        address forAccount,
        uint256 amount,
        bytes calldata data
    ) external payable whenNotPaused onlyRole(DEPOSIT_ROLE) nonReentrant {
        if (forAccount == address(0)) {
            revert InvalidParameters();
        }
        if (amount == 0) {
            revert ZeroAmount();
        }

        _ensureTokenValid(token);

        if (token == address(0)) {
            if (msg.value != amount) {
                revert InvalidParameters();
            }
        } else {
            if (msg.value != 0) {
                revert InvalidParameters();
            }
            SafeERC20.safeTransferFrom(
                IERC20(token),
                msg.sender,
                address(this),
                amount
            );
        }

        emit DepositOnBehalf(msg.sender, forAccount, token, amount, data);
    }

    struct RequestWithdrawLocalVars {
        bytes32 digest;
        bool isPending;
    }

    function requestWithdraw(
        uint256 withdrawalId,
        bool isForcePending,
        ValidatorInfo[] calldata validators,
        WithdrawAction calldata action,
        bytes[] calldata validatorSignatures,
        uint256 nonce
    ) external whenNotPaused onlyRole(OPERATOR_ROLE) nonReentrant {
        RequestWithdrawLocalVars memory vars;

        _nonceUsedCheckAndSet(nonce);
        _ensureTokenValid(action.token);
        _refillWithdrawHotAmount(action.token);
        _checkWithdrawalExists(withdrawalId, false);
        _checkTokenBalance(action.token, action.amount);

        vars.digest = keccak256(
            abi.encode(
                "requestWithdraw",
                withdrawalId,
                block.chainid,
                address(this),
                action.token,
                action.amount,
                action.fee,
                action.receiver,
                isForcePending,
                nonce
            )
        );

        _verifyValidatorSignature(validators, vars.digest, validatorSignatures);

        vars.isPending = isForcePending;
        if (!isForcePending) {
            // when normal withdrawal triggers hard cap exceeded, fallback to pending mode
            vars.isPending = _increaseUsedWithdrawHotAmount(
                supportedTokens[action.token],
                action.amount
            );
        }
        withdrawals[withdrawalId] = Withdrawal(
            false,
            vars.isPending,
            false,
            action.amount,
            action.token,
            action.fee,
            action.receiver,
            block.timestamp
        );
        emit WithdrawalAdded(
            withdrawalId,
            action.token,
            action.amount,
            action.fee,
            action.receiver,
            vars.isPending,
            isForcePending,
            nonce
        );
        if (!vars.isPending) {
            _executeWithdrawal(withdrawalId, false, false, false, nonce);
        }
    }

    function rebalanceWithdraw(
        address token,
        uint256 amount,
        ValidatorInfo[] calldata validators,
        bytes[] calldata validatorSignatures,
        uint256 nonce
    ) external whenNotPaused onlyRole(OPERATOR_ROLE) nonReentrant {
        address receiver = rebalanceReceiver;
        if (receiver == address(0)) {
            revert InvalidParameters();
        }

        _nonceUsedCheckAndSet(nonce);
        _ensureTokenValid(token);
        _checkTokenBalance(token, amount);

        bytes32 digest = keccak256(
            abi.encode(
                "rebalanceWithdraw",
                block.chainid,
                address(this),
                token,
                amount,
                receiver,
                nonce
            )
        );

        _verifyValidatorSignature(validators, digest, validatorSignatures);
        _transfer(payable(receiver), token, amount, 0);
        emit RebalanceWithdrawExecuted(receiver, token, amount, nonce);
    }

    function batchTogglePendingWithdrawal(
        uint256[] calldata withdrawalIds,
        bool shouldPause,
        ValidatorInfo[] calldata validators,
        bytes[] calldata validatorSignatures,
        uint256 nonce
    ) external whenNotPaused onlyRole(OPERATOR_ROLE) nonReentrant {
        if (withdrawalIds.length == 0) {
            revert EmptyIds();
        }
        _nonceUsedCheckAndSet(nonce);
        bytes32 digest = keccak256(
            abi.encode(
                "batchTogglePendingWithdrawal",
                withdrawalIds,
                block.chainid,
                address(this),
                shouldPause,
                nonce
            )
        );

        _verifyValidatorSignature(validators, digest, validatorSignatures);

        for (uint256 i = 0; i < withdrawalIds.length; i++) {
            Withdrawal storage withdrawal = withdrawals[withdrawalIds[i]];
            _refillWithdrawHotAmount(withdrawal.token);
            // 1. executed withdrawal cannot be paused/unpaused
            // 2. only pending withdrawals can be paused/unpaused
            // 3. after challenge period expiry, only unpause is allowed
            _checkWithdrawalNotExecuted(withdrawalIds[i]);
            _checkWithdrawalPending(withdrawalIds[i]);
            if (withdrawal.paused == shouldPause) {
                revert WithdrawAlreadyInDesiredState();
            }
            if (
                shouldPause &&
                block.timestamp >=
                withdrawal.timestamp + pendingWithdrawChallengePeriod
            ) {
                revert ChallengePeriodExpired();
            }
            withdrawal.paused = shouldPause;
            emit PendingWithdrawalToggled(withdrawalIds[i], shouldPause, nonce);
        }
    }

    function executeExpiredPendingWithdrawal(
        uint256 withdrawalId
    ) external whenNotPaused nonReentrant {
        _checkWithdrawalExists(withdrawalId, true);
        _checkWithdrawalNotExecuted(withdrawalId);
        Withdrawal storage withdrawal = withdrawals[withdrawalId];
        _refillWithdrawHotAmount(withdrawal.token);
        _checkWithdrawalPending(withdrawalId);
        if (withdrawal.paused) {
            revert WithdrawalPaused();
        }
        if (block.timestamp < withdrawal.timestamp + pendingWithdrawChallengePeriod) {
            revert ChallengePeriodNotExpired();
        }
        _executeWithdrawal(withdrawalId, true, false, false, 0);
    }

    // Flushing can bypass challenge-period expiry, but cannot bypass the paused flag.
    function batchFlushWithdrawals(
        uint256[] calldata withdrawalIds,
        ValidatorInfo[] calldata validators,
        bytes[] calldata validatorSignatures,
        uint256 nonce
    ) external whenNotPaused onlyRole(OPERATOR_ROLE) nonReentrant {
        if (withdrawalIds.length == 0) {
            revert EmptyIds();
        }
        _nonceUsedCheckAndSet(nonce);
        bytes32 digest = keccak256(
            abi.encode(
                "batchFlushWithdrawals",
                withdrawalIds,
                block.chainid,
                address(this),
                nonce
            )
        );
        _verifyValidatorSignature(validators, digest, validatorSignatures);
        for (uint256 i = 0; i < withdrawalIds.length; i++) {
            uint256 withdrawalId = withdrawalIds[i];
            _checkWithdrawalExists(withdrawalId, true);
            _checkWithdrawalNotExecuted(withdrawalId);
            Withdrawal storage withdrawal = withdrawals[withdrawalId];
            _refillWithdrawHotAmount(withdrawal.token);
            _checkWithdrawalPending(withdrawalId);
            if (withdrawal.paused) {
                revert WithdrawalPaused();
            }
            _executeWithdrawal(withdrawalId, withdrawal.pending, true, withdrawal.paused, nonce);
        }
    }

    function batchResetWithdrawHotAmount(
        address[] calldata tokens,
        ValidatorInfo[] calldata validators,
        bytes[] calldata validatorSignatures,
        uint256 nonce
    ) external whenNotPaused onlyRole(OPERATOR_ROLE) nonReentrant {
        if (tokens.length == 0) {
            revert EmptyTokens();
        }
        _nonceUsedCheckAndSet(nonce);
        bytes32 digest = keccak256(
            abi.encode(
                "batchResetWithdrawHotAmount",
                tokens,
                block.chainid,
                address(this),
                nonce
            )
        );
        _verifyValidatorSignature(validators, digest, validatorSignatures);
        for (uint256 i = 0; i < tokens.length; i++) {
            _ensureTokenValid(tokens[i]);
            TokenInfo storage tokenInfo = supportedTokens[tokens[i]];
            emit WithdrawHotAmountRefilled(tokens[i], tokenInfo.usedWithdrawHotAmount, 0);
            tokenInfo.usedWithdrawHotAmount = 0;
            tokenInfo.lastRefillTimestamp = block.timestamp;
        }
    }

    function getHardCap(address token) public view returns (uint256) {
        TokenInfo storage tokenInfo = supportedTokens[token];
        uint256 balance = token == address(0)
            ? address(this).balance
            : IERC20(token).balanceOf(address(this));
        return (balance * tokenInfo.hardCapRatioBps) / 10000;
    }

    // ================================ Internal Functions ================================

    function _validateTokenConfig(
        uint256 hardCapRatioBps,
        uint256 refillRateMps
    ) internal pure {
        if (
            hardCapRatioBps == 0 ||
            hardCapRatioBps > 10000 ||
            refillRateMps == 0 ||
            refillRateMps > 1000000
        ) {
            revert InvalidParameters();
        }
    }

    function _validateValidatorRequiredPower(
        uint256 requiredPower,
        uint256 totalPower
    ) internal pure {
        if (
            requiredPower == 0 ||
            totalPower == 0 ||
            requiredPower > totalPower
        ) {
            revert InvalidParameters();
        }
    }

    function _validatorAddresses(
        ValidatorInfo[] calldata validators
    ) internal pure returns (address[] memory addresses) {
        addresses = new address[](validators.length);
        for (uint256 i = 0; i < validators.length; i++) {
            addresses[i] = validators[i].signer;
        }
    }

    // validators must be sorted by address
    function _verifyValidatorSignature(
        ValidatorInfo[] calldata validators,
        bytes32 digest,
        bytes[] calldata validatorSignatures
    ) internal view {
        bytes32 validatorHash = keccak256(abi.encode(validators));
        uint256 totalPower = availableValidators[validatorHash];
        if (totalPower == 0) {
            revert InvalidValidators();
        }
        uint256 requiredPower = validatorRequiredPowers[validatorHash];
        uint256 power = 0;
        uint256 validatorIndex = 0;
        bytes32 validatorDigest = MessageHashUtils.toEthSignedMessageHash(
            digest
        );
        for (
            uint256 signatureIndex = 0;
            signatureIndex < validatorSignatures.length &&
                validatorIndex < validators.length;
            signatureIndex++
        ) {
            (address recovered, ECDSA.RecoverError recoverError, ) = ECDSA.tryRecoverCalldata(
                validatorDigest,
                validatorSignatures[signatureIndex]
            );
            if (recoverError != ECDSA.RecoverError.NoError || recovered == address(0)) {
                continue;
            }
            while (validatorIndex < validators.length) {
                address validator = validators[validatorIndex].signer;
                validatorIndex++;
                if (validator == recovered) {
                    power += validators[validatorIndex - 1].power;
                    break;
                }
            }
        }
        if (power < requiredPower) {
            revert NotEnoughValidatorPower();
        }
    }

    function _refillWithdrawHotAmount(address token) internal {
        TokenInfo storage tokenInfo = supportedTokens[token];
        uint256 refillPeriod = block.timestamp - tokenInfo.lastRefillTimestamp;
        if (refillPeriod == 0) {
            return;
        }
        uint256 hardCap = getHardCap(token);
        uint256 refillAmount = (hardCap *
            tokenInfo.refillRateMps *
            refillPeriod) / 1000000;
        uint256 appliedRefillAmount = refillAmount;
        if (tokenInfo.usedWithdrawHotAmount < refillAmount) {
            appliedRefillAmount = tokenInfo.usedWithdrawHotAmount;
            tokenInfo.usedWithdrawHotAmount = 0;
        } else {
            tokenInfo.usedWithdrawHotAmount -= refillAmount;
        }
        tokenInfo.lastRefillTimestamp = block.timestamp;
        emit WithdrawHotAmountRefilled(
            tokenInfo.token,
            appliedRefillAmount,
            tokenInfo.usedWithdrawHotAmount
        );
    }

    function _increaseUsedWithdrawHotAmount(
        TokenInfo storage tokenInfo,
        uint256 amount
    ) internal returns (bool pendingTriggered) {
        uint256 hardCap = getHardCap(tokenInfo.token);
        // hard cap exceeded
        if (tokenInfo.usedWithdrawHotAmount + amount > hardCap) {
            pendingTriggered = true;
        } else {
            tokenInfo.usedWithdrawHotAmount += amount;
        }
        emit WithdrawHotAmountUsed(
            tokenInfo.token,
            amount,
            tokenInfo.usedWithdrawHotAmount,
            pendingTriggered
        );
    }

    function _executeWithdrawal(
        uint256 withdrawalId,
        bool isPending,
        bool isFlushed,
        bool isPaused,
        uint256 nonce
    ) internal {
        Withdrawal storage withdrawal = withdrawals[withdrawalId];
        withdrawal.executed = true;
        _transfer(
            payable(withdrawal.receiver),
            withdrawal.token,
            withdrawal.amount,
            withdrawal.fee
        );
        emit WithdrawExecuted(
            withdrawalId,
            withdrawal.receiver,
            withdrawal.token,
            withdrawal.amount,
            withdrawal.fee,
            isPending,
            isFlushed,
            isPaused,
            nonce
        );
    }

    function _ensureTokenValid(address token) internal view {
        if (!_isTokenSupported(token)) {
            revert TokenInvalid();
        }
    }

    function _isTokenSupported(address token) internal view returns (bool) {
        return supportedTokens[token].hardCapRatioBps != 0;
    }

    function _nonceUsedCheckAndSet(uint256 nonce) internal {
        if (nonceUsed[nonce]) {
            revert NonceAlreadyUsed();
        }
        nonceUsed[nonce] = true;
    }

    function _checkWithdrawalExists(
        uint256 id,
        bool shouldExist
    ) internal view {
        bool isExisting = withdrawals[id].timestamp > 0;
        if (isExisting != shouldExist) {
            revert WithdrawalExistenceCheckFailed();
        }
    }

    function _checkWithdrawalNotExecuted(uint256 id) internal view {
        if (withdrawals[id].executed) {
            revert WithdrawalAlreadyExecuted();
        }
    }

    function _checkWithdrawalPending(uint256 id) internal view {
        if (!withdrawals[id].pending) {
            revert WithdrawalMustBePending();
        }
    }

    function _checkTokenBalance(
        address token,
        uint256 amount
    ) internal view {
        if (token == address(0) && amount > address(this).balance) {
            revert InsufficientVaultBalance();
        } else if (token != address(0) && amount > IERC20(token).balanceOf(address(this))) {
            revert InsufficientVaultBalance();
        }
    }

    function _transfer(
        address payable to,
        address token,
        uint256 amount,
        uint256 fee
    ) private {
        if (amount == 0) {
            revert ZeroAmount();
        }
        if (fee >= amount) {
            revert InvalidParameters();
        }
        if (token == address(0)) {
            Address.sendValue(payable(to), amount - fee);
            if (fee > 0) {
                fees[token] += fee;
            }
        } else {
            SafeERC20.safeTransfer(IERC20(token), to, amount - fee);
            if (fee > 0) {
                fees[token] += fee;
            }
        }
    }
}
