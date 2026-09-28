// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

interface ICapitalRouter {
    event TokenBuyExecuted(uint256 indexed depositId, uint256 amount);

    function executeTokenBuy(uint256 depositId, uint256 amount) external;
}
