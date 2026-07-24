// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// "The Index" — plain fixed-supply ERC-20 traded on a Uniswap v4 Index/ETH pool.
/// The 3% each-way tax is NOT here: it's taken in native ETH by IndexFeeHook on the pool.
/// This contract only maintains the holder registry the StockDistributor pays out against:
/// every wallet holding >= minShareBalance is tracked; LP (PoolManager) and infra excluded.
contract ReflectionToken is ERC20, Ownable {
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000e18;

    uint256 public minShareBalance = 10_000e18; // min balance to be in the holder registry

    mapping(address => bool) public rewardsExcluded;

    address[] private _holders;
    mapping(address => uint256) private _holderIdx; // 1-based; 0 = not registered

    error ZeroAddress();

    constructor(address poolManager) ERC20("The Index", "Index") Ownable(msg.sender) {
        if (poolManager == address(0)) revert ZeroAddress();
        rewardsExcluded[poolManager] = true; // the LP: v4 pools custody tokens in the PoolManager
        rewardsExcluded[address(0xdead)] = true;
        _mint(msg.sender, TOTAL_SUPPLY);
    }

    // ---- owner knobs ----

    /// Lowering it does not retro-register wallets: they (re)join on their next transfer.
    function setMinShareBalance(uint256 v) external onlyOwner { minShareBalance = v; }

    function setRewardsExcluded(address a, bool on) external onlyOwner {
        rewardsExcluded[a] = on;
        uint256 idx = _holderIdx[a];
        if (on && idx != 0) _removeHolder(a, idx);
        // un-excluding re-registers on the address's next transfer
    }

    // ---- holder registry (read by the distributor) ----

    function holderCount() external view returns (uint256) { return _holders.length; }
    function holderAt(uint256 i) external view returns (address) { return _holders[i]; }

    function _update(address from, address to, uint256 amount) internal override {
        super._update(from, to, amount);
        if (from != address(0)) _refreshHolder(from);
        if (to != address(0)) _refreshHolder(to);
    }

    function _refreshHolder(address a) private {
        if (rewardsExcluded[a]) return;
        uint256 idx = _holderIdx[a];
        if (balanceOf(a) >= minShareBalance) {
            if (idx == 0) {
                _holders.push(a);
                _holderIdx[a] = _holders.length;
            }
        } else if (idx != 0) {
            _removeHolder(a, idx);
        }
    }

    function _removeHolder(address a, uint256 idx) private {
        address last = _holders[_holders.length - 1];
        _holders[idx - 1] = last;
        _holderIdx[last] = idx;
        _holders.pop();
        _holderIdx[a] = 0;
    }
}
