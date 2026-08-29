// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {YieldVault} from "src/YieldVault.sol";

/**
 * @title WhitelistedYieldVault
 * @notice YieldVault variant that restricts deposit/mint/withdraw/redeem to a maintainer-managed whitelist.
 */
contract WhitelistedYieldVault is YieldVault {
    using EnumerableSet for EnumerableSet.AddressSet;

    /// @custom:storage-location erc7201:vault.storage.WhitelistedYieldVault
    struct WhitelistStorage {
        EnumerableSet.AddressSet _whitelisted;
    }

    // keccak256(abi.encode(uint256(keccak256("vault.storage.WhitelistedYieldVault")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant WhitelistStorageLocation =
        0x472c7755581d9a230de55fc8bae0f62aefafc049b5aeb35cfb99feb5da0e6200;

    error CallerIsNotWhitelisted();

    event AddedToWhitelist(address indexed account);
    event RemovedFromWhitelist(address indexed account);

    function _getWhitelistStorage() private pure returns (WhitelistStorage storage $) {
        assembly {
            $.slot := WhitelistStorageLocation
        }
    }

    modifier onlyWhitelisted(address account_) {
        if (!isWhitelisted(account_)) revert CallerIsNotWhitelisted();
        _;
    }

    /*//////////////////////////////////////////////////////////////
                                Getters
    //////////////////////////////////////////////////////////////*/

    function isWhitelisted(address account_) public view returns (bool) {
        return _getWhitelistStorage()._whitelisted.contains(account_);
    }

    function whitelist() external view returns (address[] memory) {
        return _getWhitelistStorage()._whitelisted.values();
    }

    /*//////////////////////////////////////////////////////////////
                            User functions
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc YieldVault
    function deposit(uint256 assets_, address receiver_) public override onlyWhitelisted(msg.sender) returns (uint256) {
        return super.deposit(assets_, receiver_);
    }

    /// @inheritdoc YieldVault
    function mint(uint256 shares_, address receiver_) public override onlyWhitelisted(msg.sender) returns (uint256) {
        return super.mint(shares_, receiver_);
    }

    /// @inheritdoc YieldVault
    function withdraw(
        uint256 assets_,
        address receiver_,
        address owner_
    ) public override onlyWhitelisted(owner_) returns (uint256) {
        return super.withdraw(assets_, receiver_, owner_);
    }

    /// @inheritdoc YieldVault
    function redeem(
        uint256 shares_,
        address receiver_,
        address owner_
    ) public override onlyWhitelisted(owner_) returns (uint256) {
        return super.redeem(shares_, receiver_, owner_);
    }

    /*//////////////////////////////////////////////////////////////
                        Maintainer functions
    //////////////////////////////////////////////////////////////*/

    function addToWhitelist(address account_) external onlyMaintainer {
        if (!_getWhitelistStorage()._whitelisted.add(account_)) revert AddInListFailed();
        emit AddedToWhitelist(account_);
    }

    function removeFromWhitelist(address account_) external onlyMaintainer {
        if (!_getWhitelistStorage()._whitelisted.remove(account_)) revert RemoveFromListFailed();
        emit RemovedFromWhitelist(account_);
    }
}
