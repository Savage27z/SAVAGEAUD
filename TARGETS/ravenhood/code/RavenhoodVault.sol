// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Owned} from "solmate/src/auth/Owned.sol";
import {INonfungiblePositionManager} from "./interfaces/INonfungiblePositionManager.sol";

contract RavenhoodVault is Owned {
    INonfungiblePositionManager public immutable POSITION_MANAGER;
    address public immutable DEPLOYER;
    uint256 public nftId;

    event NFTLocked(uint256 indexed nftId);
    event FeesCollected(uint256 amount0, uint256 amount1);
    event LiquidityBurned(uint128 liquidityRemoved, uint256 amount0, uint256 amount1);

    constructor(address _deployer, address _positionManager) Owned(msg.sender) {
        POSITION_MANAGER = INonfungiblePositionManager(_positionManager);
        DEPLOYER = _deployer;
    }

    /// @dev Once locked, an NFT can never be unlocked
    function lockNFT(uint256 _nftId) external {
        require(msg.sender == DEPLOYER, "!deployer");
        require(nftId == 0, "nft is already locked");
        nftId = _nftId;
        POSITION_MANAGER.transferFrom(DEPLOYER, address(this), _nftId);
        emit NFTLocked(_nftId);
    }

    function claimFees() external {
        (uint256 amount0, uint256 amount1) = POSITION_MANAGER.collect(
            INonfungiblePositionManager.CollectParams({
                tokenId: nftId,
                recipient: owner,
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            })
        );
        emit FeesCollected(amount0, amount1);
    }

    function claimBurn() external onlyOwner {
        (, , , , , , , uint128 liquidity, , , , ) = POSITION_MANAGER.positions(nftId);
        uint128 liquidityToBurn = uint128(liquidity / 200);
        POSITION_MANAGER.decreaseLiquidity(
            INonfungiblePositionManager.DecreaseLiquidityParams({
                tokenId: nftId,
                liquidity: liquidityToBurn,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp
            })
        );
        (uint256 amount0, uint256 amount1) = POSITION_MANAGER.collect(
            INonfungiblePositionManager.CollectParams({
                tokenId: nftId,
                recipient: owner,
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            })
        );
        emit LiquidityBurned(liquidityToBurn, amount0, amount1);
    }
}
