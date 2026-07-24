// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ArcisAgentVault} from "./ArcisAgentVault.sol";
import {ErrorLib} from "../libraries/ErrorLib.sol";

/// @title ArcisVaultFactory
/// @author Arcis Protocol (arcis.money)
/// @notice Deploys and registers ERC-4626 vaults for agent tokens ($CUSTOS, $AKITA, ...)
/// @dev Yearn-V3-style factory. One vault per asset. Every vault shares the same
///      security stack as the flagship USDC vault: virtual-offset inflation protection,
///      per-agent caps, early-withdrawal fee, pause, two-step ownership, and a 24h
///      strategy timelock. The factory doubles as the on-chain registry — integrators
///      (DeFiLlama, dashboards, agents) enumerate allVaults() and read each vault's
///      totalAssets() for complete accounting of every token deposited.
///
///      Vault ownership is passed through to the factory owner at deployment, so the
///      protocol multisig controls caps, fees, pause, and strategy approval on every
///      vault from day one.
contract ArcisVaultFactory {
    // ══════════════════════════════════════════════════════════════
    //                          STORAGE
    // ══════════════════════════════════════════════════════════════

    /// @notice Factory owner (protocol multisig) — becomes owner of every deployed vault
    address public owner;

    /// @notice Pending owner for two-step transfer
    address public pendingOwner;

    /// @notice All vaults ever deployed, in creation order
    address[] public vaults;

    /// @notice Asset token → vault address (one vault per asset)
    mapping(address => address) public vaultFor;

    /// @notice Vault address → registered by this factory
    mapping(address => bool) public isVault;

    // ══════════════════════════════════════════════════════════════
    //                          EVENTS
    // ══════════════════════════════════════════════════════════════

    event VaultCreated(
        address indexed asset,
        address indexed vault,
        string name,
        string symbol,
        uint256 depositCap,
        uint256 reserveRatioBps
    );
    event OwnershipTransferStarted(address indexed current, address indexed pending);
    event OwnershipTransferred(address indexed previous, address indexed current);

    // ══════════════════════════════════════════════════════════════
    //                         MODIFIERS
    // ══════════════════════════════════════════════════════════════

    modifier onlyOwner() {
        if (msg.sender != owner) revert ErrorLib.Unauthorized(msg.sender);
        _;
    }

    // ══════════════════════════════════════════════════════════════
    //                        CONSTRUCTOR
    // ══════════════════════════════════════════════════════════════

    constructor() {
        owner = msg.sender;
    }

    // ══════════════════════════════════════════════════════════════
    //                       VAULT CREATION
    // ══════════════════════════════════════════════════════════════

    /// @notice Deploy a new agent-token vault
    /// @param asset Underlying ERC-20 (agent token)
    /// @param name Share token name (e.g. "Arcis CUSTOS")
    /// @param symbol Share token symbol (e.g. "raCUSTOS")
    /// @param minDeposit Minimum deposit in asset units (dust guard)
    /// @param depositCap Maximum total deposits in asset units
    /// @param feeBps Management fee on yield in bps (0 for reserve-only vaults)
    /// @param feeRecipient Fee recipient (protocol treasury)
    /// @param reserveRatioBps Liquid reserve target in bps (10000 = reserve-only, no strategies)
    /// @return vault The deployed vault address
    function createVault(
        address asset,
        string calldata name,
        string calldata symbol,
        uint256 minDeposit,
        uint256 depositCap,
        uint256 feeBps,
        address feeRecipient,
        uint256 reserveRatioBps
    ) external onlyOwner returns (address vault) {
        if (asset == address(0)) revert ErrorLib.ZeroAddress();
        if (vaultFor[asset] != address(0)) revert ErrorLib.StrategyAlreadyRegistered(vaultFor[asset]);

        // Read decimals from the asset — shares mirror the underlying
        uint8 assetDecimals = _decimalsOf(asset);

        vault = address(
            new ArcisAgentVault(
                asset,
                name,
                symbol,
                assetDecimals,
                minDeposit,
                depositCap,
                feeBps,
                feeRecipient,
                reserveRatioBps,
                owner
            )
        );

        vaults.push(vault);
        vaultFor[asset] = vault;
        isVault[vault] = true;

        emit VaultCreated(asset, vault, name, symbol, depositCap, reserveRatioBps);
    }

    // ══════════════════════════════════════════════════════════════
    //                       REGISTRY VIEWS
    // ══════════════════════════════════════════════════════════════

    /// @notice All vault addresses deployed by this factory
    /// @dev DeFiLlama adapters and dashboards loop this and sum totalAssets() per vault
    function allVaults() external view returns (address[] memory) {
        return vaults;
    }

    /// @notice Number of vaults deployed
    function vaultCount() external view returns (uint256) {
        return vaults.length;
    }

    /// @notice Aggregated info for one vault (registry read for tooling)
    /// @param index Vault index in creation order
    function vaultInfo(uint256 index)
        external
        view
        returns (
            address vault,
            address asset,
            string memory name,
            string memory symbol,
            uint256 totalAssets,
            uint256 depositCap,
            bool paused
        )
    {
        ArcisAgentVault v = ArcisAgentVault(vaults[index]);
        return (address(v), v.asset(), v.name(), v.symbol(), v.totalAssets(), v.depositCap(), v.paused());
    }

    // ══════════════════════════════════════════════════════════════
    //                      OWNERSHIP (two-step)
    // ══════════════════════════════════════════════════════════════

    /// @notice Start ownership transfer. Note: only affects vaults created AFTER
    ///         acceptance — existing vaults transfer ownership individually.
    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ErrorLib.ZeroAddress();
        pendingOwner = newOwner;
        emit OwnershipTransferStarted(owner, newOwner);
    }

    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert ErrorLib.Unauthorized(msg.sender);
        emit OwnershipTransferred(owner, msg.sender);
        owner = msg.sender;
        pendingOwner = address(0);
    }

    // ══════════════════════════════════════════════════════════════
    //                         INTERNAL
    // ══════════════════════════════════════════════════════════════

    /// @dev Read decimals() from the asset; default to 18 if the token doesn't expose it
    function _decimalsOf(address token) internal view returns (uint8) {
        (bool success, bytes memory data) = token.staticcall(abi.encodeWithSelector(0x313ce567));
        if (success && data.length >= 32) {
            return abi.decode(data, (uint8));
        }
        return 18;
    }
}
