// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

interface ITurbo {
    event TurboExecuted(uint256 indexed sourceDepositId, uint256 indexed newDepositId, uint256 borrowAmount);
    // §Phase 2 Marketplace - a rung was attached to its position root.
    event TurboPositionMemberAdded(uint256 indexed rootDepositId, uint256 indexed memberDepositId);

    // Turbo always opens a fresh FIXED_TERM (1095-day) bond per spec V6.2;
    // there is no caller-supplied maturity.
    function executeTurbo(uint256 depositId, uint256 borrowAmount) external returns (uint256 newDepositId);

    // §Phase 2 Marketplace - position grouping so the whole leveraged stack
    // lists and transfers as a single unit.
    function turboRootOf(uint256 tokenId) external view returns (uint256 root);

    function turboRoot(uint256 tokenId) external view returns (uint256 root);

    function positionMembers(uint256 tokenId) external view returns (uint256[] memory members);
}

