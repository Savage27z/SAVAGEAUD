// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/**
 * Minimal view of the governance multisig when it acts as the protocol's
 * "guardian council" (§Emergency Brake, Jul 2026).
 *
 * `isUnanimousExecution()` is true ONLY for the duration of a multisig
 * `execute()` whose queued transaction was confirmed by every current
 * owner. That is the signal a module trusts to lift a freeze.
 */
interface IGuardianCouncil {
    function isOwner(address account) external view returns (bool);
    function ownerCount() external view returns (uint256);
    function isUnanimousExecution() external view returns (bool);
}

/**
 * @title GilderAccessControl
 * @notice Role registry + the protocol-wide emergency brake.
 *
 * §Emergency Brake (client request, Jul 2026)
 * ------------------------------------------
 * The governance multisig and the UUPS proxy both enforce a 48h timelock
 * (§N1/§N2). That is correct for *parameter and upgrade* changes, but it
 * is the wrong shape for an active exploit: a drain does not wait 48h.
 *
 * So freezing and unfreezing are deliberately ASYMMETRIC:
 *
 *   FREEZE   - any SINGLE freeze authority, immediately, no confirmations
 *              and no timelock. Cheap to trigger on suspicion, because the
 *              cost of a false alarm is downtime, not loss of funds.
 *
 *   UNFREEZE - the guardian council (multisig) only, and only inside an
 *              execution that EVERY current owner confirmed. No single
 *              signer - not even the deployer or a compromised admin key -
 *              can restart the protocol on their own.
 *
 * Unanimity replaces the timelock on the unfreeze path on purpose: making
 * recovery wait another 48h behind an already-unanimous signer set would
 * only extend an outage, and a fully-unanimous set is a strictly stronger
 * control than the m-of-n threshold the timelock was written to constrain.
 *
 * `paused` and both entry points live HERE rather than in the two module
 * bases (GilderModule / GilderMarketModule) so there is exactly one freeze
 * rule for every contract in the system.
 */
abstract contract GilderAccessControl {
    bytes32 public constant DEFAULT_ADMIN_ROLE = 0x00;
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant PARAMETER_ROLE = keccak256("PARAMETER_ROLE");
    bytes32 public constant TREASURY_OPERATOR_ROLE = keccak256("TREASURY_OPERATOR_ROLE");
    bytes32 public constant BOND_ENGINE_ROLE = keccak256("BOND_ENGINE_ROLE");
    bytes32 public constant NFT_MINTER_ROLE = keccak256("NFT_MINTER_ROLE");
    bytes32 public constant LENDING_OPERATOR_ROLE = keccak256("LENDING_OPERATOR_ROLE");
    bytes32 public constant COMPOUND_OPERATOR_ROLE = keccak256("COMPOUND_OPERATOR_ROLE");
    // §M6 (Jul 2026 client review) - authorised liquidators. Only consulted
    // when Lending.restrictedLiquidation is on; see setLiquidationPolicy.
    bytes32 public constant LIQUIDATOR_ROLE = keccak256("LIQUIDATOR_ROLE");

    mapping(bytes32 role => mapping(address account => bool enabled)) private _roles;
    bool private _initialized;
    // Moved up from GilderModule / GilderMarketModule (§Emergency Brake) so
    // one gate serves every module. Packs into the `_initialized` slot; each
    // base gave a slot back to its own __gap, so no derived contract's
    // storage layout moved.
    bool public paused;

    /// The EOA that ran initialize(). Keeps FREEZE-ONLY power (never
    /// unfreeze), and can drop it via `renounceDeployerFreeze()`.
    address private _deployer;
    /// GilderMultisig acting as guardian council. Zero = not wired yet.
    address public guardianCouncil;
    /// Extra freeze-only addresses (monitoring bots, on-call keeper, ...).
    mapping(address account => bool enabled) public isEmergencyGuardian;

    event RoleGranted(bytes32 indexed role, address indexed account, address indexed sender);
    event RoleRevoked(bytes32 indexed role, address indexed account, address indexed sender);
    event Paused(address indexed account);
    event Unpaused(address indexed account);
    event GuardianCouncilSet(address indexed council);
    event EmergencyGuardianSet(address indexed account, bool enabled);
    event DeployerFreezeRenounced(address indexed deployer);

    error AlreadyInitialized();
    error MissingRole(bytes32 role, address account);
    error ZeroAddress();
    /// Caller holds none of the freeze powers (§Emergency Brake).
    error NotFreezeAuthority(address caller);
    /// The emergency brake is engaged - see `whenNotPaused`.
    error ProtocolFrozen();
    /// Unfreeze was not routed through the guardian council.
    error UnfreezeNotFromCouncil(address caller, address council);
    /// Unfreeze reached the council but not every owner had confirmed it.
    error UnfreezeNotUnanimous();
    /// Candidate council cannot answer `isUnanimousExecution()` - see
    /// setGuardianCouncil. Wiring it would brick the unfreeze path.
    error IncompatibleCouncil(address council);

    modifier onlyRole(bytes32 role) {
        if (!hasRole(role, msg.sender)) {
            revert MissingRole(role, msg.sender);
        }
        _;
    }

    /**
     * §Emergency Brake - the gate the freeze actually acts through.
     *
     * Applied to everything that MOVES VALUE or advances economic state:
     * deposits, settlements, interest withdrawals, loans, repayments,
     * liquidations, Turbo, compounding, NFT transfers, and every treasury
     * disbursement - including the internal cross-module calls, because in a
     * drain the attacker's entry point is usually a sibling module that is
     * already role-authorised.
     *
     * Deliberately NOT applied to:
     *   - initialize() and the parameter/wiring setters, so governance can
     *     still repair the protocol WHILE it is frozen;
     *   - views and time-derived recomputes (accrueInterest,
     *     previewAccruedInterest) which move nothing and simply catch up
     *     once service resumes;
     *   - oracle observers (DePegGuard.checkPeg) - those are protections in
     *     their own right and freezing them would remove a safety net;
     *   - the brake itself.
     */
    modifier whenNotPaused() {
        if (paused) {
            revert ProtocolFrozen();
        }
        _;
    }

    function hasRole(bytes32 role, address account) public view returns (bool) {
        return _roles[role][account];
    }

    function grantRole(bytes32 role, address account) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _grantRole(role, account);
    }

    function revokeRole(bytes32 role, address account) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_roles[role][account]) {
            _roles[role][account] = false;
            emit RoleRevoked(role, account, msg.sender);
        }
    }

    /* -------------------------- emergency brake -------------------------- */

    /**
     * Who may pull the brake. Deliberately broad - during an active drain
     * the expensive mistake is hesitating, not over-freezing.
     */
    function isFreezeAuthority(address account) public view returns (bool) {
        if (account == address(0)) return false;
        if (_roles[PAUSER_ROLE][account]) return true;
        if (_roles[DEFAULT_ADMIN_ROLE][account]) return true;
        if (account == _deployer) return true;
        if (isEmergencyGuardian[account]) return true;

        address council = guardianCouncil;
        if (council != address(0)) {
            if (account == council) return true;
            // staticcall, not a hard interface call: a council that is
            // mis-wired or not multisig-shaped must never be able to brick
            // the brake for everyone else.
            (bool ok, bytes memory ret) =
                council.staticcall(abi.encodeWithSelector(IGuardianCouncil.isOwner.selector, account));
            if (ok && ret.length >= 32 && abi.decode(ret, (bool))) return true;
        }
        return false;
    }

    /**
     * FREEZE - single-signer, instant, no timelock. Idempotent: freezing an
     * already-frozen module is a no-op rather than a revert, so a batch
     * freeze across every module cannot be derailed by one that is already
     * down.
     */
    function emergencyFreeze() public {
        if (!isFreezeAuthority(msg.sender)) revert NotFreezeAuthority(msg.sender);
        if (paused) return;
        paused = true;
        emit Paused(msg.sender);
    }

    /**
     * UNFREEZE - guardian council only, and only while that council is
     * executing a transaction EVERY current owner confirmed.
     *
     * Before a council is wired (local / single-operator deployments) this
     * falls back to the historical PAUSER_ROLE rule so a dev chain is not
     * permanently bricked. Production deploys MUST call
     * `setGuardianCouncil` - see scripts/deploy.js.
     */
    function emergencyUnfreeze() public {
        address council = guardianCouncil;
        if (council == address(0)) {
            if (!_roles[PAUSER_ROLE][msg.sender]) revert MissingRole(PAUSER_ROLE, msg.sender);
        } else {
            if (msg.sender != council) revert UnfreezeNotFromCouncil(msg.sender, council);
            if (!IGuardianCouncil(council).isUnanimousExecution()) revert UnfreezeNotUnanimous();
        }
        if (!paused) return;
        paused = false;
        emit Unpaused(msg.sender);
    }

    /**
     * Wire (or rotate) the guardian council.
     *
     * First wiring is an admin action (it happens at deploy, before the
     * council exists). Every ROTATION afterwards must come from the sitting
     * council under a unanimously-confirmed execution.
     *
     * That second rule is load-bearing. DEFAULT_ADMIN_ROLE is held by the
     * multisig, so without it a mere THRESHOLD of signers (2-of-3, plus the
     * 48h timelock) could repoint `guardianCouncil` at a contract of their
     * own whose `isUnanimousExecution()` always returns true - and then
     * unfreeze without unanimity. Rotating the council is therefore held to
     * the same bar as the thing it protects. It can never be cleared back to
     * zero either, which would re-open the single-signer fallback.
     */
    function setGuardianCouncil(address council) external {
        address current = guardianCouncil;
        if (current == address(0)) {
            if (!_roles[DEFAULT_ADMIN_ROLE][msg.sender]) {
                revert MissingRole(DEFAULT_ADMIN_ROLE, msg.sender);
            }
        } else {
            if (council == address(0)) revert ZeroAddress();
            if (msg.sender != current) revert UnfreezeNotFromCouncil(msg.sender, current);
            if (!IGuardianCouncil(current).isUnanimousExecution()) revert UnfreezeNotUnanimous();
        }
        _requireCompatibleCouncil(council);
        guardianCouncil = council;
        emit GuardianCouncilSet(council);
    }

    /**
     * Refuse a council that cannot answer `isUnanimousExecution()`.
     *
     * This guard exists because getting it wrong is IRREVERSIBLE. `isOwner`
     * is probed with a soft staticcall, so freezing keeps working against an
     * older/incompatible multisig - but `emergencyUnfreeze` calls
     * `isUnanimousExecution()` for real, and a contract without that function
     * reverts. Rotating away needs the SITTING council's unanimity, which is
     * the very thing that no longer answers. The result is a protocol that
     * anyone can freeze and nobody can ever unfreeze.
     *
     * A pre-§Emergency-Brake GilderMultisig is exactly such a contract, so a
     * redeployed protocol must NOT be pointed at an old multisig address.
     *
     * The return value is irrelevant here (it is false outside an execution);
     * all that matters is that the candidate answers at all.
     */
    function _requireCompatibleCouncil(address council) private view {
        (bool ok, bytes memory ret) =
            council.staticcall(abi.encodeWithSelector(IGuardianCouncil.isUnanimousExecution.selector));
        if (!ok || ret.length < 32) revert IncompatibleCouncil(council);
    }

    /// Add/remove a freeze-only guardian (no unfreeze power is ever granted).
    function setEmergencyGuardian(address account, bool enabled) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (account == address(0)) revert ZeroAddress();
        isEmergencyGuardian[account] = enabled;
        emit EmergencyGuardianSet(account, enabled);
    }

    /**
     * Drop the deployer's standing freeze power. A retired deploy key that
     * can still halt the protocol is a griefing handle (freeze costs one
     * tx; recovery costs every signer), so this should be called alongside
     * scripts/renounce-deployer.js once governance is multisig-only.
     */
    function renounceDeployerFreeze() external {
        if (msg.sender != _deployer && !_roles[DEFAULT_ADMIN_ROLE][msg.sender]) {
            revert NotFreezeAuthority(msg.sender);
        }
        address previous = _deployer;
        _deployer = address(0);
        emit DeployerFreezeRenounced(previous);
    }

    function deployer() external view returns (address) {
        return _deployer;
    }

    /* ------------------------------ internal ----------------------------- */

    function _initializeAccessControl(address admin) internal {
        if (_initialized) {
            revert AlreadyInitialized();
        }
        if (admin == address(0)) {
            revert ZeroAddress();
        }

        _initialized = true;
        _deployer = msg.sender;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    function _grantRole(bytes32 role, address account) internal {
        if (account == address(0)) {
            revert ZeroAddress();
        }
        if (!_roles[role][account]) {
            _roles[role][account] = true;
            emit RoleGranted(role, account, msg.sender);
        }
    }

    // 50 -> 48, NOT 47. `_deployer` costs no slot of its own: solc packs it
    // into slot 1 alongside `_initialized` and `paused` (1 + 1 + 20 = 22
    // bytes), so only `guardianCouncil` and `isEmergencyGuardian` consume
    // new slots. Verified against solc storageLayout, not by eye - the naive
    // count shifted every derived contract down a slot, which would corrupt
    // the CYR proxy on upgrade.
    uint256[48] private __gap;
}
