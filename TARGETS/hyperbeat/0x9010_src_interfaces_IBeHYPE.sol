// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title IBeHYPEToken
 * @notice Interface for the BeHYPE token contract
 */
interface IBeHYPEToken is IERC20 {

    error Unauthorized();

    event StakingCoreUpdated(address stakingCore);
    event WithdrawManagerUpdated(address withdrawManager);
    event FinalizerUserUpdated(address finalizerUser);
    
    /**
     * @notice Mints new tokens to the specified address
     * @param to Address to receive the minted tokens
     * @param amount Amount of tokens to mint
     */
    function mint(address to, uint256 amount) external;

    /**
     * @notice Burns tokens from the specified address
     * @param from Address to burn tokens fro
     * @param amount Amount of tokens to burn
     */
    function burn(address from, uint256 amount) external;

    /**
     * @notice Sets the finalizer / hyperCore deployer address
     * @dev Only callable by PROTOCOL_GUARDIAN role. The finalizer address is stored
     *      in the storage slot at keccak256("HyperCore deployer") as required for
     *      contracts deployed by another contract (e.g. create2 via a multisig).
     * https://hyperliquid.gitbook.io/hyperliquid-docs/for-developers/hyperevm/hypercore-less-than-greater-than-hyperevm-transfers#linking-core-and-evm-spot-assets
     * @param _finalizerUser The address of the finalizer user
     */
    function setFinalizer(address _finalizerUser) external;

    /**
     * @notice Gets the finalizer / hyperCore deployer address
     * @dev Returns the address stored in the storage slot at keccak256("HyperCore deployer")
     * https://hyperliquid.gitbook.io/hyperliquid-docs/for-developers/hyperevm/hypercore-less-than-greater-than-hyperevm-transfers#linking-core-and-evm-spot-assets
     * @return The address of the finalizer / hyperCore deployer
     */
    function getFinalizer() external view returns (address);
}
