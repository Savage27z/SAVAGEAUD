// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

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

import {IRandomness} from "./interfaces/IRandomness.sol";

interface IArbSys {
    function arbBlockNumber() external view returns (uint256);
}

contract Arb2935Randomness is IRandomness {
    IArbSys private constant ARB_SYS = IArbSys(0x0000000000000000000000000000000000000064);
    address private constant HISTORY = 0x0000F90827F1C53a10cb7A02335B175320002935;

    uint64 public constant REVEAL_DELAY_BLOCKS = 30;
    uint256 public constant REVEAL_EXPIRY_BLOCKS = 100_000;

    function commit() external view returns (uint64) {
        return uint64(ARB_SYS.arbBlockNumber()) + REVEAL_DELAY_BLOCKS;
    }

    function seedFor(uint256 round, uint64 ref) external view returns (bytes32) {
        if (ARB_SYS.arbBlockNumber() <= ref) return bytes32(0);
        (bool ok, bytes memory out) = HISTORY.staticcall(abi.encode(uint256(ref)));
        if (!ok || out.length != 32) return bytes32(0);
        bytes32 hash = abi.decode(out, (bytes32));
        if (hash == bytes32(0)) return bytes32(0);
        return keccak256(abi.encodePacked(hash, round, address(this)));
    }

    function expired(uint64 ref) external view returns (bool) {
        return ARB_SYS.arbBlockNumber() > uint256(ref) + REVEAL_EXPIRY_BLOCKS;
    }
}
