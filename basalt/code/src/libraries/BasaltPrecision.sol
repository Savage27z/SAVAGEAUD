// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";
import {SafeCast} from "openzeppelin-contracts/contracts/utils/math/SafeCast.sol";
import {SignedMath} from "openzeppelin-contracts/contracts/utils/math/SignedMath.sol";

// Mirrors GMX Synthetics Precision.sol.
// https://github.com/gmx-io/gmx-synthetics/blob/10cfbce/contracts/utils/Precision.sol
library BasaltPrecision {
    using SafeCast for uint256;
    using SafeCast for int256;
    using SignedMath for int256;

    uint256 internal constant FLOAT_PRECISION = 10 ** 30;
    uint256 internal constant WEI_PRECISION = 10 ** 18;
    uint256 internal constant FLOAT_TO_WEI_DIVISOR = 10 ** 12;

    function mulDiv(uint256 value, uint256 numerator, uint256 denominator) internal pure returns (uint256) {
        return Math.mulDiv(value, numerator, denominator);
    }

    function mulDiv(uint256 value, int256 numerator, uint256 denominator) internal pure returns (int256) {
        uint256 result = mulDiv(value, numerator.abs(), denominator);
        return numerator > 0 ? result.toInt256() : -result.toInt256();
    }

    function applyFactor(uint256 value, uint256 factor) internal pure returns (uint256) {
        return mulDiv(value, factor, FLOAT_PRECISION);
    }

    function applyFactor(uint256 value, int256 factor) internal pure returns (int256) {
        return mulDiv(value, factor, FLOAT_PRECISION);
    }
}
