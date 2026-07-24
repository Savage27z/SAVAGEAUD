// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ErrorLib} from "../libraries/ErrorLib.sol";

/// @title BondToken
/// @author Arcis Protocol
/// @notice ERC-1155 multi-token for bond positions
/// @dev Each bondId maps to a token ID. Balances represent USDC-denominated
///      claims on the bond's principal + coupon. Transferable so bond positions
///      can trade on secondary markets.
///
///      Only the RevenueBondFactory (minter) can mint and burn tokens.
contract BondToken {
    // ══════════════════════════════════════════════════════════════
    //                         STORAGE
    // ══════════════════════════════════════════════════════════════

    /// @notice Token name
    string public constant name = "Arcis Revenue Bond";
    string public constant symbol = "arBOND";

    /// @notice Only the factory can mint/burn
    address public immutable factory;

    /// @notice token ID -> owner -> balance
    mapping(uint256 => mapping(address => uint256)) public balanceOf;

    /// @notice owner -> operator -> approved
    mapping(address => mapping(address => bool)) public isApprovedForAll;

    /// @notice token ID -> total supply
    mapping(uint256 => uint256) public totalSupply;

    /// @notice token ID -> metadata URI
    mapping(uint256 => string) private _uris;

    // ══════════════════════════════════════════════════════════════
    //                          EVENTS
    // ══════════════════════════════════════════════════════════════

    event TransferSingle(
        address indexed operator,
        address indexed from,
        address indexed to,
        uint256 id,
        uint256 value
    );

    event TransferBatch(
        address indexed operator,
        address indexed from,
        address indexed to,
        uint256[] ids,
        uint256[] values
    );

    event ApprovalForAll(address indexed account, address indexed operator, bool approved);
    event URI(string value, uint256 indexed id);

    // ══════════════════════════════════════════════════════════════
    //                        MODIFIERS
    // ══════════════════════════════════════════════════════════════

    modifier onlyFactory() {
        if (msg.sender != factory) revert ErrorLib.Unauthorized(msg.sender);
        _;
    }

    // ══════════════════════════════════════════════════════════════
    //                       CONSTRUCTOR
    // ══════════════════════════════════════════════════════════════

    /// @param _factory RevenueBondFactory address
    constructor(address _factory) {
        if (_factory == address(0)) revert ErrorLib.ZeroAddress();
        factory = _factory;
    }

    // ══════════════════════════════════════════════════════════════
    //                    ERC-1155 FUNCTIONS
    // ══════════════════════════════════════════════════════════════

    function safeTransferFrom(
        address from,
        address to,
        uint256 id,
        uint256 amount,
        bytes calldata data
    ) external {
        if (from != msg.sender && !isApprovedForAll[from][msg.sender]) {
            revert ErrorLib.Unauthorized(msg.sender);
        }
        if (to == address(0)) revert ErrorLib.ZeroAddress();

        balanceOf[id][from] -= amount;
        balanceOf[id][to] += amount;

        emit TransferSingle(msg.sender, from, to, id, amount);

        _checkOnERC1155Received(msg.sender, from, to, id, amount, data);
    }

    function safeBatchTransferFrom(
        address from,
        address to,
        uint256[] calldata ids,
        uint256[] calldata amounts,
        bytes calldata data
    ) external {
        if (from != msg.sender && !isApprovedForAll[from][msg.sender]) {
            revert ErrorLib.Unauthorized(msg.sender);
        }
        if (to == address(0)) revert ErrorLib.ZeroAddress();
        if (ids.length != amounts.length) revert ErrorLib.InvalidAllocation();

        for (uint256 i; i < ids.length; ++i) {
            balanceOf[ids[i]][from] -= amounts[i];
            balanceOf[ids[i]][to] += amounts[i];
        }

        emit TransferBatch(msg.sender, from, to, ids, amounts);

        _checkOnERC1155BatchReceived(msg.sender, from, to, ids, amounts, data);
    }

    function setApprovalForAll(address operator, bool approved) external {
        isApprovedForAll[msg.sender][operator] = approved;
        emit ApprovalForAll(msg.sender, operator, approved);
    }

    function balanceOfBatch(
        address[] calldata accounts,
        uint256[] calldata ids
    ) external view returns (uint256[] memory) {
        if (accounts.length != ids.length) revert ErrorLib.InvalidAllocation();

        uint256[] memory batchBalances = new uint256[](accounts.length);
        for (uint256 i; i < accounts.length; ++i) {
            batchBalances[i] = balanceOf[ids[i]][accounts[i]];
        }
        return batchBalances;
    }

    function uri(uint256 id) external view returns (string memory) {
        return _uris[id];
    }

    /// @notice ERC-165 interface support
    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return
            interfaceId == 0xd9b67a26 || // ERC-1155
            interfaceId == 0x0e89341c || // ERC-1155 Metadata URI
            interfaceId == 0x01ffc9a7;   // ERC-165
    }

    // ══════════════════════════════════════════════════════════════
    //                    FACTORY-ONLY FUNCTIONS
    // ══════════════════════════════════════════════════════════════

    /// @notice Mint bond tokens to an investor
    /// @param to Investor address
    /// @param id Bond ID (token ID)
    /// @param amount Number of tokens (1:1 with USDC)
    function mint(address to, uint256 id, uint256 amount) external onlyFactory {
        if (to == address(0)) revert ErrorLib.ZeroAddress();

        balanceOf[id][to] += amount;
        totalSupply[id] += amount;

        emit TransferSingle(msg.sender, address(0), to, id, amount);
    }

    /// @notice Burn bond tokens on redemption
    /// @param from Holder address
    /// @param id Bond ID
    /// @param amount Tokens to burn
    function burn(address from, uint256 id, uint256 amount) external onlyFactory {
        balanceOf[id][from] -= amount;
        totalSupply[id] -= amount;

        emit TransferSingle(msg.sender, from, address(0), id, amount);
    }

    /// @notice Set metadata URI for a bond
    function setURI(uint256 id, string calldata newUri) external onlyFactory {
        _uris[id] = newUri;
        emit URI(newUri, id);
    }

    // ══════════════════════════════════════════════════════════════
    //                    INTERNAL FUNCTIONS
    // ══════════════════════════════════════════════════════════════

    function _checkOnERC1155Received(
        address operator,
        address from,
        address to,
        uint256 id,
        uint256 amount,
        bytes calldata data
    ) internal {
        if (to.code.length > 0) {
            (bool success, bytes memory returnData) = to.call(
                abi.encodeWithSelector(0xf23a6e61, operator, from, id, amount, data)
            );
            if (success && returnData.length >= 32) {
                bytes4 retval = abi.decode(returnData, (bytes4));
                if (retval != 0xf23a6e61) revert ErrorLib.Unauthorized(to);
            }
        }
    }

    function _checkOnERC1155BatchReceived(
        address operator,
        address from,
        address to,
        uint256[] calldata ids,
        uint256[] calldata amounts,
        bytes calldata data
    ) internal {
        if (to.code.length > 0) {
            (bool success, bytes memory returnData) = to.call(
                abi.encodeWithSelector(0xbc197c81, operator, from, ids, amounts, data)
            );
            if (success && returnData.length >= 32) {
                bytes4 retval = abi.decode(returnData, (bytes4));
                if (retval != 0xbc197c81) revert ErrorLib.Unauthorized(to);
            }
        }
    }
}
