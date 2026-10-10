// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC721} from "openzeppelin-contracts/contracts/token/ERC721/ERC721.sol";
import {ERC721Consecutive} from "openzeppelin-contracts/contracts/token/ERC721/extensions/ERC721Consecutive.sol";

/// @title DaemonNFT — the collection. Every token is minted at deployment, to the sale contract, in ERC-2309
///        consecutive batches (cheap: one event per batch, not one storage write per token). No mint afterwards, no
///        admin. The token URI points at the daemon's OS (its live page on obol.sh). `owner()` names the treasury Safe
///        ONLY so marketplaces (OpenSea) let it edit the collection page — it has no power over this contract;
///        `contractURI()` is the collection's metadata (ERC-7572).
contract DaemonNFT is ERC721Consecutive {
    uint256 public immutable supply;
    string private baseUri;
    address public immutable owner;      // informational: who edits the collection page on marketplaces; no powers here
    string private collectionUri;

    constructor(address sale, uint96 supply_, string memory baseUri_, address owner_, string memory contractUri_) ERC721("Daemon", "DAEMON") {
        supply = supply_;
        baseUri = baseUri_;
        owner = owner_;
        collectionUri = contractUri_;
        uint96 left = supply_;
        while (left > 0) {
            uint96 batch = left > 5000 ? 5000 : left; // OZ's per-batch ceiling
            _mintConsecutive(sale, batch);
            left -= batch;
        }
    }

    function _baseURI() internal view override returns (string memory) {
        return baseUri;
    }

    function contractURI() external view returns (string memory) {
        return collectionUri;
    }
}
