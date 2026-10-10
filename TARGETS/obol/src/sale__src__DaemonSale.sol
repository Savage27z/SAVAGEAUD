// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC721} from "openzeppelin-contracts/contracts/token/ERC721/IERC721.sol";
import {IERC721Receiver} from "openzeppelin-contracts/contracts/token/ERC721/IERC721Receiver.sol";

interface IERC6551Registry {
    function createAccount(address impl, bytes32 salt, uint256 chainId, address tokenContract, uint256 tokenId) external returns (address);
    function account(address impl, bytes32 salt, uint256 chainId, address tokenContract, uint256 tokenId) external view returns (address);
}

/// @title DaemonSale — sells every daemon at its band's price and funds the daemon's own wallet in the same transaction.
/// @notice Ten bands by number already sold; each band costs `multiplier` × the one before (1.3 for Daemon). Prices,
///         the split and the treasury are fixed at deployment — nobody can change them. Of each price, `walletBps` goes
///         straight to the daemon's ERC-6551 account (created here if it doesn't exist) and the rest to the treasury
///         (SHYGUY LLC). The sale holds no money between transactions. It opens at `opensAt` (fixed at deployment), so
///         the contracts can be deployed and checked before anyone can buy. Every purchase also emits a readable memo.
contract DaemonSale is IERC721Receiver {
    IERC6551Registry public constant REGISTRY = IERC6551Registry(0x000000006551c19487814612e58FE06813775758);
    uint256 public constant BANDS = 10;

    IERC721 public nft;
    address public immutable accountImpl;
    address payable public immutable treasury;
    uint256 public immutable supply;
    uint256 public immutable walletBps; // e.g. 9000 = 90% to the daemon's wallet
    uint256[BANDS] public bandPrice;   // wei; band 0 first
    uint256 public sold;
    address private immutable deployer;
    uint256 public immutable opensAt;   // unix seconds; buying before it reverts
    string public constant TREASURY_NAME = "SHYGUY LLC";

    event Memo(uint256 indexed tokenId, string memo);   // the purchase in words, decoded by any explorer
    event Bought(uint256 indexed tokenId, address indexed buyer, uint256 band, uint256 price, address wallet, uint256 toWallet, uint256 toTreasury);

    error AlreadySet();
    error WrongPrice(uint256 sent, uint256 price);
    error NotForSale(uint256 tokenId);
    error TransferFailed();
    error NotOpen(uint256 opensAt);

    constructor(address accountImpl_, address payable treasury_, uint256 supply_, uint256 walletBps_, uint256 firstPrice, uint256 multiplierBps, uint256 opensAt_) {
        require(walletBps_ <= 10_000 && supply_ >= BANDS && treasury_ != address(0));
        accountImpl = accountImpl_;
        treasury = treasury_;
        supply = supply_;
        walletBps = walletBps_;
        deployer = msg.sender;
        opensAt = opensAt_;
        uint256 p = firstPrice;
        for (uint256 i; i < BANDS; ++i) {
            bandPrice[i] = p;
            p = (p * multiplierBps) / 10_000;
        }
    }

    /// @dev one-time link to the collection (the NFT is deployed after the sale, minting to it)
    function setNft(address nft_) external {
        if (address(nft) != address(0) || msg.sender != deployer) revert AlreadySet();
        nft = IERC721(nft_);
    }

    function currentBand() public view returns (uint256) {
        return (sold * BANDS) / supply; // 0..9; a band is a tenth of the supply
    }

    function price() public view returns (uint256) {
        return bandPrice[currentBand()];
    }

    function walletOf(uint256 tokenId) public view returns (address) {
        return REGISTRY.account(accountImpl, bytes32(0), block.chainid, address(nft), tokenId);
    }

    /// @notice buy a specific daemon (pick it on the Floor)
    function buy(uint256 tokenId) external payable {
        if (block.timestamp < opensAt) revert NotOpen(opensAt);
        uint256 band = currentBand();
        uint256 p = bandPrice[band];
        if (msg.value != p) revert WrongPrice(msg.value, p);
        if (nft.ownerOf(tokenId) != address(this)) revert NotForSale(tokenId);
        ++sold;
        address wallet = REGISTRY.createAccount(accountImpl, bytes32(0), block.chainid, address(nft), tokenId); // idempotent
        uint256 toWallet = (p * walletBps) / 10_000;
        uint256 toTreasury = p - toWallet;
        nft.transferFrom(address(this), msg.sender, tokenId);
        (bool ok,) = wallet.call{value: toWallet}("");
        (bool ok2,) = treasury.call{value: toTreasury}("");
        if (!ok || !ok2) revert TransferFailed();
        emit Bought(tokenId, msg.sender, band, p, wallet, toWallet, toTreasury);
        emit Memo(tokenId, memo(tokenId, band, p));
    }

    /// @notice e.g. "Daemon #212 · band 3 of 10 · 0.0169 ETH: 90% to its own wallet, 10% to SHYGUY LLC"
    function memo(uint256 tokenId, uint256 band, uint256 p) public view returns (string memory) {
        return string.concat("Daemon #", _uint(tokenId), unicode" · band ", _uint(band + 1), " of 10 ", unicode"· ", _eth(p), " ETH: ",
            _uint(walletBps / 100), "% to its own wallet, ", _uint((10_000 - walletBps) / 100), "% to ", TREASURY_NAME);
    }

    function _uint(uint256 v) internal pure returns (string memory) {
        if (v == 0) return "0";
        uint256 n; for (uint256 t = v; t != 0; t /= 10) n++;
        bytes memory b = new bytes(n);
        while (v != 0) { b[--n] = bytes1(uint8(48 + v % 10)); v /= 10; }
        return string(b);
    }

    /// @dev wei → a decimal ETH string with trailing zeros dropped ("0.01", "0.0169", "1")
    function _eth(uint256 wei_) internal pure returns (string memory) {
        uint256 whole = wei_ / 1e18; uint256 frac = wei_ % 1e18;
        if (frac == 0) return _uint(whole);
        bytes memory f = new bytes(18);
        for (uint256 i = 18; i > 0; --i) { f[i - 1] = bytes1(uint8(48 + frac % 10)); frac /= 10; }
        uint256 len = 18; while (len > 0 && f[len - 1] == "0") --len;
        bytes memory out = new bytes(len);
        for (uint256 i; i < len; ++i) out[i] = f[i];
        return string.concat(_uint(whole), ".", string(out));
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }
}
