// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IDeathFunMin {
    enum GameStatus { Active, Won, Lost }

    struct Game {
        uint256 createdAt;
        address player;
        uint256 betAmount;
        GameStatus status;
        uint256 payoutAmount;
        bytes32 gameSeedHash;
        string gameSeed;
        string algoVersion;
        string gameConfig;
        string gameState;
    }

    function createGame(
        string calldata preliminaryGameId,
        bytes32 gameSeedHash,
        string calldata algoVersion,
        string calldata gameConfig,
        uint256 deadline,
        bytes calldata serverSignature
    ) external payable;

    function increaseBet(uint256 onChainGameId, uint256 amount, uint256 deadline, bytes calldata serverSignature) external payable;

    function getGameDetails(uint256 onChainGameId) external view returns (Game memory);
    function getOnChainGameId(string calldata preliminaryGameId) external view returns (uint256);
    function isAdmin(address) external view returns (bool);
    function messagePrefix() external view returns (string memory);
    function gameCounter() external view returns (uint256);
    function owner() external view returns (address);
}
