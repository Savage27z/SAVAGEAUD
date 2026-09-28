// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC20} from "./interfaces/IERC20.sol";

/**
 * @title GilderToken (GIL)
 * @notice The protocol token.
 *
 *   Name          : GILD
 *   Symbol        : $GILD
 *   Decimals      : 18
 *   Initial supply: 1,000,000,000,000 GIL  (1 trillion, per V6.2 §B.2)
 *
 * Fixed-supply ERC-20: the entire 1T GIL is minted once to the
 * deployment recipient at construction and there is no further mint
 * path - the supply can only ever decrease (via `burn`). The 10% of
 * every deposit that the protocol routes into an open-market token buy
 * trades against the existing supply on the GIL/USDC Uniswap V2 pool;
 * it does not mint new tokens.
 *
 * V6.2 §B.2 mandated initial allocation (post-mint distribution, handled
 * by the deploy script via plain ERC-20 transfers):
 *   50% -> Market Treasury        (500B)
 *   30% -> Distribution Reserve   (300B)
 *   15% -> Marketing & Ops Wallet (150B)
 *    5% -> Liquidity Pool          (50B + $50k USDC seed)
 *
 * Spec §9.2: "circulating supply" for the TVT calculation excludes
 * protocol-held inventory - the TVT module derives it as
 * `totalSupply() - balanceOf(treasury)`.
 */
contract GilderToken is IERC20 {
    string public constant name = "GILD";
    string public constant symbol = "$GILD";
    uint8 public constant decimals = 18;

    uint256 public constant INITIAL_SUPPLY = 1_000_000_000_000 * 1e18;

    uint256 private _totalSupply;
    mapping(address account => uint256 balance) private _balances;
    mapping(address owner => mapping(address spender => uint256 allowance)) private _allowances;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    error ZeroAddress();
    error InsufficientBalance(uint256 balance, uint256 needed);
    error InsufficientAllowance(uint256 allowance, uint256 needed);

    /**
     * Mints the full fixed supply to `recipient` (the deploy script's
     * treasury / protocol holder). All distribution - pool seeding,
     * Treasury inventory - happens afterwards via plain transfers.
     */
    constructor(address recipient) {
        if (recipient == address(0)) {
            revert ZeroAddress();
        }
        _totalSupply = INITIAL_SUPPLY;
        _balances[recipient] = INITIAL_SUPPLY;
        emit Transfer(address(0), recipient, INITIAL_SUPPLY);
    }

    function totalSupply() external view returns (uint256) {
        return _totalSupply;
    }

    function balanceOf(address account) external view returns (uint256) {
        return _balances[account];
    }

    function allowance(address owner, address spender) external view returns (uint256) {
        return _allowances[owner][spender];
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        _allowances[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = _allowances[from][msg.sender];
        if (allowed < amount) {
            revert InsufficientAllowance(allowed, amount);
        }
        if (allowed != type(uint256).max) {
            _allowances[from][msg.sender] = allowed - amount;
        }
        _transfer(from, to, amount);
        return true;
    }

    /** Permanently removes `amount` GIL from the caller's balance + total supply. */
    function burn(uint256 amount) external {
        uint256 balance = _balances[msg.sender];
        if (balance < amount) {
            revert InsufficientBalance(balance, amount);
        }
        _balances[msg.sender] = balance - amount;
        _totalSupply -= amount;
        emit Transfer(msg.sender, address(0), amount);
    }

    function _transfer(address from, address to, uint256 amount) private {
        if (to == address(0)) {
            revert ZeroAddress();
        }
        uint256 balance = _balances[from];
        if (balance < amount) {
            revert InsufficientBalance(balance, amount);
        }
        _balances[from] = balance - amount;
        _balances[to] += amount;
        emit Transfer(from, to, amount);
    }
}
