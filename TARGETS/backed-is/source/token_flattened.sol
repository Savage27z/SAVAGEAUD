// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";

/// ██████╗  █████╗  ██████╗██╗  ██╗███████╗██████╗
/// ██╔══██╗██╔══██╗██╔════╝██║ ██╔╝██╔════╝██╔══██╗
/// ██████╔╝███████║██║     █████╔╝ █████╗  ██║  ██║
/// ██╔══██╗██╔══██║██║     ██╔═██╗ ██╔══╝  ██║  ██║
/// ██████╔╝██║  ██║╚██████╗██║  ██╗███████╗██████╔╝
/// ╚═════╝ ╚═╝  ╚═╝ ╚═════╝╚═╝  ╚═╝╚══════╝╚═════╝
///
///           the token that can't go to zero
///
///        🌐 https://backed.is   ·   𝕏 https://x.com/isBacked_
///
/// ────────────────────────────────────────────────────────────────────────
///
/// A fixed-supply ERC-20 traded on a single Uniswap v4 BACKED/ETH pool. A 3% each-way ETH tax
/// (taken by BackedFeeHook, NOT here) is used by the StockVault to buy tokenized real stocks that
/// are ACCUMULATED, never distributed. Every token is therefore a redeemable claim on a growing
/// basket of real equities: `StockVault.redeem()` burns your tokens and pays out your pro-rata
/// share of the vault in-kind. That share is the hard floor — no oracle, no counterparty.
///
/// This contract is deliberately minimal: no holder registry, no reflection accounting, no owner
/// mint. Supply is fixed forever at construction and only ever *decreases*, via redemption burns —
/// which makes every remaining token strictly more backed.
contract BackedToken is ERC20, ERC20Burnable {
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000e18;

    constructor(address treasury) ERC20("Backed", "BACKED") {
        // Minted once to the deployer/treasury, which seeds the v4 pool liquidity and any
        // community distribution. No further minting is possible.
        _mint(treasury, TOTAL_SUPPLY);
    }
}