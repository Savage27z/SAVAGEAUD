// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

interface IDepositNFT {
    event DepositTokenMinted(uint256 indexed tokenId, address indexed owner, uint256 indexed depositId);
    event Transfer(address indexed from, address indexed to, uint256 indexed tokenId);
    event Approval(address indexed owner, address indexed approved, uint256 indexed tokenId);
    event ApprovalForAll(address indexed owner, address indexed operator, bool approved);
    event TransferWhitelistSet(address indexed account, bool allowed);
    event BaseTokenUriSet(string baseTokenUri);
    event MetadataRendererSet(address indexed renderer);
    event DepositBurned(uint256 indexed tokenId);
    event MarketplaceSet(address indexed marketplace);
    event ListedStateSet(uint256 indexed tokenId, bool listed);

    function mintForDeposit(address owner, uint256 depositId) external returns (uint256 tokenId);

    function burn(uint256 tokenId) external;

    function transferFrom(address from, address to, uint256 tokenId) external;

    function safeTransferFrom(address from, address to, uint256 tokenId) external;

    function safeTransferFrom(address from, address to, uint256 tokenId, bytes calldata data) external;

    function approve(address to, uint256 tokenId) external;

    function setApprovalForAll(address operator, bool approved) external;

    function getApproved(uint256 tokenId) external view returns (address operator);

    function isApprovedForAll(address owner, address operator) external view returns (bool);

    function setTransferWhitelist(address account, bool allowed) external;

    function setMarketplace(address marketplace_) external;

    function marketplace() external view returns (address);

    function setListedState(uint256 tokenId, bool listed) external;

    function isListed(uint256 tokenId) external view returns (bool);

    function isPoolAttached(uint256 tokenId) external view returns (bool);

    function tokenURI(uint256 tokenId) external view returns (string memory uri);

    function royaltyInfo(uint256 tokenId, uint256 salePrice) external view returns (address receiver, uint256 royaltyAmount);

    function ownerOf(uint256 tokenId) external view returns (address owner);

    function balanceOf(address owner) external view returns (uint256 balance);

    function supportsInterface(bytes4 interfaceId) external view returns (bool);
}
