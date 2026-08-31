// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

//
//                         ,(
//                        ((
//                         \\
//                     .---\\---.
//                    /    ``    \
//                   |            |
//                   |            |
//                    \          /
//                     '.______.'
//
//              O R C H A R D  ·  $SEED
//             Plant ETH. Harvest $AAPL.
//
//                https://orchard.gold
//            https://x.com/orcharddotgold
//

import {UtilityToken, UtilityTokenParams} from "../UtilityToken.sol";

contract Orchard is UtilityToken {
    string private constant _name = unicode"Orchard";
    string private constant _symbol = unicode"SEED";

    constructor(
        UtilityTokenParams memory params,
        address uniswapV2Router_,
        address feeRecipient_
    ) UtilityToken(_name, _symbol, params, uniswapV2Router_, feeRecipient_) {}

    function name() public pure override returns (string memory) {
        return _name;
    }

    function symbol() public pure override returns (string memory) {
        return _symbol;
    }
}
