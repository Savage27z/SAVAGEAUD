// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////
  EXTERNAL INTERFACES (mimo Flap — ty jsou kanonicky v src/flap/)
  ABI ověřeno 2026-07-18 z verifikovaných zdrojáků na Blockscoutu
  (robinhoodchain.blockscout.com) + fork testy.
//////////////////////////////////////////////////////////////*/

/// @notice SlvrVoteEscrow — 0xd9b8FBD61033145c5496132153CE675756313B71
/// VERIFIED: kontrakty smí vytvářet locky (žádný EOA check). TMAX = 120 dní,
/// ale používáme PERMANENT lock: SLVR se pálí, lock je nevratný, konstantní
/// 4x staking weight (MMAX=2.5e18, P=2e18 → m = 1+(2.5-1)*2 = 4.0x), max 1 na adresu.
/// Auto-stake: createPermanentLock sám (best-effort) stakuje do stakingContract.
interface ISlvrVoteEscrow {
    function createPermanentLock(uint256 amount) external returns (uint256 tokenId);
    function increasePermanentLock(uint256 tokenId, uint256 amount) external;
    function userPermanentLockId(address user) external view returns (uint256);
    function getStakingWeight(uint256 tokenId) external view returns (uint256);
    function ownerOf(uint256 tokenId) external view returns (address);
}

/// @notice SlvrVoteEscrowStaking — 0xaF68598eBd245DC3cB92FF16E9Ba1814DD137200
/// VERIFIED: weight-based staking, NFT ZŮSTÁVÁ vlastníkovi (žádná custody).
/// claimStakerRewards platí nativní ETH volajícímu (musí být ownerOf veNFT);
/// revertuje "no rewards" při nule → volat v try/catch.
interface ISlvrStaking {
    function stake(uint256 tokenId) external;
    function claimStakerRewards(uint256 tokenId) external;
    function getStakerRewards(uint256 tokenId) external view returns (uint256);
    function balance(uint256 tokenId) external view returns (uint256);
}

/// @notice UniV2 pair — swapujeme přímo přes pár, žádný router (odpadá neznámá adresa).
/// VERIFIED: K-check `balance*1000 - amountIn*3` → fee 997/1000 (klasický UniV2).
interface IUniswapV2Pair {
    function getReserves() external view returns (uint112 r0, uint112 r1, uint32);
    function token0() external view returns (address);
    function token1() external view returns (address);
    function factory() external view returns (address);
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
}

interface IUniswapV2Factory {
    function getPair(address a, address b) external view returns (address pair);
}

interface IWETH {
    function deposit() external payable;
    function transfer(address, uint256) external returns (bool);
}

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
}

interface IERC721Receiver {
    function onERC721Received(address, address, uint256, bytes calldata) external returns (bytes4);
}
