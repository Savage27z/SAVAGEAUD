// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/**
 * Renderer that returns a fully-formed `data:` URI for a given deposit
 * token, embedding the live deposit state (principal, accrued interest,
 * days-to-maturity, status, loan, compound mode) inside an on-chain SVG
 * + JSON metadata blob. The DepositNFT contract delegates `tokenURI`
 * to a renderer set by governance so the rendering surface can evolve
 * without re-deploying the NFT itself.
 */
interface IDepositMetadataRenderer {
    function tokenURI(uint256 tokenId) external view returns (string memory);
}
