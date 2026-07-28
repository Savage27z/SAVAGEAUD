// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {AccessControl} from "openzeppelin-contracts/contracts/access/AccessControl.sol";
import {Pausable} from "openzeppelin-contracts/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

import {IV3SwapRouter} from "swap-router-contracts/contracts/interfaces/IV3SwapRouter.sol";
import {RewardsDistributor} from "../staking/RewardsDistributor.sol";
import {Staking} from "../staking/Staking.sol";

/// @title Treasury
/// @notice Manages K613 token flows: stakes K613 to get xK613 for rewards, executes buybacks. Rewards are distributed in xK613.
contract Treasury is AccessControl, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice Thrown when a zero address is passed as a parameter.
    error ZeroAddress();
    /// @notice Thrown when amount is zero where a positive value is required.
    error ZeroAmount();
    /// @notice Thrown when the DEX swap call fails.
    error BuybackFailed();
    /// @notice Thrown when the swap output is less than minK613Out.
    error InsufficientOutput();
    /// @notice Thrown when buyback is called with a router not in the whitelist.
    error RouterNotWhitelisted();

    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    IERC20 public immutable k613;
    IERC20 public immutable xk613;
    Staking public immutable staking;
    RewardsDistributor public immutable rewardsDistributor;

    /// @notice Whitelist of DEX routers allowed for buyback. Only DEFAULT_ADMIN_ROLE can update.
    mapping(address => bool) public routerWhitelist;
    /// @notice List of whitelisted router addresses for enumeration (see getWhitelistedRouters).
    address[] private _whitelistedRouters;

    /// @notice Emitted when admin withdraws tokens.
    /// @param token Token withdrawn.
    /// @param to Recipient.
    /// @param amount Amount withdrawn.
    event Withdrawn(address indexed token, address indexed to, uint256 amount);

    /// @notice Emitted when a buyback is executed.
    /// @param tokenIn Token swapped in for K613.
    /// @param router DEX router used for the swap.
    /// @param amountIn Amount of tokenIn swapped.
    /// @param k613Out Amount of K613 received.
    /// @param distributed Whether rewards were distributed to stakers.
    event BuybackExecuted(
        address indexed tokenIn, address indexed router, uint256 amountIn, uint256 k613Out, bool distributed
    );
    /// @notice Emitted when a router is added to or removed from the whitelist.
    event RouterWhitelistUpdated(address indexed router, bool allowed);

    event Xk613PullAllowanceSet(address indexed spender, uint256 amount);

    /// @notice Emitted when Treasury stakes K613 it already holds, to obtain xK613 used as the reward
    ///         pool for an external pull-based incentives strategy (e.g. Aave's `PullRewardsTransferStrategy`).
    event StakedForExternalIncentives(uint256 amount);

    /// @notice Deploys the Treasury with K613, xK613, Staking, and RewardsDistributor.
    constructor(address k613Token, address xk613Token, address staking_, address rewardsDistributor_) {
        if (
            k613Token == address(0) || xk613Token == address(0) || staking_ == address(0)
                || rewardsDistributor_ == address(0)
        ) {
            revert ZeroAddress();
        }
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(PAUSER_ROLE, msg.sender);
        k613 = IERC20(k613Token);
        xk613 = IERC20(xk613Token);
        staking = Staking(staking_);
        rewardsDistributor = RewardsDistributor(rewardsDistributor_);
    }

    /// @notice Stakes K613 already held by this contract into Staking, leaving the resulting xK613 on Treasury's
    ///         balance. Used to fund an external pull-based incentives strategy (e.g. Aave's
    ///         `PullRewardsTransferStrategy`) without touching `RewardsDistributor.totalDeposits`, so the
    ///         per-share reward math for buyback rewards is NOT diluted by this xK613 supply.
    /// @dev    Treasury is whitelisted to hold xK613 and is a `systemStaker` in `Staking`, so the resulting
    ///         xK613 sits on Treasury's balance and is later pulled by the strategy via `transferFrom`
    ///         (see `approveXk613PullRewards`). This contrasts with `depositRewards`, which forwards xK613
    ///         to `RewardsDistributor` and adds to its reward stream.
    /// @param amount Amount of K613 (already held by Treasury) to stake. Must be non-zero.
    function stakeForExternalIncentives(uint256 amount)
        external
        nonReentrant
        onlyRole(DEFAULT_ADMIN_ROLE)
        whenNotPaused
    {
        if (amount == 0) revert ZeroAmount();
        k613.forceApprove(address(staking), amount);
        staking.stake(amount);
        k613.forceApprove(address(staking), 0);
        emit StakedForExternalIncentives(amount);
    }

    /// @notice Deposits rewards: stakes K613 to get xK613, sends xK613 to RewardsDistributor and notifies. Caller must have approved Treasury for K613.
    /// @param amount Amount of K613 to stake and deposit as xK613 rewards. If zero, no-op.
    function depositRewards(uint256 amount) external nonReentrant onlyRole(DEFAULT_ADMIN_ROLE) whenNotPaused {
        if (amount == 0) return;
        k613.safeTransferFrom(msg.sender, address(this), amount);
        k613.forceApprove(address(staking), amount);
        staking.stake(amount);
        k613.forceApprove(address(staking), 0);
        xk613.safeTransfer(address(rewardsDistributor), amount);
        rewardsDistributor.notifyReward(amount);
    }

    /// @notice Adds or removes a router from the buyback whitelist. Only DEFAULT_ADMIN_ROLE.
    /// @param router Router address to whitelist or remove.
    /// @param allowed True to allow buyback via this router, false to disallow.
    function setRouterWhitelist(address router, bool allowed) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (router == address(0)) revert ZeroAddress();
        bool wasAllowed = routerWhitelist[router];
        routerWhitelist[router] = allowed;
        if (allowed && !wasAllowed) {
            _whitelistedRouters.push(router);
        } else if (!allowed && wasAllowed) {
            _removeRouterFromList(router);
        }
        emit RouterWhitelistUpdated(router, allowed);
    }

    /// @notice Returns the list of all whitelisted router addresses.
    function getWhitelistedRouters() external view returns (address[] memory) {
        return _whitelistedRouters;
    }

    /// @dev Removes a router from _whitelistedRouters by swapping with the last element and popping.
    function _removeRouterFromList(address router) private {
        uint256 len = _whitelistedRouters.length;
        for (uint256 i = 0; i < len; ++i) {
            if (_whitelistedRouters[i] == router) {
                address lastRouter = _whitelistedRouters[len - 1];
                _whitelistedRouters[i] = lastRouter;
                _whitelistedRouters.pop();
                return;
            }
        }
    }

    /// @notice Buys K613 with `tokenIn` through a whitelisted router implementing `IV3SwapRouter.exactInputSingle` (Uniswap SwapRouter02-style).
    /// @param poolFee Uniswap V3 fee tier (e.g. 3000 = 0.3%).
    function buybackV3ExactInputSingle(
        address tokenIn,
        address router,
        uint256 amountIn,
        uint256 minK613Out,
        uint24 poolFee,
        bool distributeRewards
    ) external nonReentrant onlyRole(DEFAULT_ADMIN_ROLE) whenNotPaused returns (uint256 k613Out) {
        if (tokenIn == address(0) || router == address(0)) {
            revert ZeroAddress();
        }
        if (amountIn == 0) {
            revert ZeroAmount();
        }
        if (!routerWhitelist[router]) revert RouterNotWhitelisted();
        if (tokenIn == address(k613)) {
            revert InsufficientOutput();
        }

        uint256 k613Before = k613.balanceOf(address(this));
        uint256 routerReportedOut = 0;
        IERC20(tokenIn).forceApprove(router, amountIn);
        try IV3SwapRouter(router)
            .exactInputSingle(
                IV3SwapRouter.ExactInputSingleParams({
                    tokenIn: tokenIn,
                    tokenOut: address(k613),
                    fee: poolFee,
                    recipient: address(this),
                    amountIn: amountIn,
                    amountOutMinimum: minK613Out,
                    sqrtPriceLimitX96: 0
                })
            ) returns (
            uint256 amountOut
        ) {
            routerReportedOut = amountOut;
        } catch {
            revert BuybackFailed();
        }
        IERC20(tokenIn).forceApprove(router, 0);
        if (routerReportedOut < minK613Out) {
            revert InsufficientOutput();
        }
        k613Out = k613.balanceOf(address(this)) - k613Before;
        if (k613Out < minK613Out) {
            revert InsufficientOutput();
        }
        if (distributeRewards && k613Out > 0) {
            k613.forceApprove(address(staking), k613Out);
            staking.stake(k613Out);
            k613.forceApprove(address(staking), 0);
            xk613.safeTransfer(address(rewardsDistributor), k613Out);
            rewardsDistributor.notifyReward(k613Out);
        }
        emit BuybackExecuted(tokenIn, router, amountIn, k613Out, distributeRewards);
    }

    /// @notice Withdraws any ERC20 token from the Treasury. Only callable by DEFAULT_ADMIN_ROLE.
    /// @param token Token to withdraw.
    /// @param to Recipient address.
    /// @param amount Amount to withdraw.
    function withdraw(address token, address to, uint256 amount) external nonReentrant onlyRole(DEFAULT_ADMIN_ROLE) {
        if (token == address(0) || to == address(0)) {
            revert ZeroAddress();
        }
        if (amount == 0) {
            revert ZeroAmount();
        }
        IERC20(token).safeTransfer(to, amount);
        emit Withdrawn(token, to, amount);
    }

    function approveXk613PullRewards(address spender, uint256 amount)
        external
        nonReentrant
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (spender == address(0)) revert ZeroAddress();
        xk613.forceApprove(spender, amount);
        emit Xk613PullAllowanceSet(spender, amount);
    }

    /// @notice Pauses deposit and buybackV3 operations. Only callable by PAUSER_ROLE.
    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    /// @notice Resumes operations. Only callable by PAUSER_ROLE.
    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }
}

// SPDX-License-Identifier: MIT
// OpenZeppelin Contracts (last updated v5.0.0) (access/AccessControl.sol)

pragma solidity ^0.8.20;

import {IAccessControl} from "./IAccessControl.sol";
import {Context} from "../utils/Context.sol";
import {ERC165} from "../utils/introspection/ERC165.sol";

/**
 * @dev Contract module that allows children to implement role-based access
 * control mechanisms. This is a lightweight version that doesn't allow enumerating role
 * members except through off-chain means by accessing the contract event logs. Some
 * applications may benefit from on-chain enumerability, for those cases see
 * {AccessControlEnumerable}.
 *
 * Roles are referred to by their `bytes32` identifier. These should be exposed
 * in the external API and be unique. The best way to achieve this is by
 * using `public constant` hash digests:
 *
 * ```solidity
 * bytes32 public constant MY_ROLE = keccak256("MY_ROLE");
 * ```
 *
 * Roles can be used to represent a set of permissions. To restrict access to a
 * function call, use {hasRole}:
 *
 * ```solidity
 * function foo() public {
 *     require(hasRole(MY_ROLE, msg.sender));
 *     ...
 * }
 * ```
 *
 * Roles can be granted and revoked dynamically via the {grantRole} and
 * {revokeRole} functions. Each role has an associated admin role, and only
 * accounts that have a role's admin role can call {grantRole} and {revokeRole}.
 *
 * By default, the admin role for all roles is `DEFAULT_ADMIN_ROLE`, which means
 * that only accounts with this role will be able to grant or revoke other
 * roles. More complex role relationships can be created by using
 * {_setRoleAdmin}.
 *
 * WARNING: The `DEFAULT_ADMIN_ROLE` is also its own admin: it has permission to
 * grant and revoke this role. Extra precautions should be taken to secure
 * accounts that have been granted it. We recommend using {AccessControlDefaultAdminRules}
 * to enforce additional security measures for this role.
 */
abstract contract AccessControl is Context, IAccessControl, ERC165 {
    struct RoleData {
        mapping(address account => bool) hasRole;
        bytes32 adminRole;
    }

    mapping(bytes32 role => RoleData) private _roles;

    bytes32 public constant DEFAULT_ADMIN_ROLE = 0x00;

    /**
     * @dev Modifier that checks that an account has a specific role. Reverts
     * with an {AccessControlUnauthorizedAccount} error including the required role.
     */
    modifier onlyRole(bytes32 role) {
        _checkRole(role);
        _;
    }

    /**
     * @dev See {IERC165-supportsInterface}.
     */
    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return interfaceId == type(IAccessControl).interfaceId || super.supportsInterface(interfaceId);
    }

    /**
     * @dev Returns `true` if `account` has been granted `role`.
     */
    function hasRole(bytes32 role, address account) public view virtual returns (bool) {
        return _roles[role].hasRole[account];
    }

    /**
     * @dev Reverts with an {AccessControlUnauthorizedAccount} error if `_msgSender()`
     * is missing `role`. Overriding this function changes the behavior of the {onlyRole} modifier.
     */
    function _checkRole(bytes32 role) internal view virtual {
        _checkRole(role, _msgSender());
    }

    /**
     * @dev Reverts with an {AccessControlUnauthorizedAccount} error if `account`
     * is missing `role`.
     */
    function _checkRole(bytes32 role, address account) internal view virtual {
        if (!hasRole(role, account)) {
            revert AccessControlUnauthorizedAccount(account, role);
        }
    }

    /**
     * @dev Returns the admin role that controls `role`. See {grantRole} and
     * {revokeRole}.
     *
     * To change a role's admin, use {_setRoleAdmin}.
     */
    function getRoleAdmin(bytes32 role) public view virtual returns (bytes32) {
        return _roles[role].adminRole;
    }

    /**
     * @dev Grants `role` to `account`.
     *
     * If `account` had not been already granted `role`, emits a {RoleGranted}
     * event.
     *
     * Requirements:
     *
     * - the caller must have ``role``'s admin role.
     *
     * May emit a {RoleGranted} event.
     */
    function grantRole(bytes32 role, address account) public virtual onlyRole(getRoleAdmin(role)) {
        _grantRole(role, account);
    }

    /**
     * @dev Revokes `role` from `account`.
     *
     * If `account` had been granted `role`, emits a {RoleRevoked} event.
     *
     * Requirements:
     *
     * - the caller must have ``role``'s admin role.
     *
     * May emit a {RoleRevoked} event.
     */
    function revokeRole(bytes32 role, address account) public virtual onlyRole(getRoleAdmin(role)) {
        _revokeRole(role, account);
    }

    /**
     * @dev Revokes `role` from the calling account.
     *
     * Roles are often managed via {grantRole} and {revokeRole}: this function's
     * purpose is to provide a mechanism for accounts to lose their privileges
     * if they are compromised (such as when a trusted device is misplaced).
     *
     * If the calling account had been revoked `role`, emits a {RoleRevoked}
     * event.
     *
     * Requirements:
     *
     * - the caller must be `callerConfirmation`.
     *
     * May emit a {RoleRevoked} event.
     */
    function renounceRole(bytes32 role, address callerConfirmation) public virtual {
        if (callerConfirmation != _msgSender()) {
            revert AccessControlBadConfirmation();
        }

        _revokeRole(role, callerConfirmation);
    }

    /**
     * @dev Sets `adminRole` as ``role``'s admin role.
     *
     * Emits a {RoleAdminChanged} event.
     */
    function _setRoleAdmin(bytes32 role, bytes32 adminRole) internal virtual {
        bytes32 previousAdminRole = getRoleAdmin(role);
        _roles[role].adminRole = adminRole;
        emit RoleAdminChanged(role, previousAdminRole, adminRole);
    }

    /**
     * @dev Attempts to grant `role` to `account` and returns a boolean indicating if `role` was granted.
     *
     * Internal function without access restriction.
     *
     * May emit a {RoleGranted} event.
     */
    function _grantRole(bytes32 role, address account) internal virtual returns (bool) {
        if (!hasRole(role, account)) {
            _roles[role].hasRole[account] = true;
            emit RoleGranted(role, account, _msgSender());
            return true;
        } else {
            return false;
        }
    }

    /**
     * @dev Attempts to revoke `role` to `account` and returns a boolean indicating if `role` was revoked.
     *
     * Internal function without access restriction.
     *
     * May emit a {RoleRevoked} event.
     */
    function _revokeRole(bytes32 role, address account) internal virtual returns (bool) {
        if (hasRole(role, account)) {
            _roles[role].hasRole[account] = false;
            emit RoleRevoked(role, account, _msgSender());
            return true;
        } else {
            return false;
        }
    }
}

// SPDX-License-Identifier: MIT
// OpenZeppelin Contracts (last updated v5.0.0) (utils/Pausable.sol)

pragma solidity ^0.8.20;

import {Context} from "../utils/Context.sol";

/**
 * @dev Contract module which allows children to implement an emergency stop
 * mechanism that can be triggered by an authorized account.
 *
 * This module is used through inheritance. It will make available the
 * modifiers `whenNotPaused` and `whenPaused`, which can be applied to
 * the functions of your contract. Note that they will not be pausable by
 * simply including this module, only once the modifiers are put in place.
 */
abstract contract Pausable is Context {
    bool private _paused;

    /**
     * @dev Emitted when the pause is triggered by `account`.
     */
    event Paused(address account);

    /**
     * @dev Emitted when the pause is lifted by `account`.
     */
    event Unpaused(address account);

    /**
     * @dev The operation failed because the contract is paused.
     */
    error EnforcedPause();

    /**
     * @dev The operation failed because the contract is not paused.
     */
    error ExpectedPause();

    /**
     * @dev Initializes the contract in unpaused state.
     */
    constructor() {
        _paused = false;
    }

    /**
     * @dev Modifier to make a function callable only when the contract is not paused.
     *
     * Requirements:
     *
     * - The contract must not be paused.
     */
    modifier whenNotPaused() {
        _requireNotPaused();
        _;
    }

    /**
     * @dev Modifier to make a function callable only when the contract is paused.
     *
     * Requirements:
     *
     * - The contract must be paused.
     */
    modifier whenPaused() {
        _requirePaused();
        _;
    }

    /**
     * @dev Returns true if the contract is paused, and false otherwise.
     */
    function paused() public view virtual returns (bool) {
        return _paused;
    }

    /**
     * @dev Throws if the contract is paused.
     */
    function _requireNotPaused() internal view virtual {
        if (paused()) {
            revert EnforcedPause();
        }
    }

    /**
     * @dev Throws if the contract is not paused.
     */
    function _requirePaused() internal view virtual {
        if (!paused()) {
            revert ExpectedPause();
        }
    }

    /**
     * @dev Triggers stopped state.
     *
     * Requirements:
     *
     * - The contract must not be paused.
     */
    function _pause() internal virtual whenNotPaused {
        _paused = true;
        emit Paused(_msgSender());
    }

    /**
     * @dev Returns to normal state.
     *
     * Requirements:
     *
     * - The contract must be paused.
     */
    function _unpause() internal virtual whenPaused {
        _paused = false;
        emit Unpaused(_msgSender());
    }
}

// SPDX-License-Identifier: MIT
// OpenZeppelin Contracts (last updated v5.1.0) (utils/ReentrancyGuard.sol)

pragma solidity ^0.8.20;

/**
 * @dev Contract module that helps prevent reentrant calls to a function.
 *
 * Inheriting from `ReentrancyGuard` will make the {nonReentrant} modifier
 * available, which can be applied to functions to make sure there are no nested
 * (reentrant) calls to them.
 *
 * Note that because there is a single `nonReentrant` guard, functions marked as
 * `nonReentrant` may not call one another. This can be worked around by making
 * those functions `private`, and then adding `external` `nonReentrant` entry
 * points to them.
 *
 * TIP: If EIP-1153 (transient storage) is available on the chain you're deploying at,
 * consider using {ReentrancyGuardTransient} instead.
 *
 * TIP: If you would like to learn more about reentrancy and alternative ways
 * to protect against it, check out our blog post
 * https://blog.openzeppelin.com/reentrancy-after-istanbul/[Reentrancy After Istanbul].
 */
abstract contract ReentrancyGuard {
    // Booleans are more expensive than uint256 or any type that takes up a full
    // word because each write operation emits an extra SLOAD to first read the
    // slot's contents, replace the bits taken up by the boolean, and then write
    // back. This is the compiler's defense against contract upgrades and
    // pointer aliasing, and it cannot be disabled.

    // The values being non-zero value makes deployment a bit more expensive,
    // but in exchange the refund on every call to nonReentrant will be lower in
    // amount. Since refunds are capped to a percentage of the total
    // transaction's gas, it is best to keep them low in cases like this one, to
    // increase the likelihood of the full refund coming into effect.
    uint256 private constant NOT_ENTERED = 1;
    uint256 private constant ENTERED = 2;

    uint256 private _status;

    /**
     * @dev Unauthorized reentrant call.
     */
    error ReentrancyGuardReentrantCall();

    constructor() {
        _status = NOT_ENTERED;
    }

    /**
     * @dev Prevents a contract from calling itself, directly or indirectly.
     * Calling a `nonReentrant` function from another `nonReentrant`
     * function is not supported. It is possible to prevent this from happening
     * by making the `nonReentrant` function external, and making it call a
     * `private` function that does the actual work.
     */
    modifier nonReentrant() {
        _nonReentrantBefore();
        _;
        _nonReentrantAfter();
    }

    function _nonReentrantBefore() private {
        // On the first call to nonReentrant, _status will be NOT_ENTERED
        if (_status == ENTERED) {
            revert ReentrancyGuardReentrantCall();
        }

        // Any calls to nonReentrant after this point will fail
        _status = ENTERED;
    }

    function _nonReentrantAfter() private {
        // By storing the original value once again, a refund is triggered (see
        // https://eips.ethereum.org/EIPS/eip-2200)
        _status = NOT_ENTERED;
    }

    /**
     * @dev Returns true if the reentrancy guard is currently set to "entered", which indicates there is a
     * `nonReentrant` function in the call stack.
     */
    function _reentrancyGuardEntered() internal view returns (bool) {
        return _status == ENTERED;
    }
}

// SPDX-License-Identifier: MIT
// OpenZeppelin Contracts (last updated v5.1.0) (token/ERC20/IERC20.sol)

pragma solidity ^0.8.20;

/**
 * @dev Interface of the ERC-20 standard as defined in the ERC.
 */
interface IERC20 {
    /**
     * @dev Emitted when `value` tokens are moved from one account (`from`) to
     * another (`to`).
     *
     * Note that `value` may be zero.
     */
    event Transfer(address indexed from, address indexed to, uint256 value);

    /**
     * @dev Emitted when the allowance of a `spender` for an `owner` is set by
     * a call to {approve}. `value` is the new allowance.
     */
    event Approval(address indexed owner, address indexed spender, uint256 value);

    /**
     * @dev Returns the value of tokens in existence.
     */
    function totalSupply() external view returns (uint256);

    /**
     * @dev Returns the value of tokens owned by `account`.
     */
    function balanceOf(address account) external view returns (uint256);

    /**
     * @dev Moves a `value` amount of tokens from the caller's account to `to`.
     *
     * Returns a boolean value indicating whether the operation succeeded.
     *
     * Emits a {Transfer} event.
     */
    function transfer(address to, uint256 value) external returns (bool);

    /**
     * @dev Returns the remaining number of tokens that `spender` will be
     * allowed to spend on behalf of `owner` through {transferFrom}. This is
     * zero by default.
     *
     * This value changes when {approve} or {transferFrom} are called.
     */
    function allowance(address owner, address spender) external view returns (uint256);

    /**
     * @dev Sets a `value` amount of tokens as the allowance of `spender` over the
     * caller's tokens.
     *
     * Returns a boolean value indicating whether the operation succeeded.
     *
     * IMPORTANT: Beware that changing an allowance with this method brings the risk
     * that someone may use both the old and the new allowance by unfortunate
     * transaction ordering. One possible solution to mitigate this race
     * condition is to first reduce the spender's allowance to 0 and set the
     * desired value afterwards:
     * https://github.com/ethereum/EIPs/issues/20#issuecomment-263524729
     *
     * Emits an {Approval} event.
     */
    function approve(address spender, uint256 value) external returns (bool);

    /**
     * @dev Moves a `value` amount of tokens from `from` to `to` using the
     * allowance mechanism. `value` is then deducted from the caller's
     * allowance.
     *
     * Returns a boolean value indicating whether the operation succeeded.
     *
     * Emits a {Transfer} event.
     */
    function transferFrom(address from, address to, uint256 value) external returns (bool);
}

// SPDX-License-Identifier: MIT
// OpenZeppelin Contracts (last updated v5.2.0) (token/ERC20/utils/SafeERC20.sol)

pragma solidity ^0.8.20;

import {IERC20} from "../IERC20.sol";
import {IERC1363} from "../../../interfaces/IERC1363.sol";

/**
 * @title SafeERC20
 * @dev Wrappers around ERC-20 operations that throw on failure (when the token
 * contract returns false). Tokens that return no value (and instead revert or
 * throw on failure) are also supported, non-reverting calls are assumed to be
 * successful.
 * To use this library you can add a `using SafeERC20 for IERC20;` statement to your contract,
 * which allows you to call the safe operations as `token.safeTransfer(...)`, etc.
 */
library SafeERC20 {
    /**
     * @dev An operation with an ERC-20 token failed.
     */
    error SafeERC20FailedOperation(address token);

    /**
     * @dev Indicates a failed `decreaseAllowance` request.
     */
    error SafeERC20FailedDecreaseAllowance(address spender, uint256 currentAllowance, uint256 requestedDecrease);

    /**
     * @dev Transfer `value` amount of `token` from the calling contract to `to`. If `token` returns no value,
     * non-reverting calls are assumed to be successful.
     */
    function safeTransfer(IERC20 token, address to, uint256 value) internal {
        _callOptionalReturn(token, abi.encodeCall(token.transfer, (to, value)));
    }

    /**
     * @dev Transfer `value` amount of `token` from `from` to `to`, spending the approval given by `from` to the
     * calling contract. If `token` returns no value, non-reverting calls are assumed to be successful.
     */
    function safeTransferFrom(IERC20 token, address from, address to, uint256 value) internal {
        _callOptionalReturn(token, abi.encodeCall(token.transferFrom, (from, to, value)));
    }

    /**
     * @dev Increase the calling contract's allowance toward `spender` by `value`. If `token` returns no value,
     * non-reverting calls are assumed to be successful.
     *
     * IMPORTANT: If the token implements ERC-7674 (ERC-20 with temporary allowance), and if the "client"
     * smart contract uses ERC-7674 to set temporary allowances, then the "client" smart contract should avoid using
     * this function. Performing a {safeIncreaseAllowance} or {safeDecreaseAllowance} operation on a token contract
     * that has a non-zero temporary allowance (for that particular owner-spender) will result in unexpected behavior.
     */
    function safeIncreaseAllowance(IERC20 token, address spender, uint256 value) internal {
        uint256 oldAllowance = token.allowance(address(this), spender);
        forceApprove(token, spender, oldAllowance + value);
    }

    /**
     * @dev Decrease the calling contract's allowance toward `spender` by `requestedDecrease`. If `token` returns no
     * value, non-reverting calls are assumed to be successful.
     *
     * IMPORTANT: If the token implements ERC-7674 (ERC-20 with temporary allowance), and if the "client"
     * smart contract uses ERC-7674 to set temporary allowances, then the "client" smart contract should avoid using
     * this function. Performing a {safeIncreaseAllowance} or {safeDecreaseAllowance} operation on a token contract
     * that has a non-zero temporary allowance (for that particular owner-spender) will result in unexpected behavior.
     */
    function safeDecreaseAllowance(IERC20 token, address spender, uint256 requestedDecrease) internal {
        unchecked {
            uint256 currentAllowance = token.allowance(address(this), spender);
            if (currentAllowance < requestedDecrease) {
                revert SafeERC20FailedDecreaseAllowance(spender, currentAllowance, requestedDecrease);
            }
            forceApprove(token, spender, currentAllowance - requestedDecrease);
        }
    }

    /**
     * @dev Set the calling contract's allowance toward `spender` to `value`. If `token` returns no value,
     * non-reverting calls are assumed to be successful. Meant to be used with tokens that require the approval
     * to be set to zero before setting it to a non-zero value, such as USDT.
     *
     * NOTE: If the token implements ERC-7674, this function will not modify any temporary allowance. This function
     * only sets the "standard" allowance. Any temporary allowance will remain active, in addition to the value being
     * set here.
     */
    function forceApprove(IERC20 token, address spender, uint256 value) internal {
        bytes memory approvalCall = abi.encodeCall(token.approve, (spender, value));

        if (!_callOptionalReturnBool(token, approvalCall)) {
            _callOptionalReturn(token, abi.encodeCall(token.approve, (spender, 0)));
            _callOptionalReturn(token, approvalCall);
        }
    }

    /**
     * @dev Performs an {ERC1363} transferAndCall, with a fallback to the simple {ERC20} transfer if the target has no
     * code. This can be used to implement an {ERC721}-like safe transfer that rely on {ERC1363} checks when
     * targeting contracts.
     *
     * Reverts if the returned value is other than `true`.
     */
    function transferAndCallRelaxed(IERC1363 token, address to, uint256 value, bytes memory data) internal {
        if (to.code.length == 0) {
            safeTransfer(token, to, value);
        } else if (!token.transferAndCall(to, value, data)) {
            revert SafeERC20FailedOperation(address(token));
        }
    }

    /**
     * @dev Performs an {ERC1363} transferFromAndCall, with a fallback to the simple {ERC20} transferFrom if the target
     * has no code. This can be used to implement an {ERC721}-like safe transfer that rely on {ERC1363} checks when
     * targeting contracts.
     *
     * Reverts if the returned value is other than `true`.
     */
    function transferFromAndCallRelaxed(
        IERC1363 token,
        address from,
        address to,
        uint256 value,
        bytes memory data
    ) internal {
        if (to.code.length == 0) {
            safeTransferFrom(token, from, to, value);
        } else if (!token.transferFromAndCall(from, to, value, data)) {
            revert SafeERC20FailedOperation(address(token));
        }
    }

    /**
     * @dev Performs an {ERC1363} approveAndCall, with a fallback to the simple {ERC20} approve if the target has no
     * code. This can be used to implement an {ERC721}-like safe transfer that rely on {ERC1363} checks when
     * targeting contracts.
     *
     * NOTE: When the recipient address (`to`) has no code (i.e. is an EOA), this function behaves as {forceApprove}.
     * Opposedly, when the recipient address (`to`) has code, this function only attempts to call {ERC1363-approveAndCall}
     * once without retrying, and relies on the returned value to be true.
     *
     * Reverts if the returned value is other than `true`.
     */
    function approveAndCallRelaxed(IERC1363 token, address to, uint256 value, bytes memory data) internal {
        if (to.code.length == 0) {
            forceApprove(token, to, value);
        } else if (!token.approveAndCall(to, value, data)) {
            revert SafeERC20FailedOperation(address(token));
        }
    }

    /**
     * @dev Imitates a Solidity high-level call (i.e. a regular function call to a contract), relaxing the requirement
     * on the return value: the return value is optional (but if data is returned, it must not be false).
     * @param token The token targeted by the call.
     * @param data The call data (encoded using abi.encode or one of its variants).
     *
     * This is a variant of {_callOptionalReturnBool} that reverts if call fails to meet the requirements.
     */
    function _callOptionalReturn(IERC20 token, bytes memory data) private {
        uint256 returnSize;
        uint256 returnValue;
        assembly ("memory-safe") {
            let success := call(gas(), token, 0, add(data, 0x20), mload(data), 0, 0x20)
            // bubble errors
            if iszero(success) {
                let ptr := mload(0x40)
                returndatacopy(ptr, 0, returndatasize())
                revert(ptr, returndatasize())
            }
            returnSize := returndatasize()
            returnValue := mload(0)
        }

        if (returnSize == 0 ? address(token).code.length == 0 : returnValue != 1) {
            revert SafeERC20FailedOperation(address(token));
        }
    }

    /**
     * @dev Imitates a Solidity high-level call (i.e. a regular function call to a contract), relaxing the requirement
     * on the return value: the return value is optional (but if data is returned, it must not be false).
     * @param token The token targeted by the call.
     * @param data The call data (encoded using abi.encode or one of its variants).
     *
     * This is a variant of {_callOptionalReturn} that silently catches all reverts and returns a bool instead.
     */
    function _callOptionalReturnBool(IERC20 token, bytes memory data) private returns (bool) {
        bool success;
        uint256 returnSize;
        uint256 returnValue;
        assembly ("memory-safe") {
            success := call(gas(), token, 0, add(data, 0x20), mload(data), 0, 0x20)
            returnSize := returndatasize()
            returnValue := mload(0)
        }
        return success && (returnSize == 0 ? address(token).code.length > 0 : returnValue == 1);
    }
}

// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.7.5;
pragma abicoder v2;

import '@uniswap/v3-core/contracts/interfaces/callback/IUniswapV3SwapCallback.sol';

/// @title Router token swapping functionality
/// @notice Functions for swapping tokens via Uniswap V3
interface IV3SwapRouter is IUniswapV3SwapCallback {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    /// @notice Swaps `amountIn` of one token for as much as possible of another token
    /// @dev Setting `amountIn` to 0 will cause the contract to look up its own balance,
    /// and swap the entire amount, enabling contracts to send tokens before calling this function.
    /// @param params The parameters necessary for the swap, encoded as `ExactInputSingleParams` in calldata
    /// @return amountOut The amount of the received token
    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);

    struct ExactInputParams {
        bytes path;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
    }

    /// @notice Swaps `amountIn` of one token for as much as possible of another along the specified path
    /// @dev Setting `amountIn` to 0 will cause the contract to look up its own balance,
    /// and swap the entire amount, enabling contracts to send tokens before calling this function.
    /// @param params The parameters necessary for the multi-hop swap, encoded as `ExactInputParams` in calldata
    /// @return amountOut The amount of the received token
    function exactInput(ExactInputParams calldata params) external payable returns (uint256 amountOut);

    struct ExactOutputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountOut;
        uint256 amountInMaximum;
        uint160 sqrtPriceLimitX96;
    }

    /// @notice Swaps as little as possible of one token for `amountOut` of another token
    /// that may remain in the router after the swap.
    /// @param params The parameters necessary for the swap, encoded as `ExactOutputSingleParams` in calldata
    /// @return amountIn The amount of the input token
    function exactOutputSingle(ExactOutputSingleParams calldata params) external payable returns (uint256 amountIn);

    struct ExactOutputParams {
        bytes path;
        address recipient;
        uint256 amountOut;
        uint256 amountInMaximum;
    }

    /// @notice Swaps as little as possible of one token for `amountOut` of another along the specified path (reversed)
    /// that may remain in the router after the swap.
    /// @param params The parameters necessary for the multi-hop swap, encoded as `ExactOutputParams` in calldata
    /// @return amountIn The amount of the input token
    function exactOutput(ExactOutputParams calldata params) external payable returns (uint256 amountIn);
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {AccessControl} from "openzeppelin-contracts/contracts/access/AccessControl.sol";
import {Pausable} from "openzeppelin-contracts/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

interface IStaking {
    function stake(uint256 amount) external;
    function exitQueueLength(address user) external view returns (uint256);
}

/// @title RewardsDistributor
/// @notice Users deposit xK613 (stakingToken) to earn rewards in xK613 (rewardToken). Claim anytime. Penalties from instant exit are staked to get xK613, then distributed. Rewards can be converted to K613 via Staking instant exit (50% penalty)
contract RewardsDistributor is AccessControl, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    /// @notice Thrown when a zero address is provided
    error ZeroAddress();
    /// @notice Thrown when a zero amount is provided
    error ZeroAmount();
    /// @notice Thrown when a user has no rewards to claim
    error NoRewards();
    /// @notice Thrown when a user has insufficient balance
    error InsufficientBalance();
    /// @notice Thrown when an invalid epoch duration is provided
    error InvalidEpochDuration();
    /// @notice Thrown when a minimum initial deposit is not met
    error MinimumInitialDeposit();
    /// @notice Thrown when a minimum notify amount is not met
    error MinimumNotify();
    /// @notice Thrown when advanceEpoch() is called before the current epoch has ended
    error EpochNotReady();
    /// @notice Thrown when claim() is called while the user has an active exit vesting in Staking
    error ExitVestingActive();

    /// @notice Staking token (xK613): users deposit this to earn rewards
    IERC20 public immutable stakingToken;
    /// @notice Reward token (xK613): rewards are paid out in xK613. Same token as stakingToken
    IERC20 public immutable rewardToken;
    /// @notice K613 token; used to stake penalty K613 in Staking to get xK613 for distribution
    IERC20 public immutable k613;

    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant REWARDS_NOTIFIER_ROLE = keccak256("REWARDS_NOTIFIER_ROLE");

    /// @notice Scale for accRewardPerShare and reward math
    uint256 private constant PRECISION = 1e18;
    /// @notice Minimum penalty flush amount to avoid dust rounding
    uint256 public constant MIN_PENALTY_FLUSH = 1e18;
    /// @notice Minimum first deposit to prevent first-depositor griefing
    uint256 public constant MIN_INITIAL_DEPOSIT = 1e12;
    /// @notice Minimum amount per notifyReward to avoid precision loss and notify spam
    uint256 public constant MIN_NOTIFY = 1e12;

    /// @notice Epoch duration in seconds. Penalties flush at epoch boundary even if below threshold
    uint256 public immutable epochDuration;
    /// @notice Timestamp when penalties were last flushed at epoch boundary
    uint256 public lastEpochFlushAt;

    /// @notice Global accumulated rewards per share, scaled by 1e18
    uint256 public accRewardPerShare;
    /// @notice Rewards notified but not yet distributed (when totalDeposits was 0)
    uint256 public pendingRewards;
    /// @notice Penalties from instant exit; flushed when >= MIN_PENALTY_FLUSH to avoid dust rounding
    uint256 public pendingPenalties;
    /// @notice Total stakingToken (xK613) deposited by all users
    uint256 public totalDeposits;

    /// @notice The amount of stakingToken (xK613) held by a user
    mapping(address => uint256) public balanceOf;
    /// @notice The amount of rewards owed to a user
    mapping(address => uint256) public userRewardDebt;
    /// @notice The amount of rewards pending for a user
    mapping(address => uint256) public userPendingRewards;

    /// @notice Staking contract; receives REWARDS_NOTIFIER_ROLE for penalty rewards
    address public staking;

    /// @notice Emitted when a user claims rewards
    event Claimed(address indexed account, uint256 amount);
    /// @notice Emitted when rewards are notified
    event RewardNotified(uint256 amount);
    /// @notice Emitted when rewards are queued because totalDeposits is zero
    event RewardQueued(uint256 amount);
    /// @notice Emitted when the staking contract is updated
    event StakingUpdated(address indexed staking);
    /// @notice Emitted when a user deposits stakingToken (xK613)
    event Deposited(address indexed account, uint256 amount);
    /// @notice Emitted when a user withdraws stakingToken (xK613)
    event Withdrawn(address indexed account, uint256 amount);
    /// @notice Emitted when penalties are added
    event PenaltyAdded(uint256 amount);
    /// @notice Emitted when the epoch is advanced
    event EpochAdvanced(uint256 timestamp);

    constructor(address stakingToken_, address rewardToken_, address k613_, uint256 epochDuration_) {
        if (stakingToken_ == address(0) || rewardToken_ == address(0) || k613_ == address(0)) revert ZeroAddress();
        if (epochDuration_ == 0) revert InvalidEpochDuration();
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(PAUSER_ROLE, msg.sender);
        stakingToken = IERC20(stakingToken_);
        rewardToken = IERC20(rewardToken_);
        k613 = IERC20(k613_);
        epochDuration = epochDuration_;
        lastEpochFlushAt = block.timestamp;
    }

    /// @notice Sets the staking contract. Grants REWARDS_NOTIFIER_ROLE for penalty rewards. Pass address(0) to disable.
    function setStaking(address staking_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (address(staking) != address(0)) {
            _revokeRole(REWARDS_NOTIFIER_ROLE, address(staking));
        }
        staking = staking_;
        if (staking_ != address(0)) {
            _grantRole(REWARDS_NOTIFIER_ROLE, staking_);
        }
        emit StakingUpdated(staking_);
    }

    /// @notice Deposits xK613 to earn rewards. Caller must approve this contract first
    function deposit(uint256 amount) external nonReentrant whenNotPaused {
        if (amount == 0) revert ZeroAmount();
        if (totalDeposits == 0 && amount < MIN_INITIAL_DEPOSIT) revert MinimumInitialDeposit();
        _updateUser(msg.sender);
        balanceOf[msg.sender] += amount;
        totalDeposits += amount;
        userRewardDebt[msg.sender] = (balanceOf[msg.sender] * accRewardPerShare) / PRECISION;
        stakingToken.safeTransferFrom(msg.sender, address(this), amount);
        emit Deposited(msg.sender, amount);
    }

    /// @notice Withdraws xK613. Must withdraw from RD before initiating exit in Staking.
    function withdraw(uint256 amount) external nonReentrant whenNotPaused {
        if (amount == 0) revert ZeroAmount();
        if (balanceOf[msg.sender] < amount) revert InsufficientBalance();
        _updateUser(msg.sender);
        balanceOf[msg.sender] -= amount;
        totalDeposits -= amount;
        userRewardDebt[msg.sender] = (balanceOf[msg.sender] * accRewardPerShare) / PRECISION;
        stakingToken.safeTransfer(msg.sender, amount);
        emit Withdrawn(msg.sender, amount);
    }

    /// @notice Claims accumulated rewards. Reverts while caller has an active exit vesting in Staking (withdraw from RD first, then exit; no claim during vesting).
    function claim() external nonReentrant whenNotPaused {
        // aderyn-ignore-next-line(reentrancy-state-change)
        if (address(staking) != address(0) && IStaking(staking).exitQueueLength(msg.sender) > 0) {
            revert ExitVestingActive();
        }
        _updateUser(msg.sender);
        uint256 reward = userPendingRewards[msg.sender];
        if (reward == 0) revert NoRewards();

        userPendingRewards[msg.sender] = 0;
        _stakeHeldK613();
        rewardToken.safeTransfer(msg.sender, reward);
        emit Claimed(msg.sender, reward);
    }

    /// @notice Notifies new rewards in xK613. Caller must have transferred rewardToken (xK613) to this contract first.
    function notifyReward(uint256 amount) external nonReentrant onlyRole(REWARDS_NOTIFIER_ROLE) whenNotPaused {
        if (amount == 0) revert ZeroAmount();
        if (amount < MIN_NOTIFY) revert MinimumNotify();
        if (totalDeposits == 0) {
            pendingRewards += amount;
            emit RewardQueued(amount);
            return;
        }
        accRewardPerShare += (amount * PRECISION) / totalDeposits;
        emit RewardNotified(amount);
    }

    /// @notice Receives K613 penalty from Staking; adds to pending penalties. K613 is staked to xK613 on next claim/advanceEpoch to avoid reentrancy (Staking calls this).
    function addPendingPenalty(uint256 amount) external nonReentrant onlyRole(REWARDS_NOTIFIER_ROLE) whenNotPaused {
        if (amount == 0) return;
        pendingPenalties += amount;
        emit PenaltyAdded(amount);
    }

    /// @notice Stakes any K613 held by this contract to get xK613. Non-fatal if Staking is paused.
    function _stakeHeldK613() internal {
        if (address(staking) == address(0)) return;
        uint256 balance = k613.balanceOf(address(this));
        if (balance < 1) return;
        k613.forceApprove(address(staking), balance);
        try IStaking(staking).stake(balance) {}
        catch {
            k613.forceApprove(address(staking), 0);
            return;
        }
        k613.forceApprove(address(staking), 0);
    }

    /// @notice Pauses reward-related state-changing operations.
    /// @dev Functions guarded by `whenNotPaused` will revert while the contract is paused.
    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    /// @notice Unpauses the contract, re-enabling state-changing operations.
    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    /// @notice Advances the epoch: flushes pending rewards/penalties. Always advances the epoch marker.
    function advanceEpoch() external nonReentrant whenNotPaused {
        _stakeHeldK613();
        if (block.timestamp < lastEpochFlushAt + epochDuration) revert EpochNotReady();
        if (totalDeposits > 0) _distributePending();
        lastEpochFlushAt = block.timestamp;
        emit EpochAdvanced(block.timestamp);
    }

    /// @notice Returns the timestamp when the current epoch ends (or 0 if no epochs).
    function nextEpochAt() external view returns (uint256) {
        return lastEpochFlushAt + epochDuration;
    }

    function _updateUser(address user) internal {
        _distributePending();
        uint256 bal = balanceOf[user];
        uint256 accumulated = (bal * accRewardPerShare) / PRECISION;
        if (accumulated > userRewardDebt[user]) {
            userPendingRewards[user] += (accumulated - userRewardDebt[user]);
        }
        userRewardDebt[user] = accumulated;
    }

    function _distributePending() internal {
        if (totalDeposits == 0) return;
        if (pendingRewards > 0) {
            uint256 amount = pendingRewards;
            pendingRewards = 0;
            accRewardPerShare += (amount * PRECISION) / totalDeposits;
            emit RewardNotified(amount);
        }
        bool epochPassed = block.timestamp >= lastEpochFlushAt + epochDuration;
        bool shouldFlushPenalties = pendingPenalties >= MIN_PENALTY_FLUSH || (pendingPenalties > 0 && epochPassed);
        if (shouldFlushPenalties) {
            uint256 amount = pendingPenalties;
            pendingPenalties = 0;
            accRewardPerShare += (amount * PRECISION) / totalDeposits;
            emit RewardNotified(amount);
        }
    }

    /// @notice Returns pending rewards for an account.
    function pendingRewardsOf(address account) external view returns (uint256) {
        if (totalDeposits == 0) return userPendingRewards[account];
        uint256 accReward = accRewardPerShare;
        if (pendingRewards > 0) {
            accReward += (pendingRewards * PRECISION) / totalDeposits;
        }
        bool epochPassed = block.timestamp >= lastEpochFlushAt + epochDuration;
        bool wouldFlushPenalties = pendingPenalties >= MIN_PENALTY_FLUSH || (pendingPenalties > 0 && epochPassed);
        if (wouldFlushPenalties) {
            accReward += (pendingPenalties * PRECISION) / totalDeposits;
        }
        uint256 bal = balanceOf[account];
        uint256 accumulated = (bal * accReward) / PRECISION;
        uint256 pending = accumulated > userRewardDebt[account] ? accumulated - userRewardDebt[account] : 0;
        return userPendingRewards[account] + pending;
    }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {AccessControl} from "openzeppelin-contracts/contracts/access/AccessControl.sol";
import {Pausable} from "openzeppelin-contracts/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

import {xK613} from "../token/xK613.sol";
import {RewardsDistributor} from "./RewardsDistributor.sol";

/**
 * @title K613 Staking
 * @author K613
 *
 * @notice
 * Shadow (xSHADOW)-inspired staking contract implementing a 1:1 conversion
 * between K613 and xK613 with an explicit exit queue and optional instant exit
 * penalty mechanism.
 *
 * @dev
 * DESIGN OVERVIEW
 * ---------------
 * This contract intentionally borrows the economic pattern of Shadow's xToken
 * staking model (receipt token + exit mechanics), while significantly reducing
 * system complexity and attack surface.
 *
 * Core principles:
 * - xK613 is a passive receipt token minted 1:1 on stake and burned on exit.
 * - No rebasing, governance, voting, or vesting logic is included.
 * - Rewards distribution is fully decoupled and handled externally via
 *   RewardsDistributor.
 *
 * SHADOW-INSPIRED ELEMENTS
 * -----------------------
 * - Receipt-token based staking (K613 → xK613).
 * - Exit delay enforced via an exit queue.
 * - Optional early exit with penalty (basis-points based).
 *
 * INTENTIONAL DIFFERENCES FROM SHADOW
 * ----------------------------------
 * - No automatic reward accrual or rebasing.
 * - No epoch-based accounting.
 * - No governance or voting power coupling.
 * - Exit requests escrow xK613 inside this contract, ensuring strict
 *   accounting and preventing double exits.
 *
 * SECURITY RATIONALE
 * ------------------
 * - Explicit state tracking via UserState prevents balance desynchronization.
 * - xK613 is transferred to this contract during exit requests and burned on exit,
 *   eliminating reliance on user balances at execution time.
 * - All external token transfers use SafeERC20.
 * - ReentrancyGuard is applied to all state-mutating user flows.
 *
 * ECONOMIC NOTES
 * --------------
 * - Instant exit penalties (if enabled) are transferred as K613 to the
 *   RewardsDistributor, increasing future reward weight for remaining stakers.
 * - Underlying K613 principal is never implicitly redistributed. xK613 is strictly 1:1 backed.
 *
 * This design preserves proven economic incentives from Shadow while favoring
 * auditability, explicit user intent, and minimal cross-contract coupling.
 */
///@author a.r.c.i.t.e.c.t
contract Staking is AccessControl, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public maxExitRequests;
    uint256 public constant MAX_BASIS_POINTS = 10_000;

    /// @notice Thrown when a zero address is passed where a non-zero address is required.
    error ZeroAddress();
    /// @notice Thrown when a zero amount is passed where a positive amount is required.
    error ZeroAmount();
    /// @notice Thrown when attempting to exit before the lock duration has passed.
    error Locked();
    /// @notice Thrown when attempting an instant exit after the lock duration has already passed.
    error Unlocked();
    /// @notice Thrown when the instant exit penalty basis points exceed MAX_BASIS_POINTS.
    error InvalidBps();
    /// @notice Thrown when an instant exit with a non-zero penalty is attempted without a rewards distributor set.
    error RewardsDistributorNotSet();
    /// @notice Thrown when the caller does not hold enough xK613 to cover the requested exit amount.
    error InsufficientxK613();
    /// @notice Thrown when there is no remaining staked amount available to initiate a new exit request.
    error NothingToInitiate();
    /// @notice Thrown when an invalid exit queue index is provided.
    error InvalidExitIndex();
    /// @notice Thrown when the user's exit queue has reached MAX_EXIT_REQUESTS.
    error ExitQueueFull();
    /// @notice Thrown when the requested exit amount exceeds the user’s staked balance.
    error AmountExceedsStake();
    /// @notice Thrown when lockDuration is zero.
    error InvalidLockDuration();
    /// @notice Thrown when maxExitRequests is zero.
    error InvalidMaxExitRequests();
    /// @notice Thrown when there is not enough system backing to redeem rewards.
    error InsufficientSystemBacking();
    /// @notice Thrown when attempting to redeem more xK613 than the caller's reward portion.
    error ExceedsRewardPortion();
    /// @notice Thrown when attempting to add a system staker that is already registered.
    error AlreadySystemStaker();
    /// @notice Thrown when attempting to remove a system staker that is not registered.
    error NotSystemStaker();

    /// @notice Exit request struct
    struct ExitRequest {
        uint256 amount;
        uint256 exitInitiatedAt;
    }

    /// @notice User state struct
    struct UserState {
        uint256 amount;
        ExitRequest[] exitQueue;
    }

    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    /// @notice Underlying token being staked
    IERC20 public immutable k613;
    /// @notice xK613 token minted on stake and burned on exit
    xK613 public immutable xk613;

    /// @notice Lock duration for standard exits
    uint256 public immutable lockDuration;
    /// @notice Penalty, in basis points, applied on instant exits before `lockDuration`
    uint256 public instantExitPenaltyBps;

    /// @notice Rewards distributor responsible for external reward accounting
    RewardsDistributor public rewardsDistributor;
    mapping(address => UserState) private _userState;
    /// @notice Total K613 backing active positions (staked minus exited)
    uint256 private _totalBacking;
    /// @notice System staker addresses (RD, Treasury) whose positions back reward xK613
    address[] private _systemStakers;
    /// @notice Whether an address is a registered system staker
    mapping(address => bool) public isSystemStaker;

    /// @notice Emitted when a user stakes K613
    event Staked(address indexed account, uint256 amount);
    /// @notice Emitted when a user initiates an exit request
    event ExitInitiated(address indexed account, uint256 index, uint256 amount, uint256 exitInitiatedAt);
    /// @notice Emitted when a user cancels an exit request
    event ExitCancelled(address indexed account, uint256 index);
    /// @notice Emitted when a user exits after the lock period
    event Exited(address indexed account, uint256 index, uint256 amount);
    /// @notice Emitted when a user performs an instant exit
    event InstantExit(address indexed account, uint256 index, uint256 amount, uint256 penalty);
    /// @notice Emitted when rewards distributor is updated
    event RewardsDistributorUpdated(address indexed distributor);
    /// @notice Emitted when instantExitPenaltyBps is updated
    event InstantExitPenaltyBpsUpdated(uint256 oldBps, uint256 newBps);
    event MaxExitRequestsUpdated(uint256 oldValue, uint256 newValue);
    /// @notice Emitted when a user redeems reward xK613 for K613
    event RewardsRedeemed(address indexed account, uint256 amount);
    /// @notice Emitted when a system staker is added or removed
    event SystemStakerUpdated(address indexed account, bool added);

    /// @notice Initializes the staking contract.
    /// @param k613Token Address of the K613 token to be staked.
    /// @param xk613Token Address of the xK613 token to be minted/burned on stake/exit.
    /// @param lockDuration_ Lock duration, in seconds, for standard exits.
    /// @param instantExitPenaltyBps_ Penalty in basis points for instant exits.
    constructor(address k613Token, address xk613Token, uint256 lockDuration_, uint256 instantExitPenaltyBps_) {
        if (k613Token == address(0) || xk613Token == address(0)) revert ZeroAddress();
        if (lockDuration_ == 0) revert InvalidLockDuration();
        if (instantExitPenaltyBps_ == 0 || instantExitPenaltyBps_ > MAX_BASIS_POINTS) revert InvalidBps();
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(PAUSER_ROLE, msg.sender);
        k613 = IERC20(k613Token);
        xk613 = xK613(xk613Token);
        lockDuration = lockDuration_;
        instantExitPenaltyBps = instantExitPenaltyBps_;
        maxExitRequests = 100;
    }

    /// @notice Sets the rewards distributor contract. Pass address(0) to disable; instant exit with penalty will revert until set.
    /// @param distributor Address of the rewards distributor.
    function setRewardsDistributor(address distributor) external onlyRole(DEFAULT_ADMIN_ROLE) {
        rewardsDistributor = RewardsDistributor(distributor);
        emit RewardsDistributorUpdated(distributor);
    }

    function MAX_EXIT_REQUESTS() external view returns (uint256) {
        return maxExitRequests;
    }

    /// @notice Returns the total deposited amount and exit queue for a user.
    /// @param user Address of the user.
    /// @return amount Total staked K613 amount for the user.
    /// @return exitQueue Array of exit requests for the user.
    function deposits(address user) external view returns (uint256 amount, ExitRequest[] memory exitQueue) {
        UserState storage s = _userState[user];
        amount = s.amount;
        exitQueue = s.exitQueue;
    }

    /// @notice Returns the length of the exit queue for a user.
    /// @param user Address of the user.
    /// @return Length of the exit queue.
    function exitQueueLength(address user) external view returns (uint256) {
        return _userState[user].exitQueue.length;
    }

    /// @notice Returns data for a specific exit request in a user's queue.
    /// @param user Address of the user.
    /// @param index Index of the exit request.
    /// @return amount Amount requested to exit.
    /// @return exitInitiatedAt Timestamp when the exit was initiated.
    function exitRequestAt(address user, uint256 index)
        external
        view
        returns (uint256 amount, uint256 exitInitiatedAt)
    {
        ExitRequest storage r = _userState[user].exitQueue[index];
        return (r.amount, r.exitInitiatedAt);
    }

    /// @notice Returns total K613 backing active positions (staked minus exited). For invariant: xK613.totalSupply() == totalBacking().
    function totalBacking() external view returns (uint256) {
        return _totalBacking;
    }

    /// @notice Computes the sum of all amounts pending exit for a user.
    /// @param user Address of the user.
    /// @return sum Total amount pending exit across the user's queue.
    function _exitPendingSum(address user) internal view returns (uint256 sum) {
        ExitRequest[] storage q = _userState[user].exitQueue;
        uint256 len = q.length;
        for (uint256 i = 0; i < len; ++i) {
            sum += q[i].amount;
        }
    }

    /// @notice Converts K613 to xK613 1:1 and mints to caller
    /// @param amount Amount of K613 to convert.
    function stake(uint256 amount) external nonReentrant whenNotPaused {
        if (amount == 0) revert ZeroAmount();

        UserState storage s = _userState[msg.sender];
        s.amount += amount;
        _totalBacking += amount;

        k613.safeTransferFrom(msg.sender, address(this), amount);
        xk613.mint(msg.sender, amount);

        emit Staked(msg.sender, amount);
    }

    /// @notice Initiates exit: pulls xK613 from caller and adds request to queue.
    /// @dev Caller must approve Staking for xK613. At most `maxExitRequests` per user.
    /// @param amount Amount of xK613 to schedule for exit.
    function initiateExit(uint256 amount) external nonReentrant whenNotPaused {
        if (amount == 0) revert ZeroAmount();

        UserState storage s = _userState[msg.sender];
        uint256 inQueue = _exitPendingSum(msg.sender);
        if (s.amount <= inQueue) revert NothingToInitiate();
        if (amount > s.amount - inQueue) revert AmountExceedsStake();
        // aderyn-ignore-next-line(reentrancy-state-change)
        if (xk613.balanceOf(msg.sender) < amount) revert InsufficientxK613();
        if (s.exitQueue.length >= maxExitRequests) revert ExitQueueFull();
        s.exitQueue.push(ExitRequest({amount: amount, exitInitiatedAt: block.timestamp}));
        IERC20(address(xk613)).safeTransferFrom(msg.sender, address(this), amount);

        emit ExitInitiated(msg.sender, s.exitQueue.length - 1, amount, block.timestamp);
    }

    /// @notice Cancels an exit request and returns xK613 to caller.
    /// @param index Index of the exit request in the caller's queue.
    function cancelExit(uint256 index) external nonReentrant whenNotPaused {
        UserState storage s = _userState[msg.sender];
        if (index >= s.exitQueue.length) revert InvalidExitIndex();

        uint256 amount = s.exitQueue[index].amount;
        _removeExitRequest(msg.sender, index);
        IERC20(address(xk613)).safeTransfer(msg.sender, amount);

        emit ExitCancelled(msg.sender, index);
    }

    /// @notice Executes an exit after the lock period: burns held xK613 and transfers K613 to caller.
    /// @param index Index of the exit request in the caller's queue.
    function exit(uint256 index) external nonReentrant whenNotPaused {
        UserState storage s = _userState[msg.sender];
        if (index >= s.exitQueue.length) revert InvalidExitIndex();

        ExitRequest storage req = s.exitQueue[index];
        if (block.timestamp < req.exitInitiatedAt + lockDuration) revert Locked();

        uint256 amount = req.amount;
        _removeExitRequest(msg.sender, index);
        s.amount -= amount;
        _totalBacking -= amount;

        xk613.burnFrom(address(this), amount);
        k613.safeTransfer(msg.sender, amount);

        emit Exited(msg.sender, index, amount);
    }

    /// @notice Instant exit before lock period; penalty goes to RewardsDistributor if set.
    /// @dev Requires rewardsDistributor when penalty > 0.
    /// @param index Index of the exit request in the caller's queue.
    function instantExit(uint256 index) external nonReentrant whenNotPaused {
        UserState storage s = _userState[msg.sender];
        if (index >= s.exitQueue.length) revert InvalidExitIndex();

        ExitRequest storage req = s.exitQueue[index];
        if (block.timestamp >= req.exitInitiatedAt + lockDuration) revert Unlocked();

        uint256 amount = req.amount;
        uint256 penalty = (amount * instantExitPenaltyBps + MAX_BASIS_POINTS - 1) / MAX_BASIS_POINTS;
        uint256 payout = amount - penalty;

        if (penalty > 0 && address(rewardsDistributor) == address(0)) revert RewardsDistributorNotSet();

        _removeExitRequest(msg.sender, index);
        s.amount -= amount;
        _totalBacking -= amount;

        xk613.burnFrom(address(this), amount);
        if (penalty > 0) {
            k613.safeTransfer(address(rewardsDistributor), penalty);
            rewardsDistributor.addPendingPenalty(penalty);
        }
        k613.safeTransfer(msg.sender, payout);

        emit InstantExit(msg.sender, index, amount, penalty);
    }

    /// @notice Removes an exit request from a user's queue by index.
    /// @dev Swaps with the last element and pops to keep the array compact.
    /// @param user Address of the user.
    /// @param index Index of the exit request to remove.
    function _removeExitRequest(address user, uint256 index) internal {
        UserState storage s = _userState[user];
        uint256 last = s.exitQueue.length - 1;
        if (index != last) {
            s.exitQueue[index] = s.exitQueue[last];
        }
        s.exitQueue.pop();
    }

    /// @notice Updates the instant exit penalty. Only callable by DEFAULT_ADMIN_ROLE.
    /// @param newBps New penalty in basis points. Must be > 0 and <= MAX_BASIS_POINTS.
    function setInstantExitPenaltyBps(uint256 newBps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newBps == 0 || newBps > MAX_BASIS_POINTS) revert InvalidBps();
        emit InstantExitPenaltyBpsUpdated(instantExitPenaltyBps, newBps);
        instantExitPenaltyBps = newBps;
    }

    function setMaxExitRequests(uint256 newValue) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newValue == 0) revert InvalidMaxExitRequests();
        emit MaxExitRequestsUpdated(maxExitRequests, newValue);
        maxExitRequests = newValue;
    }

    /// @notice Registers a system staker whose position backs reward xK613 (e.g. RewardsDistributor, Treasury).
    /// @param account Address to register.
    function addSystemStaker(address account) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (account == address(0)) revert ZeroAddress();
        if (isSystemStaker[account]) revert AlreadySystemStaker();
        isSystemStaker[account] = true;
        _systemStakers.push(account);
        emit SystemStakerUpdated(account, true);
    }

    /// @notice Removes a system staker.
    /// @param account Address to remove.
    function removeSystemStaker(address account) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (!isSystemStaker[account]) revert NotSystemStaker();
        isSystemStaker[account] = false;
        uint256 len = _systemStakers.length;
        for (uint256 i = 0; i < len; ++i) {
            if (_systemStakers[i] == account) {
                _systemStakers[i] = _systemStakers[len - 1];
                _systemStakers.pop();
                break;
            }
        }
        emit SystemStakerUpdated(account, false);
    }

    /// @notice Returns all registered system staker addresses.
    function getSystemStakers() external view returns (address[] memory) {
        return _systemStakers;
    }

    /// @notice Redeems reward xK613 for underlying K613, deducting from system staker positions.
    /// @dev Caller transfers xK613 to this contract, it is burned, and K613 is released from system backing.
    /// @param amount Amount of xK613 to redeem for K613.
    function redeemRewards(uint256 amount) external nonReentrant whenNotPaused {
        if (amount == 0) revert ZeroAmount();

        // H-02 FIX: only allow redeeming xK613 that exceeds the caller's own staking position.
        // Prevents stakers from bypassing exit penalties via redeemRewards.
        uint256 inQueueCaller = _exitPendingSum(msg.sender);
        uint256 ownPosition =
            _userState[msg.sender].amount > inQueueCaller ? _userState[msg.sender].amount - inQueueCaller : 0;
        // aderyn-fp-next-line(reentrancy-state-change)
        uint256 walletBalance = IERC20(address(xk613)).balanceOf(msg.sender);
        uint256 rewardPortion = walletBalance > ownPosition ? walletBalance - ownPosition : 0;
        if (amount > rewardPortion) revert ExceedsRewardPortion();

        uint256 remaining = amount;
        uint256 len = _systemStakers.length;
        for (uint256 i = 0; i < len && remaining > 0; ++i) {
            address sys = _systemStakers[i];
            uint256 inQueue = _exitPendingSum(sys);
            uint256 available = _userState[sys].amount > inQueue ? _userState[sys].amount - inQueue : 0;
            if (available == 0) continue;
            uint256 deduct = remaining > available ? available : remaining;
            // aderyn-fp-next-line(costly-loop)
            _userState[sys].amount -= deduct;
            remaining -= deduct;
        }
        if (remaining > 0) revert InsufficientSystemBacking();

        _totalBacking -= amount;
        IERC20(address(xk613)).safeTransferFrom(msg.sender, address(this), amount);
        xk613.burnFrom(address(this), amount);
        k613.safeTransfer(msg.sender, amount);

        emit RewardsRedeemed(msg.sender, amount);
    }

    /// @notice Pauses staking and exit operations.
    /// @dev Functions guarded by `whenNotPaused` will revert while the contract is paused.
    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    /// @notice Unpauses staking and exit operations.
    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }
}

// SPDX-License-Identifier: MIT
// OpenZeppelin Contracts (last updated v5.1.0) (access/IAccessControl.sol)

pragma solidity ^0.8.20;

/**
 * @dev External interface of AccessControl declared to support ERC-165 detection.
 */
interface IAccessControl {
    /**
     * @dev The `account` is missing a role.
     */
    error AccessControlUnauthorizedAccount(address account, bytes32 neededRole);

    /**
     * @dev The caller of a function is not the expected one.
     *
     * NOTE: Don't confuse with {AccessControlUnauthorizedAccount}.
     */
    error AccessControlBadConfirmation();

    /**
     * @dev Emitted when `newAdminRole` is set as ``role``'s admin role, replacing `previousAdminRole`
     *
     * `DEFAULT_ADMIN_ROLE` is the starting admin for all roles, despite
     * {RoleAdminChanged} not being emitted signaling this.
     */
    event RoleAdminChanged(bytes32 indexed role, bytes32 indexed previousAdminRole, bytes32 indexed newAdminRole);

    /**
     * @dev Emitted when `account` is granted `role`.
     *
     * `sender` is the account that originated the contract call. This account bears the admin role (for the granted role).
     * Expected in cases where the role was granted using the internal {AccessControl-_grantRole}.
     */
    event RoleGranted(bytes32 indexed role, address indexed account, address indexed sender);

    /**
     * @dev Emitted when `account` is revoked `role`.
     *
     * `sender` is the account that originated the contract call:
     *   - if using `revokeRole`, it is the admin role bearer
     *   - if using `renounceRole`, it is the role bearer (i.e. `account`)
     */
    event RoleRevoked(bytes32 indexed role, address indexed account, address indexed sender);

    /**
     * @dev Returns `true` if `account` has been granted `role`.
     */
    function hasRole(bytes32 role, address account) external view returns (bool);

    /**
     * @dev Returns the admin role that controls `role`. See {grantRole} and
     * {revokeRole}.
     *
     * To change a role's admin, use {AccessControl-_setRoleAdmin}.
     */
    function getRoleAdmin(bytes32 role) external view returns (bytes32);

    /**
     * @dev Grants `role` to `account`.
     *
     * If `account` had not been already granted `role`, emits a {RoleGranted}
     * event.
     *
     * Requirements:
     *
     * - the caller must have ``role``'s admin role.
     */
    function grantRole(bytes32 role, address account) external;

    /**
     * @dev Revokes `role` from `account`.
     *
     * If `account` had been granted `role`, emits a {RoleRevoked} event.
     *
     * Requirements:
     *
     * - the caller must have ``role``'s admin role.
     */
    function revokeRole(bytes32 role, address account) external;

    /**
     * @dev Revokes `role` from the calling account.
     *
     * Roles are often managed via {grantRole} and {revokeRole}: this function's
     * purpose is to provide a mechanism for accounts to lose their privileges
     * if they are compromised (such as when a trusted device is misplaced).
     *
     * If the calling account had been granted `role`, emits a {RoleRevoked}
     * event.
     *
     * Requirements:
     *
     * - the caller must be `callerConfirmation`.
     */
    function renounceRole(bytes32 role, address callerConfirmation) external;
}

// SPDX-License-Identifier: MIT
// OpenZeppelin Contracts (last updated v5.0.1) (utils/Context.sol)

pragma solidity ^0.8.20;

/**
 * @dev Provides information about the current execution context, including the
 * sender of the transaction and its data. While these are generally available
 * via msg.sender and msg.data, they should not be accessed in such a direct
 * manner, since when dealing with meta-transactions the account sending and
 * paying for execution may not be the actual sender (as far as an application
 * is concerned).
 *
 * This contract is only required for intermediate, library-like contracts.
 */
abstract contract Context {
    function _msgSender() internal view virtual returns (address) {
        return msg.sender;
    }

    function _msgData() internal view virtual returns (bytes calldata) {
        return msg.data;
    }

    function _contextSuffixLength() internal view virtual returns (uint256) {
        return 0;
    }
}

// SPDX-License-Identifier: MIT
// OpenZeppelin Contracts (last updated v5.1.0) (utils/introspection/ERC165.sol)

pragma solidity ^0.8.20;

import {IERC165} from "./IERC165.sol";

/**
 * @dev Implementation of the {IERC165} interface.
 *
 * Contracts that want to implement ERC-165 should inherit from this contract and override {supportsInterface} to check
 * for the additional interface id that will be supported. For example:
 *
 * ```solidity
 * function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
 *     return interfaceId == type(MyInterface).interfaceId || super.supportsInterface(interfaceId);
 * }
 * ```
 */
abstract contract ERC165 is IERC165 {
    /**
     * @dev See {IERC165-supportsInterface}.
     */
    function supportsInterface(bytes4 interfaceId) public view virtual returns (bool) {
        return interfaceId == type(IERC165).interfaceId;
    }
}

// SPDX-License-Identifier: MIT
// OpenZeppelin Contracts (last updated v5.1.0) (interfaces/IERC1363.sol)

pragma solidity ^0.8.20;

import {IERC20} from "./IERC20.sol";
import {IERC165} from "./IERC165.sol";

/**
 * @title IERC1363
 * @dev Interface of the ERC-1363 standard as defined in the https://eips.ethereum.org/EIPS/eip-1363[ERC-1363].
 *
 * Defines an extension interface for ERC-20 tokens that supports executing code on a recipient contract
 * after `transfer` or `transferFrom`, or code on a spender contract after `approve`, in a single transaction.
 */
interface IERC1363 is IERC20, IERC165 {
    /*
     * Note: the ERC-165 identifier for this interface is 0xb0202a11.
     * 0xb0202a11 ===
     *   bytes4(keccak256('transferAndCall(address,uint256)')) ^
     *   bytes4(keccak256('transferAndCall(address,uint256,bytes)')) ^
     *   bytes4(keccak256('transferFromAndCall(address,address,uint256)')) ^
     *   bytes4(keccak256('transferFromAndCall(address,address,uint256,bytes)')) ^
     *   bytes4(keccak256('approveAndCall(address,uint256)')) ^
     *   bytes4(keccak256('approveAndCall(address,uint256,bytes)'))
     */

    /**
     * @dev Moves a `value` amount of tokens from the caller's account to `to`
     * and then calls {IERC1363Receiver-onTransferReceived} on `to`.
     * @param to The address which you want to transfer to.
     * @param value The amount of tokens to be transferred.
     * @return A boolean value indicating whether the operation succeeded unless throwing.
     */
    function transferAndCall(address to, uint256 value) external returns (bool);

    /**
     * @dev Moves a `value` amount of tokens from the caller's account to `to`
     * and then calls {IERC1363Receiver-onTransferReceived} on `to`.
     * @param to The address which you want to transfer to.
     * @param value The amount of tokens to be transferred.
     * @param data Additional data with no specified format, sent in call to `to`.
     * @return A boolean value indicating whether the operation succeeded unless throwing.
     */
    function transferAndCall(address to, uint256 value, bytes calldata data) external returns (bool);

    /**
     * @dev Moves a `value` amount of tokens from `from` to `to` using the allowance mechanism
     * and then calls {IERC1363Receiver-onTransferReceived} on `to`.
     * @param from The address which you want to send tokens from.
     * @param to The address which you want to transfer to.
     * @param value The amount of tokens to be transferred.
     * @return A boolean value indicating whether the operation succeeded unless throwing.
     */
    function transferFromAndCall(address from, address to, uint256 value) external returns (bool);

    /**
     * @dev Moves a `value` amount of tokens from `from` to `to` using the allowance mechanism
     * and then calls {IERC1363Receiver-onTransferReceived} on `to`.
     * @param from The address which you want to send tokens from.
     * @param to The address which you want to transfer to.
     * @param value The amount of tokens to be transferred.
     * @param data Additional data with no specified format, sent in call to `to`.
     * @return A boolean value indicating whether the operation succeeded unless throwing.
     */
    function transferFromAndCall(address from, address to, uint256 value, bytes calldata data) external returns (bool);

    /**
     * @dev Sets a `value` amount of tokens as the allowance of `spender` over the
     * caller's tokens and then calls {IERC1363Spender-onApprovalReceived} on `spender`.
     * @param spender The address which will spend the funds.
     * @param value The amount of tokens to be spent.
     * @return A boolean value indicating whether the operation succeeded unless throwing.
     */
    function approveAndCall(address spender, uint256 value) external returns (bool);

    /**
     * @dev Sets a `value` amount of tokens as the allowance of `spender` over the
     * caller's tokens and then calls {IERC1363Spender-onApprovalReceived} on `spender`.
     * @param spender The address which will spend the funds.
     * @param value The amount of tokens to be spent.
     * @param data Additional data with no specified format, sent in call to `spender`.
     * @return A boolean value indicating whether the operation succeeded unless throwing.
     */
    function approveAndCall(address spender, uint256 value, bytes calldata data) external returns (bool);
}

// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

/// @title Callback for IUniswapV3PoolActions#swap
/// @notice Any contract that calls IUniswapV3PoolActions#swap must implement this interface
interface IUniswapV3SwapCallback {
    /// @notice Called to `msg.sender` after executing a swap via IUniswapV3Pool#swap.
    /// @dev In the implementation you must pay the pool tokens owed for the swap.
    /// The caller of this method must be checked to be a UniswapV3Pool deployed by the canonical UniswapV3Factory.
    /// amount0Delta and amount1Delta can both be 0 if no tokens were swapped.
    /// @param amount0Delta The amount of token0 that was sent (negative) or must be received (positive) by the pool by
    /// the end of the swap. If positive, the callback must send that amount of token0 to the pool.
    /// @param amount1Delta The amount of token1 that was sent (negative) or must be received (positive) by the pool by
    /// the end of the swap. If positive, the callback must send that amount of token1 to the pool.
    /// @param data Any data passed through by the caller via the IUniswapV3PoolActions#swap call
    function uniswapV3SwapCallback(
        int256 amount0Delta,
        int256 amount1Delta,
        bytes calldata data
    ) external;
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {AccessControl} from "openzeppelin-contracts/contracts/access/AccessControl.sol";
import {Pausable} from "openzeppelin-contracts/contracts/utils/Pausable.sol";

/// @title xK613
/// @notice Staking receipt token minted 1:1 on stake, burned on exit. Rewards via manual deposit in RewardsDistributor.
/// @dev Transfers restricted to whitelist. Minting/burning by MINTER_ROLE.
contract xK613 is ERC20, AccessControl, Pausable {
    /// @notice Thrown when a zero address is passed as a parameter.
    error ZeroAddress();
    /// @notice Thrown when a non-minter attempts to mint or burn tokens.
    error OnlyMinter();
    /// @notice Thrown when a transfer involves addresses not in the whitelist.
    error TransfersDisabled();

    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    /// @notice Current address authorized to mint and burn tokens.
    address public minter;
    /// @notice Mapping of addresses allowed to send and receive xK613.
    mapping(address => bool) public transferWhitelist;

    /// @notice Emitted when the minter address is updated.
    /// @param previousMinter The previous minter address.
    /// @param newMinter The new minter address.
    event MinterUpdated(address indexed previousMinter, address indexed newMinter);
    /// @notice Emitted when an address is added to or removed from the transfer whitelist.
    /// @param account The address whose whitelist status changed.
    /// @param allowed Whether the address is now whitelisted.
    event TransferWhitelistUpdated(address indexed account, bool allowed);

    /// @notice Deploys the xK613 token with the initial minter.
    /// @param initialMinter Address that will be granted MINTER_ROLE for minting and burning.
    constructor(address initialMinter) ERC20("xK613", "xK613") {
        if (initialMinter == address(0)) {
            revert ZeroAddress();
        }
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(PAUSER_ROLE, msg.sender);
        minter = initialMinter;
        _grantRole(MINTER_ROLE, initialMinter);
        emit MinterUpdated(address(0), initialMinter);
    }

    /// @notice Updates the minter address. Only callable by DEFAULT_ADMIN_ROLE.
    /// @param newMinter The new address to grant MINTER_ROLE.
    function setMinter(address newMinter) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newMinter == address(0)) {
            revert ZeroAddress();
        }
        _revokeRole(MINTER_ROLE, minter);
        emit MinterUpdated(minter, newMinter);
        minter = newMinter;
        _grantRole(MINTER_ROLE, newMinter);
    }

    /// @notice Adds or removes an address from the transfer whitelist.
    /// @param account Address to update.
    /// @param allowed True to allow transfers, false to disallow.
    function setTransferWhitelist(address account, bool allowed) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (account == address(0)) {
            revert ZeroAddress();
        }
        transferWhitelist[account] = allowed;
        emit TransferWhitelistUpdated(account, allowed);
    }

    /// @notice Mints new tokens to the specified address.
    /// @param to Recipient of the minted tokens.
    /// @param amount Amount of tokens to mint.
    function mint(address to, uint256 amount) external {
        if (!hasRole(MINTER_ROLE, msg.sender)) {
            revert OnlyMinter();
        }
        _mint(to, amount);
    }

    /// @notice Burns tokens from the specified address. Caller must have MINTER_ROLE.
    /// @param from Address to burn tokens from.
    /// @param amount Amount of tokens to burn.
    function burnFrom(address from, uint256 amount) external {
        if (!hasRole(MINTER_ROLE, msg.sender)) {
            revert OnlyMinter();
        }
        _burn(from, amount);
    }

    /// @notice Pauses all token transfers. Only callable by PAUSER_ROLE.
    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    /// @notice Resumes token transfers. Only callable by PAUSER_ROLE.
    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    /// @dev Overrides _update: enforce whitelist and pause.
    function _update(address from, address to, uint256 value) internal override {
        _requireNotPaused();
        if (from != address(0) && to != address(0)) {
            if (!transferWhitelist[from] && !transferWhitelist[to]) {
                revert TransfersDisabled();
            }
        }
        super._update(from, to, value);
    }
}

// SPDX-License-Identifier: MIT
// OpenZeppelin Contracts (last updated v5.1.0) (utils/introspection/IERC165.sol)

pragma solidity ^0.8.20;

/**
 * @dev Interface of the ERC-165 standard, as defined in the
 * https://eips.ethereum.org/EIPS/eip-165[ERC].
 *
 * Implementers can declare support of contract interfaces, which can then be
 * queried by others ({ERC165Checker}).
 *
 * For an implementation, see {ERC165}.
 */
interface IERC165 {
    /**
     * @dev Returns true if this contract implements the interface defined by
     * `interfaceId`. See the corresponding
     * https://eips.ethereum.org/EIPS/eip-165#how-interfaces-are-identified[ERC section]
     * to learn more about how these ids are created.
     *
     * This function call must use less than 30 000 gas.
     */
    function supportsInterface(bytes4 interfaceId) external view returns (bool);
}

// SPDX-License-Identifier: MIT
// OpenZeppelin Contracts (last updated v5.0.0) (interfaces/IERC20.sol)

pragma solidity ^0.8.20;

import {IERC20} from "../token/ERC20/IERC20.sol";

// SPDX-License-Identifier: MIT
// OpenZeppelin Contracts (last updated v5.0.0) (interfaces/IERC165.sol)

pragma solidity ^0.8.20;

import {IERC165} from "../utils/introspection/IERC165.sol";

// SPDX-License-Identifier: MIT
// OpenZeppelin Contracts (last updated v5.2.0) (token/ERC20/ERC20.sol)

pragma solidity ^0.8.20;

import {IERC20} from "./IERC20.sol";
import {IERC20Metadata} from "./extensions/IERC20Metadata.sol";
import {Context} from "../../utils/Context.sol";
import {IERC20Errors} from "../../interfaces/draft-IERC6093.sol";

/**
 * @dev Implementation of the {IERC20} interface.
 *
 * This implementation is agnostic to the way tokens are created. This means
 * that a supply mechanism has to be added in a derived contract using {_mint}.
 *
 * TIP: For a detailed writeup see our guide
 * https://forum.openzeppelin.com/t/how-to-implement-erc20-supply-mechanisms/226[How
 * to implement supply mechanisms].
 *
 * The default value of {decimals} is 18. To change this, you should override
 * this function so it returns a different value.
 *
 * We have followed general OpenZeppelin Contracts guidelines: functions revert
 * instead returning `false` on failure. This behavior is nonetheless
 * conventional and does not conflict with the expectations of ERC-20
 * applications.
 */
abstract contract ERC20 is Context, IERC20, IERC20Metadata, IERC20Errors {
    mapping(address account => uint256) private _balances;

    mapping(address account => mapping(address spender => uint256)) private _allowances;

    uint256 private _totalSupply;

    string private _name;
    string private _symbol;

    /**
     * @dev Sets the values for {name} and {symbol}.
     *
     * All two of these values are immutable: they can only be set once during
     * construction.
     */
    constructor(string memory name_, string memory symbol_) {
        _name = name_;
        _symbol = symbol_;
    }

    /**
     * @dev Returns the name of the token.
     */
    function name() public view virtual returns (string memory) {
        return _name;
    }

    /**
     * @dev Returns the symbol of the token, usually a shorter version of the
     * name.
     */
    function symbol() public view virtual returns (string memory) {
        return _symbol;
    }

    /**
     * @dev Returns the number of decimals used to get its user representation.
     * For example, if `decimals` equals `2`, a balance of `505` tokens should
     * be displayed to a user as `5.05` (`505 / 10 ** 2`).
     *
     * Tokens usually opt for a value of 18, imitating the relationship between
     * Ether and Wei. This is the default value returned by this function, unless
     * it's overridden.
     *
     * NOTE: This information is only used for _display_ purposes: it in
     * no way affects any of the arithmetic of the contract, including
     * {IERC20-balanceOf} and {IERC20-transfer}.
     */
    function decimals() public view virtual returns (uint8) {
        return 18;
    }

    /**
     * @dev See {IERC20-totalSupply}.
     */
    function totalSupply() public view virtual returns (uint256) {
        return _totalSupply;
    }

    /**
     * @dev See {IERC20-balanceOf}.
     */
    function balanceOf(address account) public view virtual returns (uint256) {
        return _balances[account];
    }

    /**
     * @dev See {IERC20-transfer}.
     *
     * Requirements:
     *
     * - `to` cannot be the zero address.
     * - the caller must have a balance of at least `value`.
     */
    function transfer(address to, uint256 value) public virtual returns (bool) {
        address owner = _msgSender();
        _transfer(owner, to, value);
        return true;
    }

    /**
     * @dev See {IERC20-allowance}.
     */
    function allowance(address owner, address spender) public view virtual returns (uint256) {
        return _allowances[owner][spender];
    }

    /**
     * @dev See {IERC20-approve}.
     *
     * NOTE: If `value` is the maximum `uint256`, the allowance is not updated on
     * `transferFrom`. This is semantically equivalent to an infinite approval.
     *
     * Requirements:
     *
     * - `spender` cannot be the zero address.
     */
    function approve(address spender, uint256 value) public virtual returns (bool) {
        address owner = _msgSender();
        _approve(owner, spender, value);
        return true;
    }

    /**
     * @dev See {IERC20-transferFrom}.
     *
     * Skips emitting an {Approval} event indicating an allowance update. This is not
     * required by the ERC. See {xref-ERC20-_approve-address-address-uint256-bool-}[_approve].
     *
     * NOTE: Does not update the allowance if the current allowance
     * is the maximum `uint256`.
     *
     * Requirements:
     *
     * - `from` and `to` cannot be the zero address.
     * - `from` must have a balance of at least `value`.
     * - the caller must have allowance for ``from``'s tokens of at least
     * `value`.
     */
    function transferFrom(address from, address to, uint256 value) public virtual returns (bool) {
        address spender = _msgSender();
        _spendAllowance(from, spender, value);
        _transfer(from, to, value);
        return true;
    }

    /**
     * @dev Moves a `value` amount of tokens from `from` to `to`.
     *
     * This internal function is equivalent to {transfer}, and can be used to
     * e.g. implement automatic token fees, slashing mechanisms, etc.
     *
     * Emits a {Transfer} event.
     *
     * NOTE: This function is not virtual, {_update} should be overridden instead.
     */
    function _transfer(address from, address to, uint256 value) internal {
        if (from == address(0)) {
            revert ERC20InvalidSender(address(0));
        }
        if (to == address(0)) {
            revert ERC20InvalidReceiver(address(0));
        }
        _update(from, to, value);
    }

    /**
     * @dev Transfers a `value` amount of tokens from `from` to `to`, or alternatively mints (or burns) if `from`
     * (or `to`) is the zero address. All customizations to transfers, mints, and burns should be done by overriding
     * this function.
     *
     * Emits a {Transfer} event.
     */
    function _update(address from, address to, uint256 value) internal virtual {
        if (from == address(0)) {
            // Overflow check required: The rest of the code assumes that totalSupply never overflows
            _totalSupply += value;
        } else {
            uint256 fromBalance = _balances[from];
            if (fromBalance < value) {
                revert ERC20InsufficientBalance(from, fromBalance, value);
            }
            unchecked {
                // Overflow not possible: value <= fromBalance <= totalSupply.
                _balances[from] = fromBalance - value;
            }
        }

        if (to == address(0)) {
            unchecked {
                // Overflow not possible: value <= totalSupply or value <= fromBalance <= totalSupply.
                _totalSupply -= value;
            }
        } else {
            unchecked {
                // Overflow not possible: balance + value is at most totalSupply, which we know fits into a uint256.
                _balances[to] += value;
            }
        }

        emit Transfer(from, to, value);
    }

    /**
     * @dev Creates a `value` amount of tokens and assigns them to `account`, by transferring it from address(0).
     * Relies on the `_update` mechanism
     *
     * Emits a {Transfer} event with `from` set to the zero address.
     *
     * NOTE: This function is not virtual, {_update} should be overridden instead.
     */
    function _mint(address account, uint256 value) internal {
        if (account == address(0)) {
            revert ERC20InvalidReceiver(address(0));
        }
        _update(address(0), account, value);
    }

    /**
     * @dev Destroys a `value` amount of tokens from `account`, lowering the total supply.
     * Relies on the `_update` mechanism.
     *
     * Emits a {Transfer} event with `to` set to the zero address.
     *
     * NOTE: This function is not virtual, {_update} should be overridden instead
     */
    function _burn(address account, uint256 value) internal {
        if (account == address(0)) {
            revert ERC20InvalidSender(address(0));
        }
        _update(account, address(0), value);
    }

    /**
     * @dev Sets `value` as the allowance of `spender` over the `owner` s tokens.
     *
     * This internal function is equivalent to `approve`, and can be used to
     * e.g. set automatic allowances for certain subsystems, etc.
     *
     * Emits an {Approval} event.
     *
     * Requirements:
     *
     * - `owner` cannot be the zero address.
     * - `spender` cannot be the zero address.
     *
     * Overrides to this logic should be done to the variant with an additional `bool emitEvent` argument.
     */
    function _approve(address owner, address spender, uint256 value) internal {
        _approve(owner, spender, value, true);
    }

    /**
     * @dev Variant of {_approve} with an optional flag to enable or disable the {Approval} event.
     *
     * By default (when calling {_approve}) the flag is set to true. On the other hand, approval changes made by
     * `_spendAllowance` during the `transferFrom` operation set the flag to false. This saves gas by not emitting any
     * `Approval` event during `transferFrom` operations.
     *
     * Anyone who wishes to continue emitting `Approval` events on the`transferFrom` operation can force the flag to
     * true using the following override:
     *
     * ```solidity
     * function _approve(address owner, address spender, uint256 value, bool) internal virtual override {
     *     super._approve(owner, spender, value, true);
     * }
     * ```
     *
     * Requirements are the same as {_approve}.
     */
    function _approve(address owner, address spender, uint256 value, bool emitEvent) internal virtual {
        if (owner == address(0)) {
            revert ERC20InvalidApprover(address(0));
        }
        if (spender == address(0)) {
            revert ERC20InvalidSpender(address(0));
        }
        _allowances[owner][spender] = value;
        if (emitEvent) {
            emit Approval(owner, spender, value);
        }
    }

    /**
     * @dev Updates `owner` s allowance for `spender` based on spent `value`.
     *
     * Does not update the allowance value in case of infinite allowance.
     * Revert if not enough allowance is available.
     *
     * Does not emit an {Approval} event.
     */
    function _spendAllowance(address owner, address spender, uint256 value) internal virtual {
        uint256 currentAllowance = allowance(owner, spender);
        if (currentAllowance < type(uint256).max) {
            if (currentAllowance < value) {
                revert ERC20InsufficientAllowance(spender, currentAllowance, value);
            }
            unchecked {
                _approve(owner, spender, currentAllowance - value, false);
            }
        }
    }
}

// SPDX-License-Identifier: MIT
// OpenZeppelin Contracts (last updated v5.1.0) (token/ERC20/extensions/IERC20Metadata.sol)

pragma solidity ^0.8.20;

import {IERC20} from "../IERC20.sol";

/**
 * @dev Interface for the optional metadata functions from the ERC-20 standard.
 */
interface IERC20Metadata is IERC20 {
    /**
     * @dev Returns the name of the token.
     */
    function name() external view returns (string memory);

    /**
     * @dev Returns the symbol of the token.
     */
    function symbol() external view returns (string memory);

    /**
     * @dev Returns the decimals places of the token.
     */
    function decimals() external view returns (uint8);
}

// SPDX-License-Identifier: MIT
// OpenZeppelin Contracts (last updated v5.1.0) (interfaces/draft-IERC6093.sol)
pragma solidity ^0.8.20;

/**
 * @dev Standard ERC-20 Errors
 * Interface of the https://eips.ethereum.org/EIPS/eip-6093[ERC-6093] custom errors for ERC-20 tokens.
 */
interface IERC20Errors {
    /**
     * @dev Indicates an error related to the current `balance` of a `sender`. Used in transfers.
     * @param sender Address whose tokens are being transferred.
     * @param balance Current balance for the interacting account.
     * @param needed Minimum amount required to perform a transfer.
     */
    error ERC20InsufficientBalance(address sender, uint256 balance, uint256 needed);

    /**
     * @dev Indicates a failure with the token `sender`. Used in transfers.
     * @param sender Address whose tokens are being transferred.
     */
    error ERC20InvalidSender(address sender);

    /**
     * @dev Indicates a failure with the token `receiver`. Used in transfers.
     * @param receiver Address to which tokens are being transferred.
     */
    error ERC20InvalidReceiver(address receiver);

    /**
     * @dev Indicates a failure with the `spender`’s `allowance`. Used in transfers.
     * @param spender Address that may be allowed to operate on tokens without being their owner.
     * @param allowance Amount of tokens a `spender` is allowed to operate with.
     * @param needed Minimum amount required to perform a transfer.
     */
    error ERC20InsufficientAllowance(address spender, uint256 allowance, uint256 needed);

    /**
     * @dev Indicates a failure with the `approver` of a token to be approved. Used in approvals.
     * @param approver Address initiating an approval operation.
     */
    error ERC20InvalidApprover(address approver);

    /**
     * @dev Indicates a failure with the `spender` to be approved. Used in approvals.
     * @param spender Address that may be allowed to operate on tokens without being their owner.
     */
    error ERC20InvalidSpender(address spender);
}

/**
 * @dev Standard ERC-721 Errors
 * Interface of the https://eips.ethereum.org/EIPS/eip-6093[ERC-6093] custom errors for ERC-721 tokens.
 */
interface IERC721Errors {
    /**
     * @dev Indicates that an address can't be an owner. For example, `address(0)` is a forbidden owner in ERC-20.
     * Used in balance queries.
     * @param owner Address of the current owner of a token.
     */
    error ERC721InvalidOwner(address owner);

    /**
     * @dev Indicates a `tokenId` whose `owner` is the zero address.
     * @param tokenId Identifier number of a token.
     */
    error ERC721NonexistentToken(uint256 tokenId);

    /**
     * @dev Indicates an error related to the ownership over a particular token. Used in transfers.
     * @param sender Address whose tokens are being transferred.
     * @param tokenId Identifier number of a token.
     * @param owner Address of the current owner of a token.
     */
    error ERC721IncorrectOwner(address sender, uint256 tokenId, address owner);

    /**
     * @dev Indicates a failure with the token `sender`. Used in transfers.
     * @param sender Address whose tokens are being transferred.
     */
    error ERC721InvalidSender(address sender);

    /**
     * @dev Indicates a failure with the token `receiver`. Used in transfers.
     * @param receiver Address to which tokens are being transferred.
     */
    error ERC721InvalidReceiver(address receiver);

    /**
     * @dev Indicates a failure with the `operator`’s approval. Used in transfers.
     * @param operator Address that may be allowed to operate on tokens without being their owner.
     * @param tokenId Identifier number of a token.
     */
    error ERC721InsufficientApproval(address operator, uint256 tokenId);

    /**
     * @dev Indicates a failure with the `approver` of a token to be approved. Used in approvals.
     * @param approver Address initiating an approval operation.
     */
    error ERC721InvalidApprover(address approver);

    /**
     * @dev Indicates a failure with the `operator` to be approved. Used in approvals.
     * @param operator Address that may be allowed to operate on tokens without being their owner.
     */
    error ERC721InvalidOperator(address operator);
}

/**
 * @dev Standard ERC-1155 Errors
 * Interface of the https://eips.ethereum.org/EIPS/eip-6093[ERC-6093] custom errors for ERC-1155 tokens.
 */
interface IERC1155Errors {
    /**
     * @dev Indicates an error related to the current `balance` of a `sender`. Used in transfers.
     * @param sender Address whose tokens are being transferred.
     * @param balance Current balance for the interacting account.
     * @param needed Minimum amount required to perform a transfer.
     * @param tokenId Identifier number of a token.
     */
    error ERC1155InsufficientBalance(address sender, uint256 balance, uint256 needed, uint256 tokenId);

    /**
     * @dev Indicates a failure with the token `sender`. Used in transfers.
     * @param sender Address whose tokens are being transferred.
     */
    error ERC1155InvalidSender(address sender);

    /**
     * @dev Indicates a failure with the token `receiver`. Used in transfers.
     * @param receiver Address to which tokens are being transferred.
     */
    error ERC1155InvalidReceiver(address receiver);

    /**
     * @dev Indicates a failure with the `operator`’s approval. Used in transfers.
     * @param operator Address that may be allowed to operate on tokens without being their owner.
     * @param owner Address of the current owner of a token.
     */
    error ERC1155MissingApprovalForAll(address operator, address owner);

    /**
     * @dev Indicates a failure with the `approver` of a token to be approved. Used in approvals.
     * @param approver Address initiating an approval operation.
     */
    error ERC1155InvalidApprover(address approver);

    /**
     * @dev Indicates a failure with the `operator` to be approved. Used in approvals.
     * @param operator Address that may be allowed to operate on tokens without being their owner.
     */
    error ERC1155InvalidOperator(address operator);

    /**
     * @dev Indicates an array length mismatch between ids and values in a safeBatchTransferFrom operation.
     * Used in batch transfers.
     * @param idsLength Length of the array of token identifiers
     * @param valuesLength Length of the array of token amounts
     */
    error ERC1155InvalidArrayLength(uint256 idsLength, uint256 valuesLength);
}

{"compiler":{"version":"0.8.34+commit.80d5c536"},"language":"Solidity","output":{"abi":[{"inputs":[{"internalType":"address","name":"k613Token","type":"address"},{"internalType":"address","name":"xk613Token","type":"address"},{"internalType":"address","name":"staking_","type":"address"},{"internalType":"address","name":"rewardsDistributor_","type":"address"}],"stateMutability":"nonpayable","type":"constructor"},{"inputs":[],"name":"AccessControlBadConfirmation","type":"error"},{"inputs":[{"internalType":"address","name":"account","type":"address"},{"internalType":"bytes32","name":"neededRole","type":"bytes32"}],"name":"AccessControlUnauthorizedAccount","type":"error"},{"inputs":[],"name":"BuybackFailed","type":"error"},{"inputs":[],"name":"EnforcedPause","type":"error"},{"inputs":[],"name":"ExpectedPause","type":"error"},{"inputs":[],"name":"InsufficientOutput","type":"error"},{"inputs":[],"name":"ReentrancyGuardReentrantCall","type":"error"},{"inputs":[],"name":"RouterNotWhitelisted","type":"error"},{"inputs":[{"internalType":"address","name":"token","type":"address"}],"name":"SafeERC20FailedOperation","type":"error"},{"inputs":[],"name":"ZeroAddress","type":"error"},{"inputs":[],"name":"ZeroAmount","type":"error"},{"anonymous":false,"inputs":[{"indexed":true,"internalType":"address","name":"tokenIn","type":"address"},{"indexed":true,"internalType":"address","name":"router","type":"address"},{"indexed":false,"internalType":"uint256","name":"amountIn","type":"uint256"},{"indexed":false,"internalType":"uint256","name":"k613Out","type":"uint256"},{"indexed":false,"internalType":"bool","name":"distributed","type":"bool"}],"name":"BuybackExecuted","type":"event"},{"anonymous":false,"inputs":[{"indexed":false,"internalType":"address","name":"account","type":"address"}],"name":"Paused","type":"event"},{"anonymous":false,"inputs":[{"indexed":true,"internalType":"bytes32","name":"role","type":"bytes32"},{"indexed":true,"internalType":"bytes32","name":"previousAdminRole","type":"bytes32"},{"indexed":true,"internalType":"bytes32","name":"newAdminRole","type":"bytes32"}],"name":"RoleAdminChanged","type":"event"},{"anonymous":false,"inputs":[{"indexed":true,"internalType":"bytes32","name":"role","type":"bytes32"},{"indexed":true,"internalType":"address","name":"account","type":"address"},{"indexed":true,"internalType":"address","name":"sender","type":"address"}],"name":"RoleGranted","type":"event"},{"anonymous":false,"inputs":[{"indexed":true,"internalType":"bytes32","name":"role","type":"bytes32"},{"indexed":true,"internalType":"address","name":"account","type":"address"},{"indexed":true,"internalType":"address","name":"sender","type":"address"}],"name":"RoleRevoked","type":"event"},{"anonymous":false,"inputs":[{"indexed":true,"internalType":"address","name":"router","type":"address"},{"indexed":false,"internalType":"bool","name":"allowed","type":"bool"}],"name":"RouterWhitelistUpdated","type":"event"},{"anonymous":false,"inputs":[{"indexed":false,"internalType":"uint256","name":"amount","type":"uint256"}],"name":"StakedForExternalIncentives","type":"event"},{"anonymous":false,"inputs":[{"indexed":false,"internalType":"address","name":"account","type":"address"}],"name":"Unpaused","type":"event"},{"anonymous":false,"inputs":[{"indexed":true,"internalType":"address","name":"token","type":"address"},{"indexed":true,"internalType":"address","name":"to","type":"address"},{"indexed":false,"internalType":"uint256","name":"amount","type":"uint256"}],"name":"Withdrawn","type":"event"},{"anonymous":false,"inputs":[{"indexed":true,"internalType":"address","name":"spender","type":"address"},{"indexed":false,"internalType":"uint256","name":"amount","type":"uint256"}],"name":"Xk613PullAllowanceSet","type":"event"},{"inputs":[],"name":"DEFAULT_ADMIN_ROLE","outputs":[{"internalType":"bytes32","name":"","type":"bytes32"}],"stateMutability":"view","type":"function"},{"inputs":[],"name":"PAUSER_ROLE","outputs":[{"internalType":"bytes32","name":"","type":"bytes32"}],"stateMutability":"view","type":"function"},{"inputs":[{"internalType":"address","name":"spender","type":"address"},{"internalType":"uint256","name":"amount","type":"uint256"}],"name":"approveXk613PullRewards","outputs":[],"stateMutability":"nonpayable","type":"function"},{"inputs":[{"internalType":"address","name":"tokenIn","type":"address"},{"internalType":"address","name":"router","type":"address"},{"internalType":"uint256","name":"amountIn","type":"uint256"},{"internalType":"uint256","name":"minK613Out","type":"uint256"},{"internalType":"uint24","name":"poolFee","type":"uint24"},{"internalType":"bool","name":"distributeRewards","type":"bool"}],"name":"buybackV3ExactInputSingle","outputs":[{"internalType":"uint256","name":"k613Out","type":"uint256"}],"stateMutability":"nonpayable","type":"function"},{"inputs":[{"internalType":"uint256","name":"amount","type":"uint256"}],"name":"depositRewards","outputs":[],"stateMutability":"nonpayable","type":"function"},{"inputs":[{"internalType":"bytes32","name":"role","type":"bytes32"}],"name":"getRoleAdmin","outputs":[{"internalType":"bytes32","name":"","type":"bytes32"}],"stateMutability":"view","type":"function"},{"inputs":[],"name":"getWhitelistedRouters","outputs":[{"internalType":"address[]","name":"","type":"address[]"}],"stateMutability":"view","type":"function"},{"inputs":[{"internalType":"bytes32","name":"role","type":"bytes32"},{"internalType":"address","name":"account","type":"address"}],"name":"grantRole","outputs":[],"stateMutability":"nonpayable","type":"function"},{"inputs":[{"internalType":"bytes32","name":"role","type":"bytes32"},{"internalType":"address","name":"account","type":"address"}],"name":"hasRole","outputs":[{"internalType":"bool","name":"","type":"bool"}],"stateMutability":"view","type":"function"},{"inputs":[],"name":"k613","outputs":[{"internalType":"contract IERC20","name":"","type":"address"}],"stateMutability":"view","type":"function"},{"inputs":[],"name":"pause","outputs":[],"stateMutability":"nonpayable","type":"function"},{"inputs":[],"name":"paused","outputs":[{"internalType":"bool","name":"","type":"bool"}],"stateMutability":"view","type":"function"},{"inputs":[{"internalType":"bytes32","name":"role","type":"bytes32"},{"internalType":"address","name":"callerConfirmation","type":"address"}],"name":"renounceRole","outputs":[],"stateMutability":"nonpayable","type":"function"},{"inputs":[{"internalType":"bytes32","name":"role","type":"bytes32"},{"internalType":"address","name":"account","type":"address"}],"name":"revokeRole","outputs":[],"stateMutability":"nonpayable","type":"function"},{"inputs":[],"name":"rewardsDistributor","outputs":[{"internalType":"contract RewardsDistributor","name":"","type":"address"}],"stateMutability":"view","type":"function"},{"inputs":[{"internalType":"address","name":"","type":"address"}],"name":"routerWhitelist","outputs":[{"internalType":"bool","name":"","type":"bool"}],"stateMutability":"view","type":"function"},{"inputs":[{"internalType":"address","name":"router","type":"address"},{"internalType":"bool","name":"allowed","type":"bool"}],"name":"setRouterWhitelist","outputs":[],"stateMutability":"nonpayable","type":"function"},{"inputs":[{"internalType":"uint256","name":"amount","type":"uint256"}],"name":"stakeForExternalIncentives","outputs":[],"stateMutability":"nonpayable","type":"function"},{"inputs":[],"name":"staking","outputs":[{"internalType":"contract Staking","name":"","type":"address"}],"stateMutability":"view","type":"function"},{"inputs":[{"internalType":"bytes4","name":"interfaceId","type":"bytes4"}],"name":"supportsInterface","outputs":[{"internalType":"bool","name":"","type":"bool"}],"stateMutability":"view","type":"function"},{"inputs":[],"name":"unpause","outputs":[],"stateMutability":"nonpayable","type":"function"},{"inputs":[{"internalType":"address","name":"token","type":"address"},{"internalType":"address","name":"to","type":"address"},{"internalType":"uint256","name":"amount","type":"uint256"}],"name":"withdraw","outputs":[],"stateMutability":"nonpayable","type":"function"},{"inputs":[],"name":"xk613","outputs":[{"internalType":"contract IERC20","name":"","type":"address"}],"stateMutability":"view","type":"function"}],"devdoc":{"errors":{"AccessControlBadConfirmation()":[{"details":"The caller of a function is not the expected one. NOTE: Don't confuse with {AccessControlUnauthorizedAccount}."}],"AccessControlUnauthorizedAccount(address,bytes32)":[{"details":"The `account` is missing a role."}],"EnforcedPause()":[{"details":"The operation failed because the contract is paused."}],"ExpectedPause()":[{"details":"The operation failed because the contract is not paused."}],"ReentrancyGuardReentrantCall()":[{"details":"Unauthorized reentrant call."}],"SafeERC20FailedOperation(address)":[{"details":"An operation with an ERC-20 token failed."}]},"events":{"BuybackExecuted(address,address,uint256,uint256,bool)":{"params":{"amountIn":"Amount of tokenIn swapped.","distributed":"Whether rewards were distributed to stakers.","k613Out":"Amount of K613 received.","router":"DEX router used for the swap.","tokenIn":"Token swapped in for K613."}},"Paused(address)":{"details":"Emitted when the pause is triggered by `account`."},"RoleAdminChanged(bytes32,bytes32,bytes32)":{"details":"Emitted when `newAdminRole` is set as ``role``'s admin role, replacing `previousAdminRole` `DEFAULT_ADMIN_ROLE` is the starting admin for all roles, despite {RoleAdminChanged} not being emitted signaling this."},"RoleGranted(bytes32,address,address)":{"details":"Emitted when `account` is granted `role`. `sender` is the account that originated the contract call. This account bears the admin role (for the granted role). Expected in cases where the role was granted using the internal {AccessControl-_grantRole}."},"RoleRevoked(bytes32,address,address)":{"details":"Emitted when `account` is revoked `role`. `sender` is the account that originated the contract call:   - if using `revokeRole`, it is the admin role bearer   - if using `renounceRole`, it is the role bearer (i.e. `account`)"},"Unpaused(address)":{"details":"Emitted when the pause is lifted by `account`."},"Withdrawn(address,address,uint256)":{"params":{"amount":"Amount withdrawn.","to":"Recipient.","token":"Token withdrawn."}}},"kind":"dev","methods":{"buybackV3ExactInputSingle(address,address,uint256,uint256,uint24,bool)":{"params":{"poolFee":"Uniswap V3 fee tier (e.g. 3000 = 0.3%)."}},"depositRewards(uint256)":{"params":{"amount":"Amount of K613 to stake and deposit as xK613 rewards. If zero, no-op."}},"getRoleAdmin(bytes32)":{"details":"Returns the admin role that controls `role`. See {grantRole} and {revokeRole}. To change a role's admin, use {_setRoleAdmin}."},"grantRole(bytes32,address)":{"details":"Grants `role` to `account`. If `account` had not been already granted `role`, emits a {RoleGranted} event. Requirements: - the caller must have ``role``'s admin role. May emit a {RoleGranted} event."},"hasRole(bytes32,address)":{"details":"Returns `true` if `account` has been granted `role`."},"paused()":{"details":"Returns true if the contract is paused, and false otherwise."},"renounceRole(bytes32,address)":{"details":"Revokes `role` from the calling account. Roles are often managed via {grantRole} and {revokeRole}: this function's purpose is to provide a mechanism for accounts to lose their privileges if they are compromised (such as when a trusted device is misplaced). If the calling account had been revoked `role`, emits a {RoleRevoked} event. Requirements: - the caller must be `callerConfirmation`. May emit a {RoleRevoked} event."},"revokeRole(bytes32,address)":{"details":"Revokes `role` from `account`. If `account` had been granted `role`, emits a {RoleRevoked} event. Requirements: - the caller must have ``role``'s admin role. May emit a {RoleRevoked} event."},"setRouterWhitelist(address,bool)":{"params":{"allowed":"True to allow buyback via this router, false to disallow.","router":"Router address to whitelist or remove."}},"stakeForExternalIncentives(uint256)":{"details":"Treasury is whitelisted to hold xK613 and is a `systemStaker` in `Staking`, so the resulting         xK613 sits on Treasury's balance and is later pulled by the strategy via `transferFrom`         (see `approveXk613PullRewards`). This contrasts with `depositRewards`, which forwards xK613         to `RewardsDistributor` and adds to its reward stream.","params":{"amount":"Amount of K613 (already held by Treasury) to stake. Must be non-zero."}},"supportsInterface(bytes4)":{"details":"See {IERC165-supportsInterface}."},"withdraw(address,address,uint256)":{"params":{"amount":"Amount to withdraw.","to":"Recipient address.","token":"Token to withdraw."}}},"title":"Treasury","version":1},"userdoc":{"errors":{"BuybackFailed()":[{"notice":"Thrown when the DEX swap call fails."}],"InsufficientOutput()":[{"notice":"Thrown when the swap output is less than minK613Out."}],"RouterNotWhitelisted()":[{"notice":"Thrown when buyback is called with a router not in the whitelist."}],"ZeroAddress()":[{"notice":"Thrown when a zero address is passed as a parameter."}],"ZeroAmount()":[{"notice":"Thrown when amount is zero where a positive value is required."}]},"events":{"BuybackExecuted(address,address,uint256,uint256,bool)":{"notice":"Emitted when a buyback is executed."},"RouterWhitelistUpdated(address,bool)":{"notice":"Emitted when a router is added to or removed from the whitelist."},"StakedForExternalIncentives(uint256)":{"notice":"Emitted when Treasury stakes K613 it already holds, to obtain xK613 used as the reward         pool for an external pull-based incentives strategy (e.g. Aave's `PullRewardsTransferStrategy`)."},"Withdrawn(address,address,uint256)":{"notice":"Emitted when admin withdraws tokens."}},"kind":"user","methods":{"buybackV3ExactInputSingle(address,address,uint256,uint256,uint24,bool)":{"notice":"Buys K613 with `tokenIn` through a whitelisted router implementing `IV3SwapRouter.exactInputSingle` (Uniswap SwapRouter02-style)."},"constructor":{"notice":"Deploys the Treasury with K613, xK613, Staking, and RewardsDistributor."},"depositRewards(uint256)":{"notice":"Deposits rewards: stakes K613 to get xK613, sends xK613 to RewardsDistributor and notifies. Caller must have approved Treasury for K613."},"getWhitelistedRouters()":{"notice":"Returns the list of all whitelisted router addresses."},"pause()":{"notice":"Pauses deposit and buybackV3 operations. Only callable by PAUSER_ROLE."},"routerWhitelist(address)":{"notice":"Whitelist of DEX routers allowed for buyback. Only DEFAULT_ADMIN_ROLE can update."},"setRouterWhitelist(address,bool)":{"notice":"Adds or removes a router from the buyback whitelist. Only DEFAULT_ADMIN_ROLE."},"stakeForExternalIncentives(uint256)":{"notice":"Stakes K613 already held by this contract into Staking, leaving the resulting xK613 on Treasury's         balance. Used to fund an external pull-based incentives strategy (e.g. Aave's         `PullRewardsTransferStrategy`) without touching `RewardsDistributor.totalDeposits`, so the         per-share reward math for buyback rewards is NOT diluted by this xK613 supply."},"unpause()":{"notice":"Resumes operations. Only callable by PAUSER_ROLE."},"withdraw(address,address,uint256)":{"notice":"Withdraws any ERC20 token from the Treasury. Only callable by DEFAULT_ADMIN_ROLE."}},"notice":"Manages K613 token flows: stakes K613 to get xK613 for rewards, executes buybacks. Rewards are distributed in xK613.","version":1}},"settings":{"compilationTarget":{"src/treasury/Treasury.sol":"Treasury"},"evmVersion":"prague","libraries":{},"metadata":{"bytecodeHash":"ipfs"},"optimizer":{"enabled":true,"runs":200},"remappings":[":@openzeppelin/contracts-upgradeable/=lib/K613-Protocol/lib/solidity-utils/lib/openzeppelin-contracts-upgradeable/contracts/",":@openzeppelin/contracts/=lib/openzeppelin-contracts/contracts/",":@uniswap/v3-core/=lib/v3-core/",":K613-Protocol/=lib/K613-Protocol/",":ds-test/=lib/K613-Protocol/lib/forge-std/lib/ds-test/src/",":erc4626-tests/=lib/openzeppelin-contracts/lib/erc4626-tests/",":forge-std/=lib/forge-std/src/",":halmos-cheatcodes/=lib/openzeppelin-contracts/lib/halmos-cheatcodes/src/",":k613-markets-config/=lib/k613-markets-config/",":openzeppelin-contracts-upgradeable/=lib/K613-Protocol/lib/solidity-utils/lib/openzeppelin-contracts-upgradeable/",":openzeppelin-contracts/=lib/openzeppelin-contracts/",":solidity-utils/=lib/K613-Protocol/lib/solidity-utils/",":swap-router-contracts/=lib/swap-router-contracts/",":v3-core/=lib/v3-core/"],"viaIR":true},"sources":{"lib/openzeppelin-contracts/contracts/access/AccessControl.sol":{"keccak256":"0xa0e92d42942f4f57c5be50568dac11e9d00c93efcb458026e18d2d9b9b2e7308","license":"MIT","urls":["bzz-raw://46326c0bb1e296b67185e81c918e0b40501b8b6386165855df0a3f3c634b6a80","dweb:/ipfs/QmTwyrDYtsxsk6pymJTK94PnEpzsmkpUxFuzEiakDopy4Z"]},"lib/openzeppelin-contracts/contracts/access/IAccessControl.sol":{"keccak256":"0xc1c2a7f1563b77050dc6d507db9f4ada5d042c1f6a9ddbffdc49c77cdc0a1606","license":"MIT","urls":["bzz-raw://fd54abb96a6156d9a761f6fdad1d3004bc48d2d4fce47f40a3f91a7ae83fc3a1","dweb:/ipfs/QmUrFSGkTDJ7WaZ6qPVVe3Gn5uN2viPb7x7QQ35UX4DofX"]},"lib/openzeppelin-contracts/contracts/interfaces/IERC1363.sol":{"keccak256":"0x9b6b3e7803bc5f2f8cd7ad57db8ac1def61a9930a5a3107df4882e028a9605d7","license":"MIT","urls":["bzz-raw://da62d6be1f5c6edf577f0cb45666a8aa9c2086a4bac87d95d65f02e2f4c36a4b","dweb:/ipfs/QmNkpvBpoCMvX8JwAFNSc5XxJ2q5BXJpL5L1txb4QkqVFF"]},"lib/openzeppelin-contracts/contracts/interfaces/IERC165.sol":{"keccak256":"0xde7e9fd9aee8d4f40772f96bb3b58836cbc6dfc0227014a061947f8821ea9724","license":"MIT","urls":["bzz-raw://11fea9f8bc98949ac6709f0c1699db7430d2948137aa94d5a9e95a91f61a710a","dweb:/ipfs/QmQdfRXxQjwP6yn3DVo1GHPpriKNcFghSPi94Z1oKEFUNS"]},"lib/openzeppelin-contracts/contracts/interfaces/IERC20.sol":{"keccak256":"0xce41876e78d1badc0512229b4d14e4daf83bc1003d7f83978d18e0e56f965b9c","license":"MIT","urls":["bzz-raw://a2608291cb038b388d80b79a06b6118a42f7894ff67b7da10ec0dbbf5b2973ba","dweb:/ipfs/QmWohqcBLbcxmA4eGPhZDXe5RYMMEEpFq22nfkaUMvTfw1"]},"lib/openzeppelin-contracts/contracts/interfaces/draft-IERC6093.sol":{"keccak256":"0x880da465c203cec76b10d72dbd87c80f387df4102274f23eea1f9c9b0918792b","license":"MIT","urls":["bzz-raw://399594cd8bb0143bc9e55e0f1d071d0d8c850a394fb7a319d50edd55d9ed822b","dweb:/ipfs/QmbPZzgtT6LEm9CMqWfagQFwETbV1ztpECBB1DtQHrKiRz"]},"lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol":{"keccak256":"0x6ef9389a2c07bc40d8a7ba48914724ab2c108fac391ce12314f01321813e6368","license":"MIT","urls":["bzz-raw://b7a5cb39b1e6df68f4dd9a5e76e853d745a74ffb3dfd7df4ae4d2ace6992a171","dweb:/ipfs/QmPbzKR19rdM8X3PLQjsmHRepUKhvoZnedSR63XyGtXZib"]},"lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol":{"keccak256":"0xe06a3f08a987af6ad2e1c1e774405d4fe08f1694b67517438b467cecf0da0ef7","license":"MIT","urls":["bzz-raw://df6f0c459663c9858b6cba2cda1d14a7d05a985bed6d2de72bd8e78c25ee79db","dweb:/ipfs/QmeTTxZ7qVk9rjEv2R4CpCwdf8UMCcRqDNMvzNxHc3Fnn9"]},"lib/openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol":{"keccak256":"0x70f2f713b13b7ce4610bcd0ac9fec0f3cc43693b043abcb8dc40a42a726eb330","license":"MIT","urls":["bzz-raw://c13d13304ac79a83ab1c30168967d19e2203342ebbd6a9bbce4db7550522dcbf","dweb:/ipfs/QmeN5jKMN2vw5bhacr6tkg78afbTTZUeaacNHqjWt4Ew1r"]},"lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol":{"keccak256":"0x4ea01544758fd2c7045961904686bfe232d2220a04ecaa2d6b08dac17827febf","license":"MIT","urls":["bzz-raw://fabe6bef5167ae741dd8c22d7f81d3f9120bd61b290762a2e8f176712567d329","dweb:/ipfs/QmSnEitJ6xmf1SSAUeZozD7Gx7h8bNnX3a1ZBzqeivsvVg"]},"lib/openzeppelin-contracts/contracts/utils/Context.sol":{"keccak256":"0x493033a8d1b176a037b2cc6a04dad01a5c157722049bbecf632ca876224dd4b2","license":"MIT","urls":["bzz-raw://6a708e8a5bdb1011c2c381c9a5cfd8a9a956d7d0a9dc1bd8bcdaf52f76ef2f12","dweb:/ipfs/Qmax9WHBnVsZP46ZxEMNRQpLQnrdE4dK8LehML1Py8FowF"]},"lib/openzeppelin-contracts/contracts/utils/Pausable.sol":{"keccak256":"0xb2e5f50762c27fb4b123e3619c3c02bdcba5e515309382e5bfb6f7d6486510bd","license":"MIT","urls":["bzz-raw://1a4b83328c98d518a2699c2cbe9e9b055e78aa57fa8639f1b88deb8b3750b5dc","dweb:/ipfs/QmXdcYj5v7zQxXFPULShHkR5p4Wa2zYuupbHnFdV3cHYtc"]},"lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol":{"keccak256":"0x11a5a79827df29e915a12740caf62fe21ebe27c08c9ae3e09abe9ee3ba3866d3","license":"MIT","urls":["bzz-raw://3cf0c69ab827e3251db9ee6a50647d62c90ba580a4d7bbff21f2bea39e7b2f4a","dweb:/ipfs/QmZiKwtKU1SBX4RGfQtY7PZfiapbbu6SZ9vizGQD9UHjRA"]},"lib/openzeppelin-contracts/contracts/utils/introspection/ERC165.sol":{"keccak256":"0xddce8e17e3d3f9ed818b4f4c4478a8262aab8b11ed322f1bf5ed705bb4bd97fa","license":"MIT","urls":["bzz-raw://8084aa71a4cc7d2980972412a88fe4f114869faea3fefa5436431644eb5c0287","dweb:/ipfs/Qmbqfs5dRdPvHVKY8kTaeyc65NdqXRQwRK7h9s5UJEhD1p"]},"lib/openzeppelin-contracts/contracts/utils/introspection/IERC165.sol":{"keccak256":"0x79796192ec90263f21b464d5bc90b777a525971d3de8232be80d9c4f9fb353b8","license":"MIT","urls":["bzz-raw://f6fda447a62815e8064f47eff0dd1cf58d9207ad69b5d32280f8d7ed1d1e4621","dweb:/ipfs/QmfDRc7pxfaXB2Dh9np5Uf29Na3pQ7tafRS684wd3GLjVL"]},"lib/swap-router-contracts/contracts/interfaces/IV3SwapRouter.sol":{"keccak256":"0xa2300af2b82af292216a8f3f301a86e65463655fff9fb791515e3fd2ccf4a14c","license":"GPL-2.0-or-later","urls":["bzz-raw://a0a9bece58527fb5c1773d86666c7a71884a78f413e230dfa8c8a7f8ea564ef9","dweb:/ipfs/QmbDhvpoZJN1KntxUUxkYV89RPTwqVBiyHBkvVh4QHSveo"]},"lib/v3-core/contracts/interfaces/callback/IUniswapV3SwapCallback.sol":{"keccak256":"0x3f485fb1a44e8fbeadefb5da07d66edab3cfe809f0ac4074b1e54e3eb3c4cf69","license":"GPL-2.0-or-later","urls":["bzz-raw://095ce0626b41318c772b3ebf19d548282607f6a8f3d6c41c13edfbd5370c8652","dweb:/ipfs/QmVDZfJJ89UUCE1hMyzqpkZAtQ8jUsBgZNE5AMRG7RzRFS"]},"src/staking/RewardsDistributor.sol":{"keccak256":"0xa03cd717cfc0447c2a340567cfc295a0b0da692bba471b33980aa2ad48a54e26","license":"MIT","urls":["bzz-raw://f27bd4f469a701a939f6dd66ba0d7aba118f28e761864a96d7973635df8a18a4","dweb:/ipfs/QmR1dzUaqHHYL9ZwHS9TW921xPG6QZ2LyUh5KEd5Wifh7u"]},"src/staking/Staking.sol":{"keccak256":"0x0fc7d5a55a5e66599f9b0fcd500cc7c7a6182d6a66713f9781f3bfe9324727bc","license":"MIT","urls":["bzz-raw://92aaa79f8ed93b1f7bfccfa603320b51a294264f3d5cb678693eebb7322bce47","dweb:/ipfs/QmcgqqKpNXNG2sExRivuEPyymYcbpotiTWEbPdBGf6ZVTt"]},"src/token/xK613.sol":{"keccak256":"0xbaf872bf7f306b4ca345fd16ccc7becb13f70f868a4391918d1a0f4af111a744","license":"MIT","urls":["bzz-raw://9bcfb9f093e897fc174e78872ccffafbc20f0cb0cdffdced98009955acdf0896","dweb:/ipfs/QmaPdHz5u4cUEsAmgx986AsQNARFbRRAsg8z49nNn5Vt25"]},"src/treasury/Treasury.sol":{"keccak256":"0xb89975b8113084a9bc0cfa0c166cf5d777acb3bfdc53640d95178805b2e13431","license":"MIT","urls":["bzz-raw://69dd422bf240385fafe5aab0fde20ef2430732c2d9f325b2a6313799a2569687","dweb:/ipfs/QmVBWrQk7BK7VP8KfMtG2gDHvpaNpub5rgVcJb4T2TnErN"]}},"version":1}
0x000000000000000000000000b09582631336068d4b0089d943f40cbf46de51890000000000000000000000009064d55a8a8473fa39c41a16492fa1094eb4e8b500000000000000000000000036451f6b4c06916aafd16359ccf99eb1f584db0b000000000000000000000000e3e8925e8554464611c86419b9e99ad7cd47428f
0xd2c9b67d88f7ea0a1be654e79c1c910041a3b6d55d5744a1a533c3cdbc4ac947
{"4736":[{"start":1316,"length":32},{"start":1527,"length":32},{"start":3544,"length":32},{"start":4134,"length":32}],"4739":[{"start":304,"length":32},{"start":1092,"length":32},{"start":2184,"length":32},{"start":4385,"length":32}],"4742":[{"start":2021,"length":32},{"start":3160,"length":32},{"start":3502,"length":32},{"start":4225,"length":32}],"4745":[{"start":2137,"length":32},{"start":3333,"length":32},{"start":4337,"length":32}]}
